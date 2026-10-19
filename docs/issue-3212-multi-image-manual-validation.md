<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Issue #3212 – Manual validation of multi-image archive import

This guide is for manually validating the fix for issue #3212, "Support import of multi-image archives".
Follow it one step at a time. Each step says whether it is **read-only** or **modifies** something.

The implementation lives in `lib/scripts/windows/host/image/Image-Common.module.psm1`:

- `Get-DockerArchiveManifestInfo` reads `manifest.json` from the archive with Windows `tar.exe`.
- `Invoke-LinuxNodeImageImport` copies the archive to a unique temporary file
  `/tmp/k2s-image-import-<guid>.tar` on the Linux node and removes it again in a `finally` block.
  - If `manifest.json` has two or more entries, it validates each entry (`Config`, `Layers`, `RepoTags` and
    the referenced archive members) and runs
    `sudo buildah pull docker-archive:/tmp/k2s-image-import-<guid>.tar:@<index>` once per valid entry.
    Invalid entries are skipped and reported as failed; the remaining entries are still imported.
  - Every other archive uses the existing unindexed command: `docker-archive:<temporary file>` with
    `--docker-archive`, otherwise `oci-archive:<temporary file>`.

Automated coverage: the Pester tests in `lib/scripts/windows/host/image/Import-Image.unit.tests.ps1` and the
E2E suite `test/e2e/cluster/imageimport` (synthetic Docker archives, run against a real cluster). This manual
guide additionally covers archives produced from real cluster images and offline Pod execution.

The background and the original failure are described in `docs/issue-3212-multi-image-reproduction.md`.

---

## 1. Environment and prerequisites

| Item | Expected value | How to check |
|---|---|---|
| Windows shell | Elevated **Windows PowerShell 5.1** (not PowerShell 7) | `$PSVersionTable.PSVersion` |
| Repository checkout | `C:\ws\k2s`, branch `3212-multi-image-import` | Section 3, step 1 |
| K2s CLI | `C:\ws\k2s\k2s.exe` | Section 3, step 2 |
| K2s install directory | The same checkout. The fix is in PowerShell scripts that `k2s.exe` loads from its own install directory | Section 3, step 2 |
| Cluster | Running K2s cluster with a Linux control plane | `k2s status` |
| Control-plane IP and user | `172.19.1.100` and `remote` (the K2s defaults in this environment) | Change the variables in Section 2 if yours differ |
| K2s SSH key | `%USERPROFILE%\.ssh\k2s\id_rsa`. Only check that it exists; never print it | Section 3, step 1 |
| Linux tools | `buildah`, `crictl`, `python3`, `tar` on the control plane | Section 3, step 4 |
| Free disk space | At least 1 GB on `C:` and in `/tmp` on the control plane. Each two-image fixture is about 78 MB | Section 3, steps 1 and 4 |
| Source images | `registry.k8s.io/pause:3.10.2` and `registry.k8s.io/coredns/coredns:v1.14.2` on the control plane | Section 3, step 4 |

You need two terminals:

- **Windows PowerShell** (elevated): runs `k2s`, `kubectl`, `scp.exe` and `tar.exe`.
- **Linux control plane**: open it from Windows PowerShell with:

  ```powershell
  k2s node connect -i 172.19.1.100 -u remote
  ```

Commands are not interchangeable between the two shells. Every code block below names the shell it is for.

!!! note
    The source image tags above are system images present on this cluster. If your cluster has different
    versions, change `PAUSE_SRC` and `COREDNS_SRC` in Section 2. Never use production workload images.

---

## 2. Session variables and helper functions

### 2.1 Choose a unique run ID

Every test tag created by this guide has the form `k2s.local/issue3212-<run>/<image>:<tag>`. Use a new,
lowercase run ID (for example `mv1`) that has never been used on this cluster. Section 3, step 5 confirms
it is unused.

!!! warning
    Do not reuse `k2s.local/issue3212/*`. That namespace already exists from earlier validation runs on this
    cluster.

### 2.2 Windows PowerShell (read-only; defines variables and functions only)

Run this block again in every new PowerShell window.

