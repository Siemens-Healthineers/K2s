<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Issue #3212 – Validating shared-layer reuse during multi-image import

## 1. Objective and scope

Issue #3212 adds import of multi-image Docker archives. This guide tests one architectural requirement:

> When K2s imports several images from one Docker archive, a layer shared by those images must be stored
> **once**, not once per image.

The guide builds a two-image archive whose images share a new, never-before-seen 8 MiB base layer. It
imports the archive with `k2s image import` and compares the Linux control plane's image storage before and
after the import.

**Proof standard:** the main proof is the storage metadata (layer records and image layer chains). Buildah
log messages and image sizes are not proof. Disk usage is only supporting evidence.

This guide does **not** cover multi-image OCI archives, other Buildah versions, or archives produced by
`docker save`. See [Section 13](#13-known-limitations).

### 1.1 Status of each statement in this guide

| Label | Meaning |
|---|---|
| **Source-verified** | Read in the current K2s source code |
| **Environment-verified** | Observed read-only on the control plane on 2026-10-16 |
| **Expected** | What should happen if reuse works. Must be confirmed by your measurements |
| **Unverified** | Not checked; stated so you can watch for it |

### 1.2 What the implementation does (Source-verified)

In `lib/scripts/windows/host/image/Image-Common.module.psm1`, `Invoke-LinuxNodeImageImport`:

1. Reads `manifest.json` from the archive on Windows (`Get-DockerArchiveManifestInfo`). With a valid
   manifest of two or more entries it takes the multi-image path, with or without `--docker-archive`.
2. Copies the archive **once** to a unique temporary file `/tmp/k2s-image-import-<guid>.tar` on the node
   (`Copy-ToControlPlaneViaSSHKey`).
3. Runs `sudo buildah pull docker-archive:/tmp/k2s-image-import-<guid>.tar:@<i> 2>&1` for `i = 0, 1, …` in a
   `for` loop, in manifest order, each after the previous one has returned. All entries use the same copy.
4. Logs `[Import] Docker archive '<path>' contains <n> images; …` and
   `[Import] Importing archive entry @<i> (<tags>, config '<Config>') …` for each entry.
5. Runs `sudo rm -f /tmp/k2s-image-import-<guid>.tar` in a `finally` block.

The E2E suite `test/e2e/cluster/imageimport` automates the core of this check with a synthetic two-image
archive: it asserts that the shared base layer has exactly one record in `layers.json` and that both images'
top layers use it as parent. This guide remains the detailed manual procedure with disk-usage evidence.

K2s itself does not handle layers. Whether layers are reused is decided entirely by Buildah and its storage
library.

### 1.3 Target storage (Environment-verified)

| Fact | Evidence |
|---|---|
| Buildah 1.39.3 | `buildah --version` |
| `sudo buildah` uses `/var/lib/containers/storage` with the `overlay` driver | `sudo buildah info` (GraphRoot, GraphDriverName). `/etc/containers/storage.conf` does not exist, so these are the built-in defaults |
| CRI-O (1.36.7) uses the same storage | `crio config` shows the default `root = "/var/lib/containers/storage"`; no file under `/etc/crio/` overrides `root`, `runroot` or `storage_driver`; `crictl imagefsinfo` reports `/var/lib/containers/storage/overlay-images` |
| Image layer records | `/var/lib/containers/storage/overlay-layers/layers.json`: a JSON list. Every record has `id`, `diff-digest` and `diff-size`. `parent` is absent for bottom layers |
| Container (writable) layer records | Kept separately in `overlay-layers/volatile-layers.json`, with no `diff-digest`. These change whenever Pods start or stop |
| Image records | `/var/lib/containers/storage/overlay-images/images.json`: a JSON list with `id`, `names` (optional), and `layer` (the image's **top** layer record) |
| Layer contents on disk | `/var/lib/containers/storage/overlay/<layer record id>/diff` |

### 1.4 Terms

| Term | Meaning | Example |
|---|---|---|
| **Layer content digest** (`diff-digest`, DiffID) | SHA-256 of the uncompressed layer tar. Identical content gives an identical digest, wherever the layer sits | `sha256:4d049f83d9cf…` |
| **Layer record ID** (`id` in `layers.json`) | Identifier of one stored layer. It also depends on the layers below it | `9c355c246ca8…` |
| **Parent record** (`parent`) | The record ID of the layer directly below. Absent for a bottom layer | `5b082c2cea56…` |
| **Image ID** | SHA-256 of the image configuration. For a Docker-archive pull it equals the archive's `Config` member name without `.json` (Environment-verified with `registry.k8s.io/pause:3.10.2`) | `4a83b15d3ecf…` |
| **Manifest layer reference** | An entry of `Layers` in the archive's `manifest.json`: a path *inside the archive*. In Buildah-written archives it is `<content digest hex>.tar` | `4d049f83….tar` |

### 1.5 Why reuse depends on the layers below (Environment-verified)

Layers are stored per *chain*, not per content:

- The content `4d049f83d9cf…` occurs in **4 separate records** in the current storage, each with a different
  parent (it is used by kube-scheduler, coredns, etcd and one more image). Identical content on top of
  different lower layers is **not** stored only once.
- kube-scheduler and kube-controller-manager point to the **same 13 lower layer records**: identical content
  on identical lower layers is stored once.
- The images `4a83b15d3ecf` and `cb84a9dbb358`, created by **two separate pulls** during earlier validation,
  both use the single record `68b14877de21`. A later pull reuses a record created earlier.
- Bottom-layer records that were checked have a record ID equal to their content digest (for example record
  `7223ea1323e8` has content `7223ea1323e8…`).

The experiment therefore gives both test images **the same base layer as their bottom layer**, so their
chains are identical up to the base layer.

**Not yet measured, and the purpose of this guide:** that entry `@1` reuses a layer first stored by entry
`@0` of the *same* multi-image import.

### 1.6 Why Buildah log messages are not proof (Environment-verified)

Without a terminal, Buildah prints `Copying blob sha256:…` for every layer, including layers that already
exist. In earlier imports of images that were already stored, `k2s.log` contained `Copying blob` lines and
**no** `skipped: already exists` lines. Whether that message appears says nothing reliable about reuse.

---

## 2. Prerequisites

| Item | Requirement |
|---|---|
| Windows shell | Elevated Windows PowerShell 5.1 (`$PSVersionTable.PSVersion` shows 5.1) |
| Checkout | `C:\ws\k2s`, branch `3212-multi-image-import`; `C:\ws\k2s\k2s.exe` runs scripts from this checkout |
| Cluster | `k2s status` exit code 0; control plane `172.19.1.100`, user `remote` |
| SSH key | `%USERPROFILE%\.ssh\k2s\id_rsa` must exist. Never print it |
| Linux tools | Environment-verified present: `buildah` 1.39.3, `python3` 3.13, GNU `tar`, `sha256sum`, `du`, `findmnt` |
| Space on Linux `/tmp` | At least 200 MB. `/tmp` is a RAM-backed `tmpfs` (about 2.7 GB free when checked). The experiment uses about 60 MB there |
| Space on Windows `C:` | At least 100 MB |
| Concurrency | No other `k2s image import` may run during the experiment; it would change the measured storage |

Open the Linux shell from Windows PowerShell:

```powershell
k2s node connect -i 172.19.1.100 -u remote
```

Every code block below names its environment: **Windows PowerShell** or **Linux VM**. Do not mix them.

---

## 3. Session variables

Choose a run ID that has not been used before (lowercase letters and digits, for example `r1`). If the
fixture has to be rebuilt ([Section 7](#7-baseline-storage-measurement)), use a new run ID.

**Linux VM** (read-only; run again in every new shell):

```bash
RUN=r1                                          # change for every new attempt; lowercase letters and digits only
unset R
if [[ "$RUN" =~ ^[a-z0-9]+$ ]]; then
  R="/tmp/k2s-3212-layers-$RUN"                 # disposable workspace for this run only
  echo "workspace: $R"
else
  echo "ERROR: RUN '$RUN' must match ^[a-z0-9]+\$; R is not set. Fix RUN and run this block again."
fi
NS=k2s.local/issue3212-layers                   # fixed test tag namespace
S=/var/lib/containers/storage                   # target storage (Environment-verified)
# Buildah on an isolated, disposable VFS store inside $R. Never touches $S. Refuses to run without a valid $R.
bi() {
  [[ "$RUN" =~ ^[a-z0-9]+$ && "$R" == "/tmp/k2s-3212-layers-$RUN" ]] || { echo "ERROR: invalid RUN/R; not running buildah"; return 1; }
  sudo buildah --root "$R/store" --runroot "$R/run" --storage-driver vfs "$@"
}
```

Do not continue unless the block prints `workspace: /tmp/k2s-3212-layers-<run>`.

**Windows PowerShell** (read-only; run again in every new window):

```powershell
$Run = 'r1'                                           # same value as RUN on Linux
if ($Run -cnotmatch '^[a-z0-9]+$') { throw "Run ID '$Run' must match ^[a-z0-9]+$" }
$K2s = 'C:\ws\k2s\k2s.exe'
$Win = "C:\temp\k2s-3212-layers-$Run"                 # Windows workspace for this run only
$Arc = "$Win\shared.tar"
$Key = "$env:USERPROFILE\.ssh\k2s\id_rsa"             # path only; never print the file
$Log = 'C:\var\log\k2s.log'
$Ssh = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-i', $Key)
```

---

## 4. Read-only preflight

**Windows PowerShell:**

```powershell
Set-Location C:\ws\k2s
$PSVersionTable.PSVersion
git branch --show-current                  # 3212-multi-image-import
git status --short                         # record; change nothing
Test-Path $Key                             # True
Test-Path $Win                             # must be False
& $K2s status; "k2s status exit code: $LASTEXITCODE"
```

**Linux VM:**

```bash
buildah --version
sudo buildah info --format '{{.store.GraphRoot}} {{.store.GraphDriverName}}'   # /var/lib/containers/storage overlay
sudo crictl imagefsinfo | grep '"mountpoint"'                                  # .../storage/overlay-images
sudo grep -rhE '^\s*(root|runroot|storage_driver)\s*=' /etc/crio/ || echo "no CRI-O storage override"
sudo ls -l "$S/overlay-layers/layers.json" "$S/overlay-images/images.json"
sudo buildah images --format '{{.Name}}:{{.Tag}}' | grep -c "^$NS/" || true    # must print 0
ls /tmp/k2s-image-import-*.tar >/dev/null 2>&1 && echo STALE_IMPORT_ARCHIVE || echo CLEAN   # must print CLEAN
ls -ld "$R" 2>&1                                                               # must say "No such file or directory"
df -h /tmp
```

Stop if any check differs:

- If a test tag exists, a previous run was not cleaned up. Do not remove it until you know where it came
  from.
- If a `/tmp/k2s-image-import-*.tar` file exists, an import may be running or may have been interrupted. Do
  not delete it.
- If the storage root or driver differs, the measurement method in this guide may not apply.

---

## 5. Build the test fixture (Linux VM)

Changes only files inside `$R`. The cluster's storage `$S` is not touched: all Buildah commands in this
section go through `bi`, which uses the isolated store `$R/store`.

### 5.1 Create the workspace and payloads

```bash
mkdir "$R"                                      # fails if it already exists; that is intended
head -c 8388608 /dev/urandom > "$R/base.bin"    # 8 MiB of random, incompressible, unique data
printf 'image-a %s\n' "$RUN" > "$R/a.txt"
printf 'image-b %s\n' "$RUN" > "$R/b.txt"
ls -l "$R"
sha256sum "$R/base.bin" | tee "$R/base.bin.sha256"
```

### 5.2 Build a base image and two child images in the isolated store

```bash
c=$(bi from scratch)                && bi copy "$c" "$R/base.bin" /base.bin && bi commit --rm "$c" "$NS/base:1"
c=$(bi from "$NS/base:1")           && bi copy "$c" "$R/a.txt" /app.txt   && bi commit --rm "$c" "$NS/a:1"
c=$(bi from "$NS/base:1")           && bi copy "$c" "$R/b.txt" /app.txt   && bi commit --rm "$c" "$NS/b:1"
bi images --no-trunc --format '{{.Name}}:{{.Tag}} {{.ID}}'
bi containers --all                             # expect no containers (all committed with --rm)
```

- `buildah from scratch`, `copy`, `commit --rm`, `images --no-trunc --format` and `containers --all` were
  checked against `--help` of the installed Buildah 1.39.3.
- `buildah from "$NS/base:1"` finds the image in the isolated store. The default pull policy only pulls when
  the image is missing, so nothing is downloaded.

### 5.3 Check the layer structure and record the base digest

```bash
for i in base a b; do
  echo "$i: $(bi inspect --type image --format '{{range .OCIv1.RootFS.DiffIDs}}{{.}} {{end}}' "$NS/$i:1")"
done
BASE=$(bi inspect --type image --format '{{index .OCIv1.RootFS.DiffIDs 0}}' "$NS/base:1")
echo "$BASE" | tee "$R/base-digest.txt"
```

Required:

- `base` has exactly **one** digest, `BASE`.
- `a` and `b` each have exactly **two** digests. The first is `BASE` in both; the second digests differ.

If not, stop. The fixture does not have the intended structure.

### 5.4 Export each child image as a Docker archive

This is the same `buildah push <image> docker-archive:<file>:<name>` form K2s uses in
`lib/scripts/windows/host/image/Export-Image.ps1`, run against the isolated store.

```bash
bi push "$NS/a:1" "docker-archive:$R/a.tar:$NS/a:1"
bi push "$NS/b:1" "docker-archive:$R/b.tar:$NS/b:1"
sudo chown remote "$R/a.tar" "$R/b.tar"          # "remote", not "remote:remote"; that group does not exist
tar -tvf "$R/a.tar"
```

Expected archive layout, Environment-verified on an existing Buildah-written archive (`/tmp/coredns.tar`):

- Each layer is a regular file named `<content digest hex>.tar`; the manifest's `Layers` refer to these files.
- The config is `<image ID hex>.json`.
- Older-format compatibility folders `<id>/layer.tar` (a symbolic link to `../<digest>.tar`), `<id>/VERSION`
  and `<id>/json` are also present.
- `manifest.json` and `repositories` are also present.

If `tar -tvf` shows a different layout, stop and record it. [Section 6.2](#62-check-the-final-archive)
depends on the layout above.

### 5.5 Combine the two archives

#### Why not reuse `mk3212.py` unchanged

`docs/issue-3212-multi-image-manual-validation.md` (Section 4.2) contains `mk3212.py`. Reviewed for this
experiment:

- It treats two members with the **same name and size** as identical without comparing content.
- Symbolic links all count as size `-1`, so two links with the same name but different targets are not
  detected.
- It requires `--tags` for every entry and rewrites `RepoTags`.

That is acceptable for its original fixtures, but this experiment depends on the merged archive containing
exactly the right single copy of the shared layer. The script below compares SHA-256 **content** (and link
targets) for every duplicate name. It keeps the original `RepoTags`, refuses unsafe member paths, and refuses
to overwrite any file. The existing guide is not changed.

```bash
cat > "$R/combine.py" <<'PYEOF'
import hashlib, io, json, os, sys, tarfile
out, srcs = sys.argv[1], sys.argv[2:]
if len(srcs) < 2:
    sys.exit("usage: combine.py OUT SRC1 SRC2 [...]")
if os.path.exists(out):
    sys.exit("refusing to overwrite " + out)

def fingerprint(t, m):
    if m.issym() or m.islnk():
        return ("link", m.linkname)
    if m.isdir():
        return ("dir", "")
    if m.isfile():
        h = hashlib.sha256()
        f = t.extractfile(m)
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
        return ("file", h.hexdigest())
    sys.exit("unsupported member type: " + m.name)

manifest, seen, shared = [], {}, []
with tarfile.open(out, "x") as dst:                 # "x" = create only, never overwrite
    for s in srcs:
        with tarfile.open(s) as t:
            entries = json.load(t.extractfile("manifest.json"))
            if not isinstance(entries, list) or len(entries) != 1:
                sys.exit(s + ": expected a manifest.json list with exactly one entry")
            manifest += entries
            for m in t.getmembers():
                if m.name in ("manifest.json", "repositories"):
                    continue
                if os.path.isabs(m.name) or ".." in m.name.split("/"):
                    sys.exit("unsafe member path: " + m.name)
                fp = fingerprint(t, m)
                if m.name in seen:
                    if seen[m.name] != fp:
                        sys.exit("conflicting member with different content: " + m.name)
                    shared.append(m.name)
                    continue
                seen[m.name] = fp
                dst.addfile(m, t.extractfile(m) if m.isfile() else None)
    data = json.dumps(manifest).encode()
    ti = tarfile.TarInfo("manifest.json"); ti.size = len(data); ti.mode = 0o644
    dst.addfile(ti, io.BytesIO(data))
print("written", out)
print("entries:", [e.get("RepoTags") for e in manifest])
print("members written once although present in several sources:", shared)
PYEOF
python3 "$R/combine.py" "$R/shared.tar" "$R/a.tar" "$R/b.tar"
```

Expected output:

- `entries: [['k2s.local/issue3212-layers/a:1'], ['k2s.local/issue3212-layers/b:1']]`.
- The "written once" list contains `<BASE hex>.tar`, plus the compatibility folder files for the base layer
  if Buildah wrote them identically in both archives.
- If the script stops with `conflicting member`, do not work around it. Record the member name; the
  archives differ in a way this guide did not expect.

`repositories` is left out. It is an optional legacy file; the imports in the earlier validation of
`multi-image-tagged.tar`, which also had no `repositories`, succeeded.

---

## 6. Archive-integrity checks

### 6.1 Script for checking the archive (Linux VM, read-only)

```bash
cat > "$R/check_archive.py" <<'PYEOF'
import hashlib, json, sys, tarfile
path, base = sys.argv[1], sys.argv[2]
base_hex = base.split(":", 1)[1]
ok = True
def fail(msg):
    global ok; ok = False; print("FAIL:", msg)
with tarfile.open(path) as t:
    members = t.getmembers()
    names = [m.name for m in members]
    by = {m.name: m for m in members}
    if len(names) != len(set(names)):
        fail("duplicate member names in archive")
    entries = json.load(t.extractfile("manifest.json"))
    if not isinstance(entries, list) or len(entries) != 2:
        fail("manifest.json must be a list with exactly 2 entries"); sys.exit(1)
    for i, e in enumerate(entries):
        print("@%d RepoTags=%s Config=%s Layers=%s" % (i, e.get("RepoTags"), e.get("Config"), e.get("Layers")))
        for ref in [e.get("Config")] + list(e.get("Layers") or []):
            m = by.get(ref)
            if m is None or not m.isfile():
                fail("@%d reference is missing or not a regular file: %s" % (i, ref))
    if [e.get("RepoTags") for e in entries] != [["k2s.local/issue3212-layers/a:1"], ["k2s.local/issue3212-layers/b:1"]]:
        fail("unexpected RepoTags")
    la, lb = entries[0].get("Layers") or [], entries[1].get("Layers") or []
    if len(la) != 2 or len(lb) != 2:
        fail("each entry must have exactly 2 layers")
    else:
        if la[0] != lb[0]:
            fail("entries do not reference the same base-layer member")
        if la[0] != base_hex + ".tar":
            fail("base-layer member %s does not match BASE" % la[0])
        if la[1] == lb[1]:
            fail("application layers are not distinct")
        h = hashlib.sha256()
        f = t.extractfile(by[la[0]])
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
        print("sha256 of base-layer member:", h.hexdigest())
        if h.hexdigest() != base_hex:
            fail("base-layer member content does not match BASE")
        # Identity is decided by SHA-256 content; size only skips hashing members that cannot match.
        copies = []
        for m in members:
            if m.isfile() and m.size == by[la[0]].size:
                h = hashlib.sha256()
                f = t.extractfile(m)
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
                if h.hexdigest() == base_hex:
                    copies.append(m.name)
        print("regular members whose SHA-256 equals BASE:", copies)
        if copies != [la[0]]:
            fail("expected the base-layer content only in member %s, found it in %s" % (la[0], copies))
print("ARCHIVE_OK" if ok else "ARCHIVE_NOT_OK")
sys.exit(0 if ok else 1)
PYEOF
```

### 6.2 Check the final archive

**Linux VM:**

```bash
python3 "$R/check_archive.py" "$R/shared.tar" "$(cat "$R/base-digest.txt")" > "$R/archive-check.txt" 2>&1
echo "check exit status: $?" | tee -a "$R/archive-check.txt"       # must be 0
cat "$R/archive-check.txt"
ls -l "$R/a.tar" "$R/b.tar" "$R/shared.tar"
sha256sum "$R/shared.tar" | tee "$R/shared.tar.sha256"
sudo chown remote "$R/shared.tar"
```

Required:

- `ARCHIVE_OK`.
- The base-layer member referenced by both manifest entries has SHA-256 equal to `BASE`.
- `regular members whose SHA-256 equals BASE` lists only that member. The archive therefore contains the base
  layer's content once. The compatibility folder's `layer.tar` is a symbolic link, not a second copy, and is
  not counted. Member size is used only to skip hashing members that cannot match; it is never treated as
  evidence of identity.
- `shared.tar` is roughly the size of `a.tar` plus `b.tar` minus one 8 MiB base layer (supporting
  indication only).

These checks cover the **archive** only. They say nothing about how the layer is stored after the import.
That is shown by the storage measurements in Sections 7 and 9.

### 6.3 Copy the archive to Windows

**Windows PowerShell** (creates `$Win` and writes one file into it):

```powershell
New-Item -ItemType Directory -Path $Win -ErrorAction Stop | Out-Null
if (Test-Path $Arc) { throw "Refusing to overwrite $Arc" }
scp.exe @Ssh "remote@172.19.1.100:/tmp/k2s-3212-layers-$Run/shared.tar" $Arc
"scp exit code: $LASTEXITCODE"                                        # must be 0
(Get-FileHash $Arc -Algorithm SHA256).Hash | Tee-Object "$Win\shared.tar.sha256.txt"
& "$env:SystemRoot\System32\tar.exe" -xOqf $Arc manifest.json
"tar exit code: $LASTEXITCODE"
```

The Windows SHA-256 must equal the Linux value in `$R/shared.tar.sha256` (compare case-insensitively). The
manifest must show the two entries.

---

## 7. Baseline storage measurement

### 7.1 Measurement script (Linux VM, read-only)

The script only **reads** `layers.json`, `volatile-layers.json` and `images.json`, and runs `du`. It never
writes to the storage. It stops with an explicit error if a file is missing or has an unexpected shape.

```bash
cat > "$R/measure.py" <<'PYEOF'
import datetime, json, os, subprocess, sys
S = "/var/lib/containers/storage"
NS = "k2s.local/issue3212-layers/"
base = sys.argv[1]
if not base.startswith("sha256:") or len(base) != 71:
    sys.exit("ERROR: BASE must look like sha256:<64 hex>")

def load_list(path, required):
    if not os.path.isfile(path):
        sys.exit("ERROR: missing metadata file " + path)
    try:
        with open(path, "r") as f:
            data = json.load(f)
    except ValueError as e:
        sys.exit("ERROR: cannot parse %s (it may be rewritten right now; run again): %s" % (path, e))
    if not isinstance(data, list) or not all(isinstance(x, dict) for x in data):
        sys.exit("ERROR: %s is not a JSON list of objects" % path)
    for x in data:
        missing = [k for k in required if k not in x]
        if missing:
            sys.exit("ERROR: record in %s lacks %s: %s" % (path, missing, x.get("id")))
    return data

def du_kib(path):
    r = subprocess.run(["du", "-s", "--block-size=1K", path], capture_output=True, text=True)
    return r.stdout.split()[0] if r.returncode == 0 and r.stdout else "ERROR(%s)" % r.stderr.strip()

layers = load_list(S + "/overlay-layers/layers.json", ["id", "diff-digest"])
vol_path = S + "/overlay-layers/volatile-layers.json"
volatile = load_list(vol_path, ["id"]) if os.path.exists(vol_path) else []
images = load_list(S + "/overlay-images/images.json", ["id", "layer"])
by = {l["id"]: l for l in layers}

print("timestamp_utc:", datetime.datetime.now(datetime.timezone.utc).isoformat())
print("base_digest:", base)
print("image_layer_records_total:", len(layers))
print("container_layer_records_total (volatile, context only):", len(volatile))
match = [l for l in layers if l.get("diff-digest") == base]
print("records_with_base_digest:", len(match))
for l in match:
    print("  record=%s parent=%s diff-size=%s du_kib(diff)=%s" % (
        l["id"], l.get("parent", "<none>"), l.get("diff-size"), du_kib("%s/overlay/%s/diff" % (S, l["id"]))))

for im in images:
    names = im.get("names") or []
    if not isinstance(names, list):
        sys.exit("ERROR: image %s has non-list names" % im["id"])
    test_names = [n for n in names if n.startswith(NS)]
    if not test_names:
        continue
    chain, t = [], im["layer"]
    while t:
        rec = by.get(t)
        if rec is None:
            chain.append((t, "<record not found>", "")); break
        chain.append((t, rec.get("diff-digest"), du_kib("%s/overlay/%s/diff" % (S, t))))
        t = rec.get("parent")
    print("image id=%s names=%s" % (im["id"], test_names))
    for depth, (rid, dg, kib) in enumerate(reversed(chain)):
        print("  layer[%d] record=%s diff=%s du_kib(diff)=%s" % (depth, rid, dg, kib))
print("overlay_total_kib (supporting evidence only):", du_kib(S + "/overlay"))
PYEOF
```

### 7.2 Take the baseline

**Linux VM:**

```bash
BASE=$(cat "$R/base-digest.txt"); echo "$BASE"
sudo python3 "$R/measure.py" "$BASE" > "$R/before.txt" 2>&1; echo "measure exit status: $?" | tee -a "$R/before.txt"
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | sort > "$R/before-images.txt"
cat "$R/before.txt"
```

Required before you continue:

| Check | Required value |
|---|---|
| `measure exit status` | `0` |
| `records_with_base_digest` | `0` |
| Image lines for `k2s.local/issue3212-layers/` | none |

- If `records_with_base_digest` is not `0`, the base layer already exists in the target storage, and the
  experiment cannot show reuse. Do **not** change the storage to make the baseline clean. Go to
  [Section 11](#11-cleanup) to clean up this run's workspace, then start again with a new run ID, which
  generates a new random base payload.
- If the script reports `ERROR: cannot parse`, the file was probably being rewritten at that moment. Run it
  again. If it fails repeatedly, stop: the measurement is not reliable.

Record `image_layer_records_total` and `overlay_total_kib` in the checklist ([Section 14](#14-evidence-checklist)).

---

## 8. Import (Windows PowerShell) – the cluster-changing step

This step changes the cluster: it imports the two test images into `/var/lib/containers/storage` and creates
the tags `k2s.local/issue3212-layers/a:1` and `k2s.local/issue3212-layers/b:1`. Run nothing else on the
cluster at the same time.

```powershell
if (-not (Test-Path $Arc)) { throw "Archive not found: $Arc" }
$offset = (Get-Item $Log).Length
$out = & $K2s image import -t $Arc -o -v debug 2>&1
$importExitCode = $LASTEXITCODE                   # capture before any other external program runs
$out | ForEach-Object { "$_" } | Set-Content -Path "$Win\import-console.txt"
"k2s image import exit code: $importExitCode" | Tee-Object -FilePath "$Win\import-exit-code.txt"

# k2s.log stays open in K2s, so read only the new part, with shared read access, into a new file.
$fs = [IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite')
try {
    $null = $fs.Seek($offset, 'Begin')
    (New-Object IO.StreamReader($fs)).ReadToEnd() | Set-Content -Path "$Win\import-k2slog.txt"
} finally { $fs.Dispose() }

Select-String -Path "$Win\import-k2slog.txt" -Pattern '\[Import\]|Copying config|will be retried|image-import-failed' |
    ForEach-Object { ($_.Line -replace '\s+\| From:.*$', '').TrimEnd() }
```

- The command uses the existing syntax `k2s image import -t <file>`. `-o` shows the log on the console and
  `-v debug` raises the log level. The archive's two-entry `manifest.json` selects the multi-image path
  automatically, so `--docker-archive` is not needed.
- The console output and the new part of `k2s.log` are written to new files in `$Win`. The existing
  `k2s.log` is not modified.

**Expected** (confirm against the captured files):

- `k2s image import exit code: 0` and `SUCCESS  'k2s image import' completed` in `import-console.txt`.
- In this order:
  - `[Import] Docker archive '…\shared.tar' contains 2 images; importing each entry on 'control-plane'`
  - `[Import] Importing archive entry @0 (k2s.local/issue3212-layers/a:1) on 'control-plane'`
  - `[Import] Importing archive entry @1 (k2s.local/issue3212-layers/b:1) on 'control-plane'`
- No `will be retried` and no `image-import-failed`.

Successful pulls run with `-NoLog`, so the `buildah pull …:@0` / `:@1` command lines themselves are not
logged. The `[Import]` lines are the evidence that the indexed path ran.

Keep `$Arc` until all evidence has been collected.

---

## 9. Post-import measurement

**Linux VM** (read-only):

```bash
{ ls /tmp/k2s-image-import-*.tar >/dev/null 2>&1 && echo LEFTOVER_ARCHIVE || echo CLEANUP_OK; } | tee "$R/import-tmp-check.txt"
BASE=$(cat "$R/base-digest.txt")
sudo python3 "$R/measure.py" "$BASE" > "$R/after.txt" 2>&1; echo "measure exit status: $?" | tee -a "$R/after.txt"
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | sort > "$R/after-images.txt"
cat "$R/after.txt"
echo "== image list changes (only the two test tags may be added):"
diff "$R/before-images.txt" "$R/after-images.txt"
echo "== CRI-O view:"; sudo crictl images | grep issue3212-layers
echo "== expected image IDs (Config members of the archive):"
python3 -c "import json,tarfile,sys; t=tarfile.open(sys.argv[1]); [print(e['RepoTags'], e['Config'][:-5]) for e in json.load(t.extractfile('manifest.json'))]" "$R/shared.tar"
```

Run the temporary-archive check **first** and do not remove such files yourself; it records whether K2s
cleaned up.

Copy the evidence to Windows.

**Windows PowerShell:**

```powershell
foreach ($f in 'base-digest.txt','archive-check.txt','before.txt','after.txt','before-images.txt','after-images.txt','import-tmp-check.txt','shared.tar.sha256') {
    scp.exe @Ssh "remote@172.19.1.100:/tmp/k2s-3212-layers-$Run/$f" "$Win\$f"
    "$f scp exit code: $LASTEXITCODE"
}
```

---

## 10. Expected versus actual results and interpretation

### 10.1 Results table

The "Expected if reused" column states the hypothesis being tested; it is not a result. Fill in "Actual".

| # | Measurement | Before (expected) | After – expected if reused | After – would indicate duplication | Actual before | Actual after |
|---|---|---|---|---|---|---|
| 1 | Import exit code | — | `0` | — | — | |
| 2 | `[Import]` lines for `@0` then `@1` | — | both, in order | — | — | |
| 3 | `records_with_base_digest` | `0` | **`1`** | `2` | | |
| 4 | Parent of the base-digest record | — | `<none>` | — | — | |
| 5 | Base-digest record ID | — | Probably the `BASE` hex. That matches the pattern seen for bottom layers, but is not guaranteed | — | — | |
| 6 | `layer[0]` record of image `a:1` | — | equals row 7 and the record in row 3 | differs from row 7 | — | |
| 7 | `layer[0]` record of image `b:1` | — | equals row 6 | differs from row 6 | — | |
| 8 | `layer[1]` records of `a:1` and `b:1` | — | two different records, both with parent = row 3 record | — | — | |
| 9 | `image_layer_records_total` | N | **N + 3** | N + 4 | | |
| 10 | Image IDs of `a:1`, `b:1` (Buildah and CRI-O) | — | equal to the archive's `Config` names | — | — | |
| 11 | `du_kib(diff)` of the base-digest record | — | about 8,200 KiB, listed **once** | listed twice | — | |
| 12 | `overlay_total_kib` growth (supporting only) | — | about 8.2 MiB plus a few KiB | about 16.4 MiB | | |
| 13 | `/tmp/k2s-image-import-*.tar` after the import | `CLEAN` | `CLEANUP_OK` | — | | |
| 14 | Image-list diff | — | only `a:1` and `b:1` added | — | — | |

### 10.2 Interpretation

**Reuse demonstrated (PASS)** – all of the following:

- Row 3 goes from `0` to `1`.
- Rows 6 and 7 are the same record ID, which is the record in row 3.
- Row 8 shows two distinct application-layer records whose parent is that record.
- Rows 1, 2, 10 and 13 are as expected.

Rows 9, 11 and 12 must agree with this conclusion, but they do not prove it on their own.

**Duplication (FAIL)** – row 3 shows two or more records with the base digest, and `a:1` and `b:1` each use
a different one. Before classifying the result as a failure, check the records' `parent` values:

- If both records have no parent, two records were created for identical content on identical (empty)
  ancestry. That contradicts reuse and is a genuine failure.
- If they have different parents, the images did not share their lower layers. That is a fixture problem,
  not a storage failure: classify the run as **INCONCLUSIVE** and check Section 5.3 again.

**INCONCLUSIVE** if any of the following is true:

- Row 3 was not `0` before the import.
- `check_archive.py` did not print `ARCHIVE_OK`.
- `measure.py` failed, or the metadata could not be read reliably.
- The storage layout differs from [Section 1.3](#13-target-storage-environment-verified) (another root,
  driver or file layout).
- The import failed for a reason unrelated to layers.
- Other activity changed the storage during the run so much that rows 9 or 12 cannot be explained. Rows 3
  and 6–8 do not depend on other activity and remain valid.

A small growth in `overlay_total_kib` alone is **never** proof of reuse. Writable container layers (tracked
in `volatile-layers.json`) also live under `overlay/`, so running Pods change that total.

### 10.3 Expected disk usage

If the base layer is reused, storage should grow by about **one** base payload (8 MiB) plus the two small
application layers and some metadata. That is roughly 8.2 MiB. If it is not reused, growth is roughly
16.4 MiB. These are estimates; filesystem block sizes and metadata make the exact numbers vary.

---

## 11. Cleanup

Clean up **only after** Sections 8–10 are complete and the evidence files are in `$Win`.

### 11.1 Linux VM – check nothing uses the test images (read-only)

```bash
sudo buildah images --no-trunc --format '{{.Name}}:{{.Tag}} {{.ID}}' | grep "^$NS/"
sudo buildah containers --all --format '{{.ContainerID}} {{.ImageName}} {{.ImageID}}' | grep -i issue3212-layers || echo "no Buildah containers use the test images"
sudo crictl ps -a | grep -i issue3212-layers || echo "no CRI-O containers use the test images"
```

Continue only if both container checks print their "no … containers" message. If a container uses a test
image, stop: find out who created it before you remove anything.

The test images share no layers with pre-existing images, because their base layer is new random data.
Removing them cannot affect pre-existing images. Never remove a pre-existing image here.

### 11.2 Linux VM – remove the two test tags (modifies the cluster)

Run one at a time and without `--force`:

```bash
sudo buildah rmi "$NS/a:1"
sudo buildah rmi "$NS/b:1"
```

Do not use `buildah rmi --all`, `--prune`, `--force`, `buildah prune` or `crictl rmi --prune`.

### 11.3 Linux VM – verify the cluster storage is back to baseline (read-only)

```bash
BASE=$(cat "$R/base-digest.txt")
sudo python3 "$R/measure.py" "$BASE" > "$R/cleaned.txt" 2>&1; echo "measure exit status: $?" | tee -a "$R/cleaned.txt"
grep -E 'records_with_base_digest|image_layer_records_total|^image ' "$R/cleaned.txt"
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | sort | diff "$R/before-images.txt" - && echo IMAGES_MATCH_BASELINE
```

Expected:

- `records_with_base_digest: 0`.
- `image_layer_records_total` equal to the baseline.
- No `image` lines.
- `IMAGES_MATCH_BASELINE`.

If not, stop and record what remains.

### 11.4 Linux VM – remove the isolated store and workspace (modifies `/tmp` only)

```bash
bi rmi "$NS/a:1" "$NS/b:1" "$NS/base:1"          # isolated store only; specific names
bi containers --all                              # must list nothing
findmnt -rn | grep -F "$R" || echo "no mounts under $R"
sudo ls -A "$R"
```

`ls -A` must show only: `store`, `run`, `base.bin`, `base.bin.sha256`, `a.txt`, `b.txt`, `a.tar`, `b.tar`,
`shared.tar`, `shared.tar.sha256`, `base-digest.txt`, `combine.py`, `check_archive.py`, `archive-check.txt`,
`measure.py`, `before.txt`, `after.txt`, `cleaned.txt`, `before-images.txt`, `after-images.txt` and
`import-tmp-check.txt`. If anything else is present, stop and inspect it.

Then remove exactly this run's workspace:

```bash
if [[ ! "$RUN" =~ ^[a-z0-9]+$ ]]; then
  echo "REFUSING: invalid RUN '$RUN'"
else
  WS="/tmp/k2s-3212-layers-$RUN"                 # built only from the validated run ID
  if [[ "$R" != "$WS" ]]; then
    echo "REFUSING: R='$R' is not this run's workspace '$WS'"
  elif [[ -L "$WS" || ! -d "$WS" ]]; then
    echo "REFUSING: '$WS' is missing, not a directory, or a symbolic link"
  elif [[ "$(realpath -e -- "$WS")" != "$WS" ]]; then
    echo "REFUSING: '$WS' resolves to '$(realpath -e -- "$WS")'"
  else
    sudo rm -rf --one-file-system -- "$WS"
  fi
fi
ls -ld "/tmp/k2s-3212-layers-$RUN" 2>&1          # "No such file or directory"
```

The deletion runs only when all of these hold:

- The run ID matches `^[a-z0-9]+$`, so it is not empty and contains no `/`, `.`, spaces or wildcards.
- The path is rebuilt from that ID and equals `$R`.
- The path is a real directory, not a symbolic link, and resolves to itself.

As a result, `/tmp`, `/`, a parent directory or any other path can never be passed to `rm`.

### 11.5 Windows PowerShell – remove the archive, keep the evidence

```powershell
Copy-Item -Path "$Win\*.txt", "$Win\*.sha256" -Destination "<your evidence folder>"   # choose a folder first
if ($Run -cnotmatch '^[a-z0-9]+$') { throw "Invalid run ID '$Run'" }
$expectedArc = "C:\temp\k2s-3212-layers-$Run\shared.tar"
if ((Resolve-Path -LiteralPath $Arc -ErrorAction Stop).Path -ne $expectedArc) { throw "Refusing: '$Arc' is not '$expectedArc'" }
Remove-Item -LiteralPath $expectedArc
Get-ChildItem -LiteralPath $Win                           # only evidence files remain
```

Remove `$Win` itself only once you no longer need the evidence files:

```powershell
if ($Run -cnotmatch '^[a-z0-9]+$') { throw "Invalid run ID '$Run'" }
$expectedWin = "C:\temp\k2s-3212-layers-$Run"
if ((Resolve-Path -LiteralPath $Win -ErrorAction Stop).Path -ne $expectedWin) { throw "Refusing: '$Win' is not '$expectedWin'" }
Remove-Item -LiteralPath $expectedWin -Recurse
```

---

## 12. Previous evidence this guide relies on

| Evidence | Source |
|---|---|
| Separate pulls reuse an already stored record (`68b14877de21` shared by images `4a83b15d3ecf` and `cb84a9dbb358`) | Read-only inspection of `layers.json`/`images.json`, 2026-10-16 |
| Same content on different parents is stored in separate records (`4d049f83d9cf…` in 4 records) | Same inspection |
| Buildah-written Docker archives name layers `<digest>.tar` and contain compatibility folders with symbolic links | `tar -tvf /tmp/coredns.tar`, 2026-10-16 |
| Docker-archive image ID equals the `Config` digest | Earlier validation of `registry.k8s.io/pause:3.10.2` |
| K2s copies once and pulls entries in sequence | `Invoke-LinuxNodeImageImport` source and unit test "imports each entry of a two-entry archive once, in order, with an indexed selector" |

---

## 13. Known limitations

- This experiment covers shared-layer reuse during import of **multi-image Docker archives**. It does not
  show support for multi-image OCI archives, which this change does not add.
- The control plane uses Buildah 1.39.3. Compatibility with Debian 12's Buildah 1.28.2 is **unverified**.
- An archive produced by `docker save` with Docker 25 or later is a separate, still open compatibility check.
  This fixture is produced by `buildah push` and `combine.py`; the E2E fixture is generated synthetically.
- The experiment does **not** show that identical layer content on *different* lower layers is deduplicated.
  The current storage keeps such layers in separate records (Section 1.5). That is storage behaviour, not
  K2s behaviour.
- A successful import and a successful Pod start are functional checks only. They do not show that layers
  are stored once.
- The measurement reads internal storage metadata files (`layers.json`, `images.json`). Their format was
  verified on this system only and may differ in other storage versions.
- Unverified assumptions:
  - The base-digest record ID will equal the `BASE` hex (row 5). Only the record's uniqueness and its use by
    both images are required for PASS.
  - Buildah 1.39.3 writes identical compatibility-folder members for the base layer in `a.tar` and `b.tar`.
    If it does not, `combine.py` stops with `conflicting member`, and the guide must be adjusted before
    continuing.

---

## 14. Evidence checklist

Run ID: ______  Date: ______  Tester: ______  Git HEAD: ______  Buildah version: ______

| Item | Value or file | Result |
|---|---|---|
| Preflight (Section 4) passed | | |
| `BASE` digest | `base-digest.txt` | |
| Section 5.3 layer structure correct | | |
| `combine.py` output (shared members) | | |
| `ARCHIVE_OK` | `archive-check.txt` | |
| `shared.tar` SHA-256 (Linux) | `shared.tar.sha256` | |
| `shared.tar` SHA-256 (Windows), equal to Linux | `shared.tar.sha256.txt` | |
| Baseline `records_with_base_digest` = 0 | `before.txt` | |
| Baseline `image_layer_records_total` | `before.txt` | |
| Baseline `overlay_total_kib` | `before.txt` | |
| Import exit code | `import-exit-code.txt` | |
| `[Import]` lines for `@0` and `@1` | `import-k2slog.txt` | |
| `/tmp/k2s-image-import-*.tar` after import | `import-tmp-check.txt` | |
| After `records_with_base_digest` | `after.txt` | |
| Base record ID and parent | `after.txt` | |
| `layer[0]` record of `a:1` / `b:1` | `after.txt` | |
| `layer[1]` records of `a:1` / `b:1` | `after.txt` | |
| After `image_layer_records_total` (baseline + ?) | `after.txt` | |
| `du_kib(diff)` of base record | `after.txt` | |
| `overlay_total_kib` growth | `before.txt`, `after.txt` | |
| Image IDs match `Config` (Buildah and CRI-O) | Section 9 output | |
| Image-list diff only adds the two test tags | Section 9 output | |
| **Classification** (PASS / FAIL / INCONCLUSIVE) and reason | | |
| Cleanup: tags removed, storage back to baseline | `cleaned.txt` | |
| Cleanup: workspace and Windows archive removed | | |
