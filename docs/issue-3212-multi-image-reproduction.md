<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Issue #3212 – Reproducing the multi-image archive import failure

This runbook reproduces issue #3212, "Support import of multi-image archives". It builds one valid Docker
archive that holds two images and imports it with `k2s image import` from Windows.

## Labels and outcome

Every command is marked with one of these labels:
- **Verified**: run successfully in this environment on 2026-10-15.
- **Source-verified**: confirmed by reading the source, but not run.
- **Proposed**: not run as written. The label explains how to check it safely first.

**Outcome on 2026-10-15: REPRODUCED.**
- The archive was valid and the transfer succeeded.
- The import reached `sudo buildah pull docker-archive:/tmp/import.tar`, which exited with code 125 and printed `Error: Unexpected tar manifest.json: expected 1 item, got 2`.
- A single-image control test using the same path and flags succeeded.

**Status after the fix (2026-10-16):** this runbook documents the behaviour *before* the fix and reproduces
the failure only on code without it. With the fix, K2s copies the archive to a unique
`/tmp/k2s-image-import-<guid>.tar` (instead of `/tmp/import.tar`) and imports each entry with
`docker-archive:<file>:@<index>`. The same archive (SHA-256 `cb7807b8…b950`) was imported again with
`k2s image import -t C:\temp\multi-image.tar --docker-archive -o`: exit code `0`, entries `@0`
(`registry.k8s.io/pause:3.10.2`) and `@1` (`registry.k8s.io/coredns/coredns:v1.14.2`) were pulled, the image
ID/name list of the control plane was unchanged (both images were already present with the same IDs), and no
temporary archive was left. See `docs/issue-3212-multi-image-manual-validation.md` for validating the fix.

## 1. Prerequisites and environment assumptions

| Item | Value | Status |
|---|---|---|
| Repository / install dir | `C:\ws\K2s` | Verified |
| Windows shell | **Elevated** Windows PowerShell 5.1 (`Import-Image.ps1` has `#Requires -RunAsAdministrator`) | Verified |
| Setup type | `k2s`, Hyper-V control-plane VM `kubemaster`, running | Verified |
| Control-plane IP / user | `172.19.1.100` / `remote` | Verified |
| K2s SSH private key (path only, never print it) | `%USERPROFILE%\.ssh\k2s\id_rsa` | Verified for Windows user `ad005\z004w50d` |
| Windows SSH tools | `C:\WINDOWS\System32\OpenSSH\ssh.exe`, `scp.exe` | Verified |
| Linux tools | `buildah` 1.39.3, `python3`, `tar`. `podman` and `skopeo` are **not** installed | Verified |
| `remote` can run `sudo` without a password | Yes (K2s itself runs `sudo buildah` non-interactively) | Verified |
| Existing VM images | `registry.k8s.io/pause:3.10.2` (ID `4a83b15d3ecf`), `registry.k8s.io/coredns/coredns:v1.14.2` (ID `38667dd9be96`) | Verified |
| Existing single-image Docker archives | `/tmp/pause.tar` (745472 B), `/tmp/coredns.tar` (77307392 B), both owned by root | Verified |
| K2s log file | `C:\var\log\k2s.log` | Verified |

No Docker is needed and nothing is installed.

## 2. Import code path and supported formats (Source-verified)

1. `k2s image import` runs `importImage` in `cmd/k2s/cmd/image/import.go`, which calls `context.Providers().Image.Import(ImageImportConfig{...})`.
2. `windowsImageProvider.Import` in `internal/provider/image_windows.go` runs
   `lib\scripts\windows\host\image\Import-Image.ps1 -ImagePath '<path>' [-DockerArchive] [-ShowLogs]`.
   This command line appears in the `-v debug` output (Verified).