```powershell
$Run    = 'mv1'                                    # unique run ID, lowercase
$K2s    = 'C:\ws\k2s\k2s.exe'                      # change if your k2s.exe is elsewhere
$Win    = "C:\temp\k2s-mv-3212-$Run"               # Windows work directory for this run
$Ns     = "k2s.local/issue3212-$Run"               # test tag namespace
$Cp     = '172.19.1.100'                           # control-plane IP
$Key    = "$env:USERPROFILE\.ssh\k2s\id_rsa"       # K2s-managed key; never print it
$Log    = 'C:\var\log\k2s.log'                     # K2s log file
$Tar    = "$env:SystemRoot\System32\tar.exe"
$PodNs  = "issue3212-$Run"                         # disposable namespace for Scenario G

# Copies one fixture from the control plane. Refuses to overwrite.
function Copy-3212Fixture([string]$Name) {
    $dest = Join-Path $Win $Name
    if (Test-Path $dest) { Write-Warning "Refusing to overwrite $dest"; return }
    scp.exe -o BatchMode=yes -o StrictHostKeyChecking=no -i $Key "remote@${Cp}:/tmp/k2s-mv-3212-$Run/$Name" $dest
    "scp exit code: $LASTEXITCODE"
    Get-FileHash $dest -Algorithm SHA256 | Format-List Path, Hash
}

# Shows the archive markers and manifest entries, and lists referenced members that are missing.
function Show-3212Archive([string]$Name) {
    $p = Join-Path $Win $Name
    $members = & $Tar -tf $p
    "tar -tf exit code: $LASTEXITCODE; member count: $($members.Count)"
    foreach ($m in 'manifest.json', 'index.json', 'oci-layout') { '{0,-14} present: {1}' -f $m, ($members -contains $m) }
    if ($members -contains 'manifest.json') {
        $json = (& $Tar -xOqf $p manifest.json) -join ''
        $entries = $json | ConvertFrom-Json
        "manifest.json entries: $(@($entries).Count)"
        $i = 0
        foreach ($e in $entries) {
            $missing = @(@($e.Config) + @($e.Layers) | Where-Object { $members -notcontains $_ })
            "@$i RepoTags=[$($e.RepoTags -join ', ')] Config=$($e.Config) Layers=$(@($e.Layers).Count) MissingMembers=[$($missing -join ', ')]"
            $i++
        }
    }
    if ($members -contains 'index.json') { 'index.json:'; & $Tar -xOqf $p index.json; '' }
}

# Runs one import, captures the native exit code immediately, and saves the console output and the new
# section of k2s.log.
function Invoke-3212Import([string]$Label, [string[]]$ImportArgs) {
    $offset = (Get-Item $Log).Length
    $out = & $K2s image import @ImportArgs -o -v debug 2>&1
    $code = $LASTEXITCODE                              # capture before any other native command runs
    $global:ImportExitCode = $code
    $out | ForEach-Object { "$_" } | Set-Content -Path "$Win\$Label-console.txt"
    # k2s.log is held open by K2s, so open it with shared read access.
    $fs = [IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite')
    try {
        $null = $fs.Seek($offset, 'Begin')
        (New-Object IO.StreamReader($fs)).ReadToEnd() | Set-Content -Path "$Win\$Label-k2slog.txt"
    } finally { $fs.Dispose() }
    "k2s image import exit code: $code"
    '--- relevant log lines ---'
    Select-String -Path "$Win\$Label-k2slog.txt" -Pattern '\[Import\]|Copying config|expected 1 item|Some layer tarfiles|image-import-failed|will be retried' |
        ForEach-Object { ($_.Line -replace '\s+\| From:.*$', '').TrimEnd() }
    "console: $Win\$Label-console.txt"
    "log:     $Win\$Label-k2slog.txt"
}
```

!!! note
    Use `$LASTEXITCODE` directly after a native command. Any later native command (for example `ssh.exe` or
    `tar.exe`) overwrites it. `Invoke-3212Import` stores the import exit code in `$global:ImportExitCode`.

### 2.3 Linux control plane (read-only; defines variables and functions only)

Run this block again in every new `k2s node connect` session.

```bash
RUN=mv1                                       # must match $Run on Windows
W=/tmp/k2s-mv-3212-$RUN                       # Linux work directory for this run
NS=k2s.local/issue3212-$RUN                   # test tag namespace
PAUSE_SRC=registry.k8s.io/pause:3.10.2
COREDNS_SRC=registry.k8s.io/coredns/coredns:v1.14.2

# Compares the current image list with the baseline and checks for leftover temporary import archives.
check_state() {   # usage: check_state <label>
  sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | sort > "$W/after-$1-buildah.txt"
  echo "== removed or changed since baseline (must be empty):"
  comm -23 "$W/baseline-buildah.txt" "$W/after-$1-buildah.txt"
  echo "== added since baseline (only $NS/... lines are allowed):"
  comm -13 "$W/baseline-buildah.txt" "$W/after-$1-buildah.txt"
  echo "== CRI-O view of test tags:"
  sudo crictl images | grep "issue3212-$RUN" || echo "(none)"
  ls /tmp/k2s-image-import-*.tar >/dev/null 2>&1 && echo LEFTOVER_ARCHIVE || echo CLEANUP_OK
}
```

---

## 3. Safety and baseline checks

### Which steps change something

| Steps | Effect |
|---|---|
| Section 3, steps 1–5 | Read-only |
| Section 3, step 6 | Creates the work directories on Windows and the control plane, and writes the baseline files. The cluster is not changed |
| Section 4 (fixtures) | Writes files to the work directories only. `buildah push` to an archive reads images and does **not** create tags |
| Scenarios A–F | **Modify the cluster.** They add `$NS/...` image tags on the control plane; Scenario D also adds a new image ID |
| Scenario G | **Modifies the cluster.** Creates and then deletes namespace `issue3212-<run>` and one Pod |
| Scenario H and the Scenario I checks | Read-only |
| Scenario I cleanup | **Modifies the cluster.** Removes only the `$NS/...` test tags, then deletes the work directories |

Every import uses its own temporary archive on the node. Still, do not run other imports during this guide: `check_state` would report their temporary archives and image tags.

### Step 1 – Repository, shell and disk space (Windows PowerShell, read-only)

```powershell
Set-Location C:\ws\k2s
$PSVersionTable.PSVersion                       # expect Major 5, Minor 1
git branch --show-current                       # expect 3212-multi-image-import
git status --short                              # record; do not discard anything
git --no-pager log -1 --oneline                 # record the HEAD commit
Test-Path $Key                                  # must be True. Do NOT print the file.
Get-PSDrive C | Select-Object Used, Free         # Free should be at least 1 GB
Test-Path $Win                                  # must be False for a new run ID
```

### Step 2 – The K2s CLI and the scripts it loads (Windows PowerShell, read-only)