3. Without `--node` or `-w`, `Import-Image.ps1` calls `Invoke-LinuxNodeImageImport` in `Image-Common.module.psm1`, which does the following:
   - Copies the file: `Copy-ToControlPlaneViaSSHKey <path> /tmp/import.tar`. This calls `Copy-ToRemoteComputerViaSshKey`, then `Invoke-SCPWithKey`, which runs
     `scp.exe -o BatchMode=yes -o StrictHostKeyChecking=no -i <key> -r <src> remote@<ip>:/tmp/import.tar`
     (`lib\modules\windows\node\k2s.node.module\linuxnode\vm\vm.module.psm1`).
   - Runs **one** pull with no image selector:
     - with `--docker-archive`: `sudo buildah pull docker-archive:/tmp/import.tar 2>&1`
     - without it (default): `sudo buildah pull oci-archive:/tmp/import.tar 2>&1`
   - Uses `-Retries 3 -Timeout 10` on the pull.
   - Cleans up with `sudo rm -f /tmp/import.tar`.
4. The key comes from `Get-SSHKeyControlPlane` in `lib\modules\windows\infra\k2s.infra.module\config\config.module.psm1`. It looks under `<profile>\.ssh\k2s\id_rsa`. The user is `$defaultUserName = 'remote'`.

**Formats on the Windows host path:** an OCI archive (default) or a Docker archive (`--docker-archive`). Each is
pulled as a single image. Buildah rejects a Docker archive with more than one image unless a selector is given
(`:@N` or `:name:tag`), and K2s never passes one.

**Native Linux provider** (experimental Linux hosts only, not used here): `lib/scripts/linux/debian/host/image/Import-Image.sh`
tries `buildah pull oci-archive:$file`, then `buildah pull docker-archive:$file`. It also uses no selector and
tags only `manifest.json[0].RepoTags[0]`. This is Source-verified only.
`lib/scripts/linux/debian/host/image/Export-Image.sh` exports exactly one image per archive
(`buildah push <id> <format>:<tar>:<name>`).

**Test fixtures:** no repository fixture contains a multi-image archive (Verified by search).
- `Import-Image.unit.tests.ps1` mocks `'image.tar'`.
- The only `*.tar*` files are `addons\dashboard\build\plugins\*.tar.gz`, which are not container images.

## 3. Procedure

Shell legend:
- 🪟 = **Windows PowerShell (elevated)**
- 🐧 = **Linux VM**, using the interactive shell from `k2s node connect -i 172.19.1.100 -u remote`

### Step 0 – Pre-flight checks (read-only)

🪟 **Verified**
```powershell
k2s status
Test-Path "$env:USERPROFILE\.ssh\k2s\id_rsa"   # must be True. Do NOT print the file.
whoami
Test-Path C:\temp\multi-image.tar               # must be False. If True, run Section 6 first.
Test-Path C:\temp\pause.tar                     # must be False. If True, run Section 6 first.
```

> **Note (2026-10-15):** artifacts from the verification run still exist:
> - Windows: `C:\temp\multi-image.tar`, `C:\temp\pause.tar`, `%TEMP%\k2s-3212-import.txt`
> - VM: `/tmp/k2s-repro-3212/` (`before.txt`, `multi-image.tar`)
>
> Run Section 6 first to start clean.

🪟 Open the Linux shell (**Verified**):
```powershell
k2s node connect -i 172.19.1.100 -u remote
```

🐧 **Verified**
```bash
buildah --version
ls -l /tmp/pause.tar /tmp/coredns.tar
ls -ld /tmp/k2s-repro-3212 2>&1     # expect "No such file or directory"
sudo buildah images | grep -E 'REPOSITORY|pause|coredns'
```

### Step 1 – Record the VM image baseline

🐧 **Verified**
```bash
mkdir -p /tmp/k2s-repro-3212
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | sort > /tmp/k2s-repro-3212/before.txt
wc -l < /tmp/k2s-repro-3212/before.txt
```
Observed result: `10`.

### Step 2 – Create a valid two-image Docker archive (no TAR concatenation)

How the script works:
- It reads both single-image archives.
- It copies every config and layer entry once. Names are content-addressed, so a duplicate name with the same size is skipped, and a duplicate name with a different size aborts the script.
- It writes one merged `manifest.json` array and one merged `repositories` map.
- It refuses to overwrite an existing file.

🐧 **Verified.** Paste the block exactly as shown; the `PYEOF` lines must start at column 0.
```bash
cat > /tmp/k2s-repro-3212/make-multi-image.py <<'PYEOF'
import io, json, os, sys, tarfile
out = sys.argv[1]
srcs = sys.argv[2:]
if os.path.exists(out):
    sys.exit("refusing to overwrite " + out)
manifest, repos, seen = [], {}, {}
with tarfile.open(out, "w") as dst:
    for s in srcs:
        with tarfile.open(s) as t:
            manifest += json.load(t.extractfile("manifest.json"))
            if "repositories" in t.getnames():
                for r, tags in json.load(t.extractfile("repositories")).items():
                    repos.setdefault(r, {}).update(tags)
            for m in t.getmembers():
                if m.name in ("manifest.json", "repositories"):
                    continue
                data = t.extractfile(m).read() if m.isfile() else None
                size = len(data) if data is not None else -1
                if m.name in seen:
                    if seen[m.name] != size:
                        sys.exit("conflicting entry " + m.name)
                    continue
                seen[m.name] = size
                dst.addfile(m, io.BytesIO(data) if data is not None else None)
    for name, obj in (("manifest.json", manifest), ("repositories", repos)):
        b = json.dumps(obj).encode()
        ti = tarfile.TarInfo(name); ti.size = len(b); ti.mode = 0o644
        dst.addfile(ti, io.BytesIO(b))
print("written", out, "images:", [m["RepoTags"] for m in manifest])
PYEOF

sudo python3 /tmp/k2s-repro-3212/make-multi-image.py \
  /tmp/k2s-repro-3212/multi-image.tar /tmp/pause.tar /tmp/coredns.tar
sudo chown remote /tmp/k2s-repro-3212/multi-image.tar
```
- `sudo` is needed because the source archives are owned by root.
- Use `chown remote`, not `remote:remote`. The group `remote` does not exist (Verified error: `chown: invalid group`).

Observed output:
```text
written /tmp/k2s-repro-3212/multi-image.tar images: [['registry.k8s.io/pause:3.10.2'], ['registry.k8s.io/coredns/coredns:v1.14.2']]
```

### Step 3 – Validate the archive in the VM

🐧 **Verified**
```bash
cat > /tmp/k2s-repro-3212/validate-archive.py <<'PYEOF'
import json, sys, tarfile
t = tarfile.open(sys.argv[1]); n = set(t.getnames()); ok = True
mf = json.load(t.extractfile("manifest.json"))
print("images in manifest.json:", len(mf))
for m in mf:
    c = m["Config"] in n; l = all(x in n for x in m["Layers"]); ok &= c and l
    print(m["RepoTags"], "config:", c, "layers:", len(m["Layers"]), "all present:", l)
print("VALID" if ok and len(mf) >= 2 else "INVALID")
PYEOF

python3 /tmp/k2s-repro-3212/validate-archive.py /tmp/k2s-repro-3212/multi-image.tar
ls -l /tmp/k2s-repro-3212/multi-image.tar
sha256sum /tmp/k2s-repro-3212/multi-image.tar
```
Observed output (two independent builds gave the same hash):
```text
images in manifest.json: 2
['registry.k8s.io/pause:3.10.2'] config: True layers: 1 all present: True
['registry.k8s.io/coredns/coredns:v1.14.2'] config: True layers: 13 all present: True
VALID
-rw-r--r-- 1 remote root 78059520 ... /tmp/k2s-repro-3212/multi-image.tar
cb7807b885745bed21de0dc73f35ed3873059791c16ef96ca78a97791534b950  /tmp/k2s-repro-3212/multi-image.tar
```