```powershell
Test-Path $K2s                                                   # must be True
(Get-Command k2s -ErrorAction SilentlyContinue).Source           # should equal $K2s
& $K2s version
& $K2s image import --help
Select-String -Path 'C:\ws\k2s\lib\scripts\windows\host\image\Image-Common.module.psm1' `
    -Pattern 'function Get-DockerArchiveManifestInfo' | ForEach-Object { "found at line $($_.LineNumber)" }
```

What to verify:

- `--help` lists `-t, --tar`, `--docker-archive`, `-o, --output` and `-v, --verbosity`.
- `Get-DockerArchiveManifestInfo` is found in the checkout.
- The commit shown by `k2s version` is the commit `k2s.exe` was built from. It may differ from the Git HEAD,
  because this fix changes PowerShell scripts, not Go code. What matters is that `k2s.exe` runs scripts from
  this checkout; Scenario A confirms that through the script path printed at debug verbosity.

### Step 3 – Cluster health (Windows PowerShell, read-only)

```powershell
& $K2s status
"k2s status exit code: $LASTEXITCODE"           # expect 0
Get-Command kubectl | Select-Object Source      # needed for Scenario G
kubectl get nodes -o wide                       # control plane must be Ready
kubectl get namespace $PodNs --ignore-not-found # expect no output
```

### Step 4 – Control-plane tools, source images and disk space (Linux control plane, read-only)

```bash
buildah --version                             # record the version
command -v crictl python3 tar                 # all three must resolve
df -h /tmp                                    # at least 1 GB available
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | grep -E "^($PAUSE_SRC|$COREDNS_SRC) "
ls /tmp/k2s-image-import-*.tar >/dev/null 2>&1 && echo STALE_ARCHIVE || echo CLEAN
ls -ld "$W" 2>&1                              # expect "No such file or directory"
```

- Both source images must be listed. Record their 12-character IDs as `PAUSE_ID` and `COREDNS_ID`.
- If a `/tmp/k2s-image-import-*.tar` file exists, **stop**. Another import may be running or may have been
  interrupted. Do not delete it; find out who owns it first (`ls -l /tmp/k2s-image-import-*.tar`, and check
  for running `k2s` processes on Windows).

### Step 5 – Make sure the test tags are unused (Linux control plane, read-only)

```bash
sudo buildah images --format '{{.Name}}:{{.Tag}}' | grep -c "^$NS/" || true    # expect 0
```

If the result is not `0`, choose a different run ID and redo Section 2.

### Step 6 – Create the work directories and record the baseline (modifies files only)

**Linux control plane:**

```bash
mkdir "$W"
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | sort > "$W/baseline-buildah.txt"
sudo crictl images | sort > "$W/baseline-crictl.txt"
wc -l "$W/baseline-buildah.txt"
grep -E "^($PAUSE_SRC|$COREDNS_SRC) " "$W/baseline-buildah.txt"
```

**Windows PowerShell:**

```powershell
New-Item -ItemType Directory -Path $Win | Out-Null
"$Run baseline taken $(Get-Date -Format o)" | Set-Content "$Win\run-info.txt"
```

The baseline lists every image name, tag and ID as they were before testing. Every later `check_state` call
compares against it.

---

## 4. Test fixtures

All fixtures are built on the control plane from the two source images, then copied to Windows with the K2s
key. Original images, tags and earlier archives are never modified.

### 4.1 How the fixtures are built

- **Single-image archives:** `buildah push <image> docker-archive:<file>:<name>` (or `oci-archive:`). This is
  the same command `lib/scripts/windows/host/image/Export-Image.ps1` uses. It writes an archive that refers to
  the image as `<name>` without creating that tag in local storage.
- **Multi-image archives:** the script below combines single-image Docker archives into one valid Docker
  archive, based on the merge procedure in `docs/issue-3212-multi-image-reproduction.md` (Step 2):
  - It copies each config and layer member once. Members are content-addressed, so a duplicate name with the
    same size is skipped, and a duplicate name with a different size stops the script.
  - It writes a single `manifest.json` with one entry per source and the `RepoTags` you pass with `--tags`.
  - It leaves out the optional `repositories` file, so it cannot contradict the new tags.
  - With `--break-entry N`, it points the first layer of entry `N` at `missing/layer.tar`, a member that does
    not exist. This only makes sense for the disposable Scenario F fixture.
  - It refuses to overwrite an existing file and never concatenates TAR files.

### 4.2 Create the fixture script (Linux control plane, writes one file in `$W`)

Paste the whole block. The `PYEOF` lines must start at column 0.

```bash
cat > "$W/mk3212.py" <<'PYEOF'
import argparse, io, json, os, sys, tarfile
p = argparse.ArgumentParser()
p.add_argument("out")
p.add_argument("sources", nargs="+")
p.add_argument("--tags", action="append", required=True,
               help="comma-separated RepoTags for the next manifest entry; repeat once per entry")
p.add_argument("--break-entry", type=int)
a = p.parse_args()
if os.path.exists(a.out):
    sys.exit("refusing to overwrite " + a.out)
manifest = []
for s in a.sources:
    with tarfile.open(s) as t:
        manifest += json.load(t.extractfile("manifest.json"))
if len(a.tags) != len(manifest):
    sys.exit("expected %d --tags values, got %d" % (len(manifest), len(a.tags)))
for entry, tags in zip(manifest, a.tags):
    entry["RepoTags"] = [x for x in tags.split(",") if x]