Optional proof that Buildah can read the archive when an image is selected (🐧 **Verified**):
```bash
sudo buildah pull docker-archive:/tmp/k2s-repro-3212/multi-image.tar:@1; echo "exit=$?"
```
- Observed: 13 blobs and the config were copied, then `Writing manifest to image destination`, `38667dd9be96...` and `exit=0`.
- This is a no-op on the store because coredns is already present. The image list was identical to the baseline afterwards.

Leave the VM shell with `exit`.

### Step 4 – Copy the archive to Windows with the K2s SSH key

Your earlier `scp` attempt failed with `Permission denied (publickey,password)` because it did not pass K2s's key.
The command below uses the same options as K2s's `Invoke-SCPWithKey` and references only the key **path**.

🪟 **Verified**
```powershell
$k2sKey = "$env:USERPROFILE\.ssh\k2s\id_rsa"
New-Item -ItemType Directory -Path C:\temp -Force | Out-Null
scp.exe -o BatchMode=yes -o StrictHostKeyChecking=no -i $k2sKey `
  remote@172.19.1.100:/tmp/k2s-repro-3212/multi-image.tar C:\temp\multi-image.tar
"scp exit code: $LASTEXITCODE"
```
Observed result: `scp exit code: 0`.

### Step 5 – Validate the archive on Windows

🪟 **Verified**
```powershell
Get-Item C:\temp\multi-image.tar | Select-Object FullName, Length
(Get-FileHash C:\temp\multi-image.tar -Algorithm SHA256).Hash.ToLower()
$mf = tar.exe -xOf C:\temp\multi-image.tar manifest.json | Out-String | ConvertFrom-Json
"images in manifest.json: $(@($mf).Count)"
@($mf) | ForEach-Object { "$($_.RepoTags -join ',')  layers=$($_.Layers.Count)" }
```
Observed output:
```text
C:\temp\multi-image.tar  78059520
cb7807b885745bed21de0dc73f35ed3873059791c16ef96ca78a97791534b950
images in manifest.json: 2
registry.k8s.io/pause:3.10.2  layers=1
registry.k8s.io/coredns/coredns:v1.14.2  layers=13
```

### Step 6 – Run the K2s import (the reproduction)

🪟 **Verified.** In the verification run the log was saved to `%TEMP%\k2s-3212-import.txt`; the path below is the only difference.
```powershell
k2s image import -t C:\temp\multi-image.tar --docker-archive -o -v debug 2>&1 |
  Tee-Object -FilePath C:\temp\k2s-repro-3212-import.log
"k2s exit code: $LASTEXITCODE"
```
Observed output (abridged; timestamps differ):
```text
DEBUG Execution script └ script: &'C:\ws\K2s\lib\scripts\windows\host\image\Import-Image.ps1' -EncodeStructuredOutput -MessageType CmdResult  -ImagePath 'C:\temp\multi-image.tar'  -DockerArchive  -ShowLogs
⏳ Importing image C:\temp\multi-image.tar. This can take some time...
⏳ Copying 'C:\temp\multi-image.tar' to '/tmp/import.tar', ignoring errors: 'False'
⏳ Error occurred while executing command 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' in control plane (exit code: '125')
⏳ cmd: sudo buildah pull docker-archive:/tmp/import.tar 2>&1 will be retried..
   ... (repeated for each retry, 4 attempts in total) ...
⏳ Error: Unexpected tar manifest.json: expected 1 item, got 2
⏳[ERROR] [Import] Image import failed on 'control-plane'
  ERROR   One or more container image imports failed - check the log for details