if a.break_entry is not None:
    manifest[a.break_entry]["Layers"][0] = "missing/layer.tar"
seen = {}
with tarfile.open(a.out, "w") as dst:
    for s in a.sources:
        with tarfile.open(s) as t:
            for m in t.getmembers():
                if m.name in ("manifest.json", "repositories"):
                    continue
                data = t.extractfile(m).read() if m.isfile() else None
                size = len(data) if data is not None else -1
                if m.name in seen:
                    if seen[m.name] != size:
                        sys.exit("conflicting member " + m.name)
                    continue
                seen[m.name] = size
                dst.addfile(m, io.BytesIO(data) if data is not None else None)
    b = json.dumps(manifest).encode()
    ti = tarfile.TarInfo("manifest.json"); ti.size = len(b); ti.mode = 0o644
    dst.addfile(ti, io.BytesIO(b))
print("written", a.out, [e["RepoTags"] for e in manifest])
PYEOF
```

### 4.3 Create the source and single-image archives (Linux control plane, writes files in `$W`)

```bash
sudo buildah push "$PAUSE_SRC"   "docker-archive:$W/src-pause.tar:$NS/src-pause:src"
sudo buildah push "$COREDNS_SRC" "docker-archive:$W/src-coredns.tar:$NS/src-coredns:src"
sudo buildah push "$PAUSE_SRC"   "docker-archive:$W/single-docker.tar:$NS/pause:c"
sudo buildah push "$PAUSE_SRC"   "oci-archive:$W/single-oci.tar:$NS/pause:d"
sudo chown remote "$W"/*.tar          # use "remote", not "remote:remote"; that group does not exist
```

Each command must end without an error. Confirm that no tag was created:
`sudo buildah images --format '{{.Name}}:{{.Tag}}' | grep -c "^$NS/" || true` must still print `0`.

### 4.4 Create the multi-image archives (Linux control plane, writes files in `$W`)

```bash
cd "$W"
python3 mk3212.py multi-A.tar src-pause.tar src-coredns.tar --tags "$NS/pause:a" --tags "$NS/coredns:a"
python3 mk3212.py multi-B.tar src-pause.tar src-coredns.tar --tags "$NS/pause:b" --tags "$NS/coredns:b"
python3 mk3212.py multi-tags.tar src-pause.tar src-coredns.tar --tags "$NS/pause:e1,$NS/pause:e2" --tags "$NS/coredns:e1"
python3 mk3212.py multi-broken.tar src-pause.tar src-coredns.tar --tags "$NS/pause:f1" --tags "$NS/coredns:f1" --break-entry 1
ls -l "$W"/*.tar
cd - >/dev/null
```

Scenarios A and B use separate archives with different tags, so each scenario creates its own new tags.
Without that, the second run could not show that anything was imported.

### 4.5 Fixture summary

| File | Purpose | Format | Entries | Expected tags → image |
|---|---|---|---|---|
| `multi-A.tar` | Scenario A: two images, no flag | Docker | 2 | `@0 $NS/pause:a` → `PAUSE_ID`; `@1 $NS/coredns:a` → `COREDNS_ID` |
| `multi-B.tar` | Scenario B: two images, `--docker-archive` | Docker | 2 | `@0 $NS/pause:b` → `PAUSE_ID`; `@1 $NS/coredns:b` → `COREDNS_ID` |
| `single-docker.tar` | Scenario C: single-image Docker regression | Docker | 1 | `$NS/pause:c` → `PAUSE_ID` |
| `single-oci.tar` | Scenario D: single-image OCI regression | OCI | (`index.json`: 1 manifest) | `$NS/pause:d` → a **new** ID; see Scenario D |
| `multi-tags.tar` | Scenario E: two tags on one entry | Docker | 2 | `@0 $NS/pause:e1`, `$NS/pause:e2` → `PAUSE_ID`; `@1 $NS/coredns:e1` → `COREDNS_ID` |
| `multi-broken.tar` | Scenario F: partial failure | Docker | 2 | `@0 $NS/pause:f1` → `PAUSE_ID`; `@1 $NS/coredns:f1` must **not** be created |

For a Docker archive, the image ID that Buildah reports is the config digest. Each entry's `Config` member
name (`<64 hex>.json`) should therefore start with the expected 12-character image ID.

### 4.6 Copy and inspect the fixtures (Windows PowerShell; writes files in `$Win` only)

```powershell
'single-docker.tar','single-oci.tar','multi-A.tar','multi-B.tar','multi-tags.tar','multi-broken.tar' |
    ForEach-Object { Copy-3212Fixture $_ }
```

Every `scp exit code` must be `0`. Record each SHA-256 hash in the checklist in Section 9.

Then inspect each fixture:

```powershell
Show-3212Archive multi-A.tar
Show-3212Archive multi-B.tar
Show-3212Archive single-docker.tar
Show-3212Archive single-oci.tar
Show-3212Archive multi-tags.tar
Show-3212Archive multi-broken.tar
```

| Fixture | What `Show-3212Archive` must show |
|---|---|
| `multi-A.tar`, `multi-B.tar` | `manifest.json` present; 2 entries with the tags from 4.5; `MissingMembers=[]` for both entries; `Config` starts with `PAUSE_ID` (@0) and `COREDNS_ID` (@1) |
| `single-docker.tar` | `manifest.json` present; 1 entry `[$NS/pause:c]`; `MissingMembers=[]` |
| `single-oci.tar` | `manifest.json` absent; `index.json` and `oci-layout` present; `index.json` has one manifest annotated `org.opencontainers.image.ref.name` = `$NS/pause:d` |
| `multi-tags.tar` | 2 entries; @0 has both `pause:e1` and `pause:e2`; `MissingMembers=[]` for both |
| `multi-broken.tar` | 2 entries; @0 has `MissingMembers=[]`; @1 has exactly `MissingMembers=[missing/layer.tar]` |

If any fixture differs, stop and do not import it.

---

## 5. Common procedure for each import scenario

For each scenario, in this order:

1. **Windows PowerShell:** run the import with `Invoke-3212Import`. It prints the exit code and the
   relevant log lines, and saves the full console output and log section to `$Win\<label>-*.txt`.
2. **Linux control plane:** run `check_state <label>`.
3. Fill in the scenario's row in the Section 9 checklist.

Do not start the next import until the previous one has finished and both steps have been done.

---

## 6. Test scenarios

### Scenario A – Multi-image Docker archive without `--docker-archive`

**Prerequisites:** Section 3 is complete; `multi-A.tar` was inspected; no `/tmp/k2s-image-import-*.tar` file exists.
**Modifies the cluster:** adds `$NS/pause:a` and `$NS/coredns:a`.

1. **Windows PowerShell:**

   ```powershell
   Invoke-3212Import -Label A -ImportArgs @('-t', "$Win\multi-A.tar")
   Select-String -Path "$Win\A-console.txt" -Pattern 'Import-Image\.ps1' | Select-Object -First 1 | ForEach-Object { $_.Line.Trim() }
   ```

2. **Linux control plane:**

   ```bash
   check_state A
   ```

**Expected results:**

- `k2s image import exit code: 0`, and the console shows `SUCCESS  'k2s image import' completed`.
- The script path printed in step 1 is `C:\ws\k2s\lib\scripts\windows\host\image\Import-Image.ps1`, and the
  line does **not** contain `-DockerArchive`.
- The log contains:
  - `[Import] Docker archive '<path>\multi-A.tar' contains 2 images; importing each entry on 'control-plane'`
  - `[Import] Importing archive entry @0 (k2s.local/issue3212-<run>/pause:a) on 'control-plane'`
  - `[Import] Importing archive entry @1 (k2s.local/issue3212-<run>/coredns:a) on 'control-plane'`
  - `Copying config sha256:<PAUSE_ID…>` and `Copying config sha256:<COREDNS_ID…>`
- The log does **not** contain `expected 1 item` or `will be retried`.
- `check_state A`:
  - Nothing is removed or changed since the baseline.
  - Exactly two lines are added: `$NS/coredns:a COREDNS_ID` and `$NS/pause:a PAUSE_ID`.
  - CRI-O lists both tags with the same IDs.
  - It prints `CLEANUP_OK`.

Successful pulls are run with `-NoLog`, so the indexed `buildah pull` command line itself does not appear in
the log. The evidence that the indexed path ran is the `[Import]` lines together with Buildah's output.

**Cleanup:** none yet. Test tags are removed in Scenario I.

### Scenario B – Multi-image Docker archive with `--docker-archive`

**Prerequisites:** Scenario A is done; no `/tmp/k2s-image-import-*.tar` file exists.
**Modifies the cluster:** adds `$NS/pause:b` and `$NS/coredns:b`.

1. **Windows PowerShell:**

   ```powershell
   Invoke-3212Import -Label B -ImportArgs @('-t', "$Win\multi-B.tar", '--docker-archive')
   Select-String -Path "$Win\B-console.txt" -Pattern 'Import-Image\.ps1' | Select-Object -First 1 | ForEach-Object { $_.Line.Trim() }
   ```

2. **Linux control plane:**

   ```bash
   check_state B
   ```

**Expected results:**

- Exit code `0`. The script line contains `-DockerArchive`.
- The same three kinds of `[Import]` lines as in Scenario A, with the `:b` tags.
- `check_state B` adds `$NS/pause:b PAUSE_ID` and `$NS/coredns:b COREDNS_ID`; nothing is removed or changed;
  `CLEANUP_OK`.

**Cleanup:** none yet (Scenario I).

### Scenario C – Single-image Docker archive regression

**Prerequisites:** `single-docker.tar` was inspected; no `/tmp/k2s-image-import-*.tar` file exists.
**Modifies the cluster:** adds `$NS/pause:c`.

1. **Windows PowerShell:**

   ```powershell
   Invoke-3212Import -Label C -ImportArgs @('-t', "$Win\single-docker.tar", '--docker-archive')
   Select-String -Path "$Win\C-k2slog.txt" -Pattern 'contains \d+ images|archive entry @|invalid manifest' |
       Measure-Object | Select-Object -ExpandProperty Count           # expect 0
   ```

2. **Linux control plane:**

   ```bash
   check_state C
   ```

**Expected results:**

- Exit code `0`.
- There are **no** `contains N images`, `archive entry @` or invalid-manifest lines (count `0`). A
  one-entry manifest takes the existing unindexed `docker-archive:<temporary file>` path.
- Buildah output in the log shows `Copying config sha256:<PAUSE_ID…>`.
- `check_state C` adds `$NS/pause:c PAUSE_ID`; nothing is removed; `CLEANUP_OK`.

**Cleanup:** none yet (Scenario I).

### Scenario D – Single-image OCI archive regression

This scenario validates only `k2s image import` of a **single-image OCI archive**. It does **not** validate
add-on or bootstrap workflows that also import OCI archives.

**Prerequisites:** `single-oci.tar` was inspected and has no `manifest.json`; no `/tmp/k2s-image-import-*.tar` file
exists.
**Modifies the cluster:** adds `$NS/pause:d`, which points to a **new** image ID.

1. **Windows PowerShell** (no `--docker-archive`):

   ```powershell
   Invoke-3212Import -Label D -ImportArgs @('-t', "$Win\single-oci.tar")
   Select-String -Path "$Win\D-k2slog.txt" -Pattern 'contains \d+ images|archive entry @|invalid manifest' |
       Measure-Object | Select-Object -ExpandProperty Count           # expect 0
   ```

2. **Linux control plane:**

   ```bash
   check_state D
   sudo buildah inspect --type image --format '{{.Docker.RootFS.DiffIDs}}' "$NS/pause:d"
   sudo buildah inspect --type image --format '{{.Docker.RootFS.DiffIDs}}' "$PAUSE_SRC"
   ```

**Expected results:**

- Exit code `0`; count `0`. Without `manifest.json`, the helper does not change routing, and the existing
  `oci-archive:<temporary file>` path is used.
- `check_state D` adds exactly one line, `$NS/pause:d <ID>`. Nothing is removed or changed: in particular,
  `$PAUSE_SRC` keeps `PAUSE_ID`. `CLEANUP_OK`.
- The new ID will normally **differ** from `PAUSE_ID`. Exporting to an OCI archive converts the image config,
  which gives it a new digest (this was seen in earlier validation). The two `DiffIDs` outputs must be
  identical, which confirms the same layer content. Record the new ID; Scenario I removes this image.

!!! warning
    Do not build an OCI fixture that uses an existing tag such as `registry.k8s.io/pause:3.10.2`. Importing it
    would move that existing tag to the new image ID.

**Cleanup:** none yet (Scenario I).

### Scenario E – Multiple tags on one manifest entry

**Prerequisites:** `multi-tags.tar` was inspected; no `/tmp/k2s-image-import-*.tar` file exists.
**Modifies the cluster:** adds `$NS/pause:e1`, `$NS/pause:e2` and `$NS/coredns:e1`.

1. **Windows PowerShell:**

   ```powershell
   Invoke-3212Import -Label E -ImportArgs @('-t', "$Win\multi-tags.tar")
   ```

2. **Linux control plane:**

   ```bash
   check_state E
   sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | grep -E "^$NS/(pause:e[12]|coredns:e1) "
   ```

**Expected results:**

- Exit code `0`. The log shows `contains 2 images` and
  `Importing archive entry @0 (k2s.local/issue3212-<run>/pause:e1, k2s.local/issue3212-<run>/pause:e2)`.
  Buildah may print `Copying config` once per tag.
- `pause:e1` and `pause:e2` both resolve to `PAUSE_ID`; `coredns:e1` resolves to `COREDNS_ID`.
- CRI-O (`check_state` output) lists all three tags with the same IDs.
- No existing tag is removed or changed; `CLEANUP_OK`.

**Cleanup:** none yet (Scenario I).

### Scenario F – Partial failure

**Prerequisites:** `multi-broken.tar` was inspected (@1 is missing exactly `missing/layer.tar`);
no `/tmp/k2s-image-import-*.tar` file exists.
**Modifies the cluster:** adds `$NS/pause:f1`. `$NS/coredns:f1` must not be created.

1. **Windows PowerShell**:

   ```powershell
   Invoke-3212Import -Label F -ImportArgs @('-t', "$Win\multi-broken.tar")
   if ($global:ImportExitCode -ne 0) { 'overall import failed as expected' } else { 'UNEXPECTED: import reported success' }
   Select-String -Path "$Win\F-console.txt" -Pattern 'image-import-failed|One or more container image imports failed' |
       ForEach-Object { $_.Line.Trim() }
   ```

2. **Linux control plane:**

   ```bash
   check_state F
   sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | grep -E "^$NS/(pause|coredns):f1 " || true
   ```

**Expected results:**

- A **non-zero** exit code (`1` was observed) and `overall import failed as expected`.
- The console shows `One or more container image imports failed - check the log for details` and the error
  code `image-import-failed`.
- The log shows, in order:
  1. `contains 2 images`.
  2. `Importing archive entry @0 (…/pause:f1, config '…')`, followed by Buildah output with `PAUSE_ID`.
  3. `[Import] Skipping archive entry @1 (…/coredns:f1) of '<archive>': invalid manifest.json entry: archive
     member(s) not found: missing/layer.tar`. The missing member is detected before Buildah runs, so there is
     no Buildah call and no retry for @1.
  4. `[ERROR] [Import] Imported 1 of 2 images from '<archive>' on 'control-plane'; failed entries: @1.
     Successfully imported images are kept.`
- An entry that passes validation but is rejected by Buildah (covered by the E2E suite with a layer-count
  mismatch) is reported as `Image import failed for archive entry @<i> …` after the retries
  (`-Retries 3 -Timeout 10`, about 30 seconds).
- `$NS/pause:f1` is present with `PAUSE_ID`. `$NS/coredns:f1` is **absent**.
- Entries that were imported successfully are **not** rolled back. `pause:f1` staying in place is the
  expected behaviour.
- `CLEANUP_OK`: the temporary archive is removed even though the import failed.

If the import fails before the `contains 2 images` line (for example while copying), this scenario did not
test partial failure. Mark it INCONCLUSIVE and investigate the fixture.

**Cleanup:** none yet (Scenario I).

### Scenario G – Offline Pod execution

**Prerequisites:** Scenario A passed (`$NS/pause:a` exists); `kubectl get namespace $PodNs --ignore-not-found`
prints nothing.
**Modifies the cluster:** creates namespace `issue3212-<run>` and Pod `issue3212-pause`, then deletes them.

1. **Windows PowerShell – create the resources:**

   ```powershell
   @"
   apiVersion: v1
   kind: Namespace
   metadata:
     name: $PodNs
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: issue3212-pause
     namespace: $PodNs
   spec:
     nodeSelector:
       kubernetes.io/os: linux
     restartPolicy: Never
     containers:
     - name: pause
       image: $Ns/pause:a
       imagePullPolicy: Never
   "@ | kubectl apply -f -
   "kubectl apply exit code: $LASTEXITCODE"
   ```

   The `nodeSelector` keeps the Pod off Windows nodes. `imagePullPolicy: Never` means the kubelet must use the
   locally imported image and never contacts a registry.

2. **Windows PowerShell – check the result (read-only):**

   ```powershell
   kubectl wait pod/issue3212-pause -n $PodNs --for=condition=Ready --timeout=120s
   "kubectl wait exit code: $LASTEXITCODE"
   kubectl get pod issue3212-pause -n $PodNs -o wide
   kubectl get pod issue3212-pause -n $PodNs -o jsonpath='{.status.containerStatuses[0].imageID}'
   ''
   kubectl get events -n $PodNs --field-selector involvedObject.name=issue3212-pause `
       -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers
   ```

   **Expected results:**

   - `condition met`; `STATUS` is `Running` on the Linux control-plane node.
   - The events include `Pulled` with `Container image "k2s.local/issue3212-<run>/pause:a" already present on
     machine`, followed by `Created` and `Started`.
   - There is **no** `ErrImageNeverPull` event.

3. **Windows PowerShell – cleanup (only the resources created in step 1):**

   ```powershell
   kubectl delete pod issue3212-pause -n $PodNs --wait=true
   kubectl delete namespace $PodNs --wait=true
   kubectl get namespace $PodNs --ignore-not-found      # expect no output
   ```

### Scenario H – Temporary archive cleanup

There is no separate import for this scenario. It collects the temporary-archive checks that `check_state`
made after each import.

- Do **not** remove `/tmp/k2s-image-import-*.tar` files manually before `check_state` has run.
- Expected: `CLEANUP_OK` after Scenarios A, B, C, D and E (successful imports) **and** after Scenario F (a
  failed import).

Summary check (**Linux control plane**, read-only):

```bash
ls /tmp/k2s-image-import-*.tar >/dev/null 2>&1 && echo LEFTOVER_ARCHIVE || echo CLEANUP_OK
```

If `LEFTOVER_ARCHIVE` appears at any point, record which scenario left it and preserve the log for that
scenario. Do not delete the file until the cause is understood.

### Scenario I – Post-test integrity and cleanup

#### I.1 Integrity check (Linux control plane, read-only)

```bash
check_state final
comm -23 "$W/baseline-buildah.txt" "$W/after-final-buildah.txt" | wc -l          # expect 0
comm -13 "$W/baseline-buildah.txt" "$W/after-final-buildah.txt" | grep -vc "^$NS/" || true   # expect 0
grep -E "^($PAUSE_SRC|$COREDNS_SRC) " "$W/after-final-buildah.txt"                # IDs unchanged from baseline
```

- No baseline line may be missing or changed.
- Every added line must be a `$NS/...` test tag.

#### I.2 Artifacts created by this guide

| Location | Artifact |
|---|---|
| Control-plane image tags | `$NS/pause:a`, `:b`, `:c`, `:d`, `:e1`, `:e2`, `:f1`; `$NS/coredns:a`, `:b`, `:e1` |
| Control-plane images | The image behind `$NS/pause:d` (new ID from Scenario D). All other test tags point to existing images |
| Control-plane files | `$W` (`/tmp/k2s-mv-3212-<run>`): fixtures, `mk3212.py`, baseline and `after-*` files |
| Windows files | `$Win` (`C:\temp\k2s-mv-3212-<run>`): fixtures, `run-info.txt`, `*-console.txt`, `*-k2slog.txt` |
| Kubernetes | Namespace `issue3212-<run>` and Pod `issue3212-pause`, already deleted at the end of Scenario G |

Copy the evidence files you want to keep out of `$Win` **before** cleanup.

#### I.3 Before removing anything (read-only)

**Windows PowerShell:**

```powershell
kubectl get namespace $PodNs --ignore-not-found           # expect no output
```

**Linux control plane:**

```bash
sudo crictl ps -a | grep -E "issue3212|$NS" || echo "no CRI-O containers reference the test tags"
sudo buildah containers | grep -E "$NS" || echo "no Buildah containers reference the test tags"
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | grep "^$NS/"           # review this list
```

Do not continue unless both container checks report nothing.

Most test tags share an image ID with `$PAUSE_SRC` or `$COREDNS_SRC`, which the cluster itself uses.
Remove test tags **by name, one at a time**, and never by image ID. For an image with several names, removing
one name should only remove that name. Confirm this after each command before continuing.

#### I.4 Remove the test tags (Linux control plane, modifies the cluster)

Run the commands one at a time and check the result after each:

```bash
sudo buildah rmi "$NS/pause:a"
grep -E "^$PAUSE_SRC " <(sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}')   # must still show PAUSE_ID
```

If `$PAUSE_SRC` still shows `PAUSE_ID`, continue with the rest, still one at a time:

```bash
sudo buildah rmi "$NS/pause:b"
sudo buildah rmi "$NS/pause:c"
sudo buildah rmi "$NS/pause:e1"
sudo buildah rmi "$NS/pause:e2"
sudo buildah rmi "$NS/pause:f1"
sudo buildah rmi "$NS/coredns:a"
sudo buildah rmi "$NS/coredns:b"
sudo buildah rmi "$NS/coredns:e1"
sudo buildah rmi "$NS/pause:d"        # removes the Scenario D image if no other name refers to it
```

Never use `buildah rmi --all`, `buildah rmi --prune`, `crictl rmi --prune`, or any command that targets all
images or all containers.

#### I.5 Final verification (Linux control plane, read-only)

```bash
check_state cleaned
diff "$W/baseline-buildah.txt" "$W/after-cleaned-buildah.txt" && echo "MATCHES_BASELINE"
```

Expected: `MATCHES_BASELINE` and `CLEANUP_OK`. The CRI-O section prints `(none)`.

#### I.6 Remove the work directories (modifies files only)

Run this only after you have saved the evidence you need.

**Linux control plane:**

```bash
rm -f "$W"/mk3212.py "$W"/src-pause.tar "$W"/src-coredns.tar "$W"/single-docker.tar "$W"/single-oci.tar \
      "$W"/multi-A.tar "$W"/multi-B.tar "$W"/multi-tags.tar "$W"/multi-broken.tar \
      "$W"/baseline-*.txt "$W"/after-*.txt
rmdir "$W"                              # fails if anything unexpected is left; inspect before removing it
```

**Windows PowerShell:**

```powershell
Get-ChildItem $Win | Select-Object Name, Length   # review first
'single-docker.tar','single-oci.tar','multi-A.tar','multi-B.tar','multi-tags.tar','multi-broken.tar','run-info.txt' |
    ForEach-Object { Remove-Item -LiteralPath (Join-Path $Win $_) }
Get-ChildItem $Win -Filter '*-console.txt' | Remove-Item
Get-ChildItem $Win -Filter '*-k2slog.txt' | Remove-Item
Remove-Item -LiteralPath $Win                      # fails if the directory is not empty
```

---

## 7. Evidence to collect

For each scenario, keep:

- The exit code printed by `Invoke-3212Import` (or by `kubectl` in Scenario G).
- `$Win\<label>-console.txt` and `$Win\<label>-k2slog.txt`.
- The `check_state <label>` output from the Linux control plane.
- For Scenario D, both `DiffIDs` outputs and the new image ID.
- For Scenario G, the `kubectl get pod -o wide` output and the Pod events.

---

## 8. Scope and known limitations

- **In scope:** importing multi-image **Docker** archives with `k2s image import` onto Linux nodes, with or
  without `--docker-archive`.
- **Not supported by this change:** multi-image **OCI** archives. They still use the existing single
  `oci-archive:` import.
- **Out of scope:** single-image archives with several tags whose routing depends on multiple `index.json`
  descriptors, when `--docker-archive` is omitted.
- **Not verified:** compatibility with Debian 12's Buildah 1.28.2 (containers/image 5.23.1). Earlier
  validation used Buildah 1.39.3.
- **Not tested:** a genuine archive produced by `docker save` with Docker 25 or later (no Docker daemon is
  available in the validation environment). The fixtures in this guide are produced by `buildah push` and a
  Python script; the E2E suite generates synthetic archives in the current `docker save` layout. Neither proves
  compatibility with a real `docker save` archive.
- **Linux hosts:** the native Linux host provider (`Import-Image.sh`, experimental) is not changed.
- **Windows worker images:** `k2s image import -w` still copies to a fixed `C:\Windows\Temp\import.tar` on
  remote Windows workers; this change does not affect Windows image imports.
- **Retries:** a pull that Buildah rejects is retried even when the failure cannot recover, adding about 30
  seconds. Entries rejected by the manifest validation are not retried.
- **No claim is made** that add-on or bootstrap flows have been validated by this guide.

---

## 9. Execution checklist

Run ID: ________  Date: ________  Tester: ________  Git HEAD: ________  Buildah version: ________

`PAUSE_ID`: ________  `COREDNS_ID`: ________

| Fixture | SHA-256 |
|---|---|
| `multi-A.tar` | |
| `multi-B.tar` | |
| `single-docker.tar` | |
| `single-oci.tar` | |
| `multi-tags.tar` | |
| `multi-broken.tar` | |

| Scenario | Pass/Fail | Observed exit code | Image IDs or Pod name | Log or evidence location | Notes |
|---|---|---|---|---|---|
| Section 3 – Safety and baseline | | | | | |
| Section 4 – Fixtures created and inspected | | | | | |
| A – Multi-image, no flag | | | | | |
| B – Multi-image, `--docker-archive` | | | | | |
| C – Single-image Docker regression | | | | | |
| D – Single-image OCI regression | | | | | |
| E – Multiple tags on one entry | | | | | |
| F – Partial failure | | | | | |
| G – Offline Pod execution | | | | | |
| H – Temporary archive cleanup | | | | | |
| I – Post-test integrity and cleanup | | | | | |

Use **PASS** (verified with evidence), **FAIL** (contradicts the expected result), **NOT RUN**, or
**INCONCLUSIVE** (ran, but did not prove the expected behaviour).