ERROR command failed ├ code: image-import-failed
k2s exit code: 1
```

Confirm the error in the K2s log (🪟 **Verified**):
```powershell
Select-String -Path C:\var\log\k2s.log -Pattern 'expected 1 item, got 2' | Select-Object -Last 1 | ForEach-Object Line
```
Observed output:
```text
[15-10-2026 11:12:33] | Msg: Error: Unexpected tar manifest.json: expected 1 item, got 2 | From: [Image-Common.module.psm1](Invoke-LinuxNodeImageImport)
```

Cross-check by running the same Buildah command directly, outside K2s (🐧 **Verified**):
```bash
sudo buildah pull docker-archive:/tmp/k2s-repro-3212/multi-image.tar; echo "exit=$?"
```
Observed output:
```text
Error: Unexpected tar manifest.json: expected 1 item, got 2
exit=125
```

### Step 7 – Check whether the images were imported

🐧 **Verified**
```bash
ls -l /tmp/import.tar 2>&1    # expect "No such file or directory" (K2s cleanup ran)
sudo buildah images --format '{{.Name}}:{{.Tag}} {{.ID}}' | sort | diff /tmp/k2s-repro-3212/before.txt - && echo "image list unchanged"
```
Observed result: `/tmp/import.tar` is gone and the output is `image list unchanged`. **Neither image was imported.**

**Limitation:** both images already exist in the store, so a successful import after a future fix cannot be proven by presence alone.
- Check the import log for both `Copying config sha256:4a83b15d...` and `Copying config sha256:38667dd9...`, plus `k2s exit code: 0`.
- Do not delete the existing images to work around this.

### Step 8 – Single-image control test

🪟 **Verified.** The pause image is already present, so its ID does not change.
```powershell
$k2sKey = "$env:USERPROFILE\.ssh\k2s\id_rsa"
scp.exe -o BatchMode=yes -o StrictHostKeyChecking=no -i $k2sKey remote@172.19.1.100:/tmp/pause.tar C:\temp\pause.tar
"scp exit code: $LASTEXITCODE"
tar.exe -xOf C:\temp\pause.tar manifest.json
k2s image import -t C:\temp\pause.tar --docker-archive -o -v debug
"k2s exit code: $LASTEXITCODE"
```
Observed output:
```text
scp exit code: 0
[{"Config":"4a83b15d...json","RepoTags":["registry.k8s.io/pause:3.10.2"],"Layers":["68b14877...tar"]}]
⏳ Copying 'C:\temp\pause.tar' to '/tmp/import.tar', ignoring errors: 'False'
⏳ Getting image source signatures
⏳ Copying blob sha256:68b14877de21ededb2711dcda9ab929d66a57f9fe2d6abb9a1593372648ccea8
⏳ Copying config sha256:4a83b15d3ecfe0d916b2d0a7991bc2854a629b8097017c2ee1ff65b30ae4c07c
⏳ Writing manifest to image destination
DEBUG Unmarshaling message message: {"Error":null}
k2s exit code: 0
```
Then repeat Step 7 (🐧). Observed result: `image list unchanged`, and `/tmp/import.tar` was removed.

## 4. Interpretation

| Check | Result |
|---|---|
| Archive is valid: 2 manifest entries, all configs and layers present, readable by Buildah with `:@1` | ✅ Verified |
| Transfer VM→Windows (scp with key) and Windows→VM (K2s `Copy-ToControlPlaneViaSSHKey`) | ✅ Verified |
| Import reaches `sudo buildah pull docker-archive:/tmp/import.tar` | ✅ Verified |
| Buildah exits with 125: `Unexpected tar manifest.json: expected 1 item, got 2` | ✅ Verified |
| Single-image control test with the same flags passes | ✅ Verified |

This is the real issue #3212. It is **not** caused by setup, transfer or archive generation.
`Invoke-LinuxNodeImageImport` runs one `buildah pull docker-archive:<file>` without an image selector, and Buildah
rejects that for an archive containing more than one image. **The existing import path cannot import a multi-image archive without a code change.**

## 5. Troubleshooting

| Symptom | Meaning | Safe action |
|---|---|---|
| Error about `C:\temp\multi-image.tar` not found, or `Could not copy ...` **before** any `buildah` line | The archive is missing on Windows. **Not** #3212 | Repeat Step 4, then run `Test-Path C:\temp\multi-image.tar` |
| `Permission denied (publickey,password)` from `scp`/`ssh` | The key was not passed with `-i`, or a different user profile is in use | Read-only checks: `whoami`; `Test-Path "$env:USERPROFILE\.ssh\k2s\id_rsa"`; `Get-ChildItem C:\Users\*\.ssh\k2s\id_rsa -ErrorAction SilentlyContinue \| Select-Object FullName`. Do **not** print the key or change its ACLs |
| `refusing to overwrite ...` (Step 2) | Leftovers from an earlier run | Run Section 6, then restart from Step 1 |
| `conflicting entry ...` (Step 2) | Same entry name with different content in the two sources | Stop. Re-export the sources (one image each) |
| Validation prints `INVALID` | Missing config or layer, or fewer than 2 images | Do not import. Rebuild the archive |
| `chown: invalid group: 'remote:remote'` | The group does not exist | Use `chown remote` |
| `Error: loading index: open /var/tmp/container_images_oci.../index.json: no such file or directory` | `--docker-archive` was omitted, so K2s used `oci-archive:` on a Docker archive. **Not** #3212. Verified by running `sudo buildah pull oci-archive:/tmp/k2s-repro-3212/multi-image.tar` directly | Repeat Step 6 with `--docker-archive` |
| `Unexpected tar manifest.json: expected 1 item, got 2` (exit 125) | **Issue #3212** | Record the result in Section 7 |
| `#Requires -RunAsAdministrator` error | PowerShell is not elevated | Reopen PowerShell as Administrator |

## 6. Cleanup (temporary artifacts from this procedure only)

These steps never touch container images, `/tmp/pause.tar` or `/tmp/coredns.tar`.

🪟 **Proposed.** The `Get-Item` listing is Verified; `Remove-Item` was not run. Check the listing before removing anything.
```powershell
$paths = 'C:\temp\multi-image.tar', 'C:\temp\pause.tar', 'C:\temp\k2s-repro-3212-import.log', "$env:TEMP\k2s-3212-import.txt"
Get-Item $paths -ErrorAction SilentlyContinue | Select-Object FullName, Length
Remove-Item $paths -ErrorAction SilentlyContinue
```

🐧 **Proposed.** The `ls` is Verified. The same `rm -rf` on a scratch directory (`/tmp/k2s-repro-3212-verify`) was Verified; on this path it was not run. Make sure the listing shows only `before.txt`, `multi-image.tar` and the two `.py` scripts.
```bash
ls -la /tmp/k2s-repro-3212
rm -rf /tmp/k2s-repro-3212
```

## 7. Results checklist

| # | Step | Expected | Actual output / notes | ✅/❌ |
|---|---|---|---|---|
| 0 | Pre-flight | key path `True`; no leftovers; both images listed | | |
| 1 | Baseline | line count recorded | | |
| 2 | Create archive | `written ... images: [[pause], [coredns]]` | | |
| 3 | Validate (VM) | `images in manifest.json: 2`, `VALID`, sha256 recorded | | |
| 4 | SCP to Windows | `scp exit code: 0` | | |
| 5 | Validate (Windows) | Length 78059520, hash matches VM, 2 RepoTags | | |
| 6 | K2s import | `sudo buildah pull docker-archive:/tmp/import.tar` exit 125, `expected 1 item, got 2`, `k2s exit code: 1` | | |
| 7 | Post-import state | `/tmp/import.tar` absent, `image list unchanged` | | |
| 8 | Control test | `k2s exit code: 0`, `Writing manifest to image destination` | | |

**Reproduction status:** ☐ Confirmed (rows 2–6 match and row 8 passes) ☐ Inconclusive (record which row deviated and its output)
