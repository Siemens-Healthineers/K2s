<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Testing Checklist — `k2s system certificate autorotation`

## Feature Overview

Kubelet certificate auto-rotation is a Kubernetes background process where the kubelet
automatically renews its own client certificate **before** it expires — without any
administrator action.

### The 5-Step Auto-Rotation Loop

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. DETECTION  │ kubelet monitors its cert; at ~80% lifetime (~day 290│
│                │ for a 1-year cert) it triggers rotation              │
├──────────────────────────────────────────────────────────────────────┤
│  2. REQUEST    │ kubelet generates new private key + CSR, sends to    │
│                │ kube-apiserver                                        │
├──────────────────────────────────────────────────────────────────────┤
│  3. APPROVAL   │ kube-controller-manager auto-approves the CSR        │
│                │ (node is already a trusted cluster member)           │
├──────────────────────────────────────────────────────────────────────┤
│  4. ISSUANCE   │ Kubernetes CA signs the cert, attaches it to the CSR │
├──────────────────────────────────────────────────────────────────────┤
│  5. PICKUP     │ kubelet watches CSR, downloads + saves new cert to   │
│                │ /var/lib/kubelet/pki/ — NO restart required          │
└──────────────────────────────────────────────────────────────────────┘
```

### Commands Implemented

```console
k2s system certificate autorotation --status    # (default — safe, no changes)
k2s system certificate autorotation --enable    # sets rotateCertificates: true
k2s system certificate autorotation --disable   # sets rotateCertificates: false
```

> **Difference from `k2s system certificate renew`:**
> `renew` handles **control-plane** certs (kube-apiserver, etcd, scheduler, controller-manager) via `kubeadm certs renew all`.
> `autorotation` handles the **kubelet client certificate** rotation lifecycle setting only.

---

## Pre-requisites Before Testing

- K2s cluster is installed and running (`k2s start`)
- Running as Administrator on the Windows host
- SSH connectivity to the control plane node is working
- `kubectl get nodes` shows the node as `Ready`

---

## A — CLI / Help Validation

| # | Status | Test | Command | Expected Result |
|---|--------|------|---------|----------------|
| A1 | ✅ PASS | `certificate` group shows new sub-command | `k2s system certificate -h` | `autorotation` listed alongside `renew` |
| A2 | ✅ PASS | Autorotation help text complete | `k2s system certificate autorotation -h` | Shows `--enable`, `--disable`, `--status` flags and long description |
| A3 | ✅ PASS | No flag defaults to status (non-destructive) | `k2s system certificate autorotation` | Prints current status — does **not** modify config |
| A4 | ✅ PASS | Mutually exclusive: enable + disable rejected | `k2s system certificate autorotation --enable --disable` | Error: "if any flags in the group ... are set none of the others can be" |
| A5 | ✅ PASS | Mutually exclusive: enable + status rejected | `k2s system certificate autorotation --enable --status` | Same mutual exclusion error |
| A6 | ✅ PASS | Mutually exclusive: disable + status rejected | `k2s system certificate autorotation --disable --status` | Same mutual exclusion error |
| A7 | ✅ PASS | Short flag `-e` works | `k2s system certificate autorotation -e` | Same as `--enable` |
| A8 | ✅ PASS | Short flag `-d` works | `k2s system certificate autorotation -d` | Same as `--disable` |
| A9 | ✅ PASS | Short flag `-s` works | `k2s system certificate autorotation -s` | Same as `--status` |
| A10 | ✅ PASS | `-o` (output) flag shows logs in console | `k2s system certificate autorotation -s -o` | Log lines visible in terminal |
| A11 | ✅ PASS | Unknown flag rejected | `k2s system certificate autorotation --xyz` | Error: unknown flag |

---

## B — Status Command

| # | Status | Test | Setup | Command | Expected Result |
|---|--------|------|-------|---------|----------------|
| B1 | ✅ PASS | Fresh cluster — key not present | Clean install, never set | `k2s system certificate autorotation --status` | Output contains: `disabled (key not present)` |
| B2 | ✅ PASS | After manual disable | Set `rotateCertificates: false` on node | `--status` | Output contains: `disabled` |
| B3 | ✅ PASS | After enable | Run `--enable` first | `--status` | Output contains: `enabled` |
| B4 | ✅ PASS | After disable | Run `--disable` after enable | `--status` | Output contains: `disabled` |
| B5 | ✅ PASS | Verify against node directly | Any state | SSH: `sudo grep rotateCertificates /var/lib/kubelet/config.yaml` | Value matches what CLI reported |
| B6 | ⬜ TODO | Config file missing on node | Delete `/var/lib/kubelet/config.yaml` on node | `--status` | Output: `unknown (config file missing)` — no crash |

---

## C — Enable Command (Happy Path)

| # | Status | Test | Command | Expected Result |
|---|--------|------|---------|----------------|
| C1 | ✅ PASS | Enable on running cluster | `k2s system certificate autorotation --enable` | Exit code 0; success message printed |
| C2 | ✅ PASS | Config patched correctly | After C1 | SSH: `sudo grep rotateCertificates /var/lib/kubelet/config.yaml` → `rotateCertificates: true` |
| C3 | ✅ PASS | Kubelet restarted | After C1 | SSH: `sudo systemctl status kubelet` → `active (running)` |
| C4 | ✅ PASS | Node stays Ready | After C1 | `kubectl get nodes` → node status `Ready` |
| C5 | ✅ PASS | Backup file created | After C1 | SSH: `sudo ls /var/lib/kubelet/config.yaml.autorotation.bak` → file exists |
| C6 | ✅ PASS | Enable is idempotent | Run `--enable` twice | Second run exits 0 with no error; config still `true` |
| C7 | ✅ PASS | Enable when key already true | Set `rotateCertificates: true` manually, then run `--enable` | sed updates in-place correctly; kubelet restarts cleanly |

---

## D — Disable Command (Happy Path)

| # | Status | Test | Command | Expected Result |
|---|--------|------|---------|----------------|
| D1 | ✅ PASS | Disable after enable | Enable then `k2s system certificate autorotation --disable` | Exit 0; success message |
| D2 | ✅ PASS | Config patched correctly | After D1 | SSH: `sudo grep rotateCertificates /var/lib/kubelet/config.yaml` → `rotateCertificates: false` |
| D3 | ✅ PASS | Kubelet restarted | After D1 | SSH: `sudo systemctl status kubelet` → `active (running)` |
| D4 | ✅ PASS | Node stays Ready | After D1 | `kubectl get nodes` → both `kubemaster` and `imw1030228c` (worker) `Ready` |
| D5 | ✅ PASS | Disable is idempotent | Run `--disable` twice | Second run exits 0; config still `false` |
| D6 | ⬜ TODO | Disable on fresh cluster (key absent) | Never set, then `--disable` | Appends `rotateCertificates: false` to config; kubelet restarts |

---

## E — Control Plane VM State Edge Cases

| # | Status | Test | Setup | Expected |
|---|--------|------|-------|---------|
| E1 | ⬜ TODO | VM stopped (Hyper-V) — status | Stop VM via Hyper-V Manager | Script auto-starts VM, reads status, **stops VM** (started by script) |
| E2 | ⬜ TODO | VM stopped (Hyper-V) — enable | Stop VM | Script starts VM, patches config, restarts kubelet, stops VM after |
| E3 | ⬜ TODO | VM started manually before command | Start VM manually, then run `--enable` | Script does **NOT** stop VM (was not started by this script) |
| E4 | ⬜ TODO | WSL not running — status | `wsl --shutdown`, then run `--status` | Script starts WSL, reads status, shuts down WSL only if it started it |
| E5 | ⬜ TODO | WSL started manually | Start WSL first, then run `--enable` | WSL is **not** shut down after command |
| E6 | ⬜ TODO | vEthernet switch missing (Hyper-V) | Delete switch manually | Script creates switch, proceeds, removes switch in finally block |
| E7 | ⬜ TODO | SSH connection fails | Block port 22 on VM | Clear SSH error surfaced to user; no silent failure |
| E8 | ⬜ TODO | VM fails to start entirely | Rename VHDX or disable VM | Error from `Start-VM` / `Start-WSL` surfaced; no partial state left |

---

## F — Error & Failure Edge Cases

| # | Status | Test | Setup | Expected |
|---|--------|------|-------|---------|
| F1 | ⬜ TODO | Backup fails (disk full) | Fill `/var/lib` to 100% on node | Error: "Failed to back up kubelet config before patching"; config unchanged |
| F2 | ⬜ TODO | Patch fails → backup auto-restored | Break the sed command (e.g. lock the file) | Patch step fails; script detects `.Success = $false`; restores backup; throws error |
| F3 | ⬜ TODO | kubelet restart fails after patch | Lock the kubelet unit: `sudo systemctl mask kubelet` | Config is patched; error: "Failed to restart kubelet after patching config" |
| F4 | ⬜ TODO | Config file corrupt / unreadable | `sudo chmod 000 /var/lib/kubelet/config.yaml` | Permission denied from SSH command; error surfaced |
| F5 | ⬜ TODO | Config file is empty | `sudo truncate -s 0 /var/lib/kubelet/config.yaml` | `sed` appends key cleanly; no crash |
| F6 | ✅ PASS | Run without Administrator | Open non-elevated PowerShell | `fork/exec powershell.exe: Access is denied` error before any action |
| F7 | ✅ PASS | Both `--enable` and `--disable` flags | `--enable --disable` | Cobra rejects before any PS script runs |
| F8 | ⬜ TODO | `rotateCertificates` key has extra spaces | Config has `rotateCertificates :  true` (extra space) | `sed 's/rotateCertificates:.*/...'` still matches (`:.*` is greedy) |

---

## G — Auto-Rotation End-to-End Flow (The 5-Step Loop)

This validates that after enabling, Kubernetes actually performs the rotation cycle.

> ⚠️ Full end-to-end rotation takes months on a production cert.  
> Use the **forced simulation** approach below to test within minutes.

> ℹ️ **Note on SSH command:** Use `k2s node connect -i 172.19.1.100 -u remote` to SSH
> into the control plane node. `k2s ssh m` does **not** exist in this build.

---

### G0 — Node Recovery (if `kubelet-client-current.pem` is missing)

> Run this **only** if the node cert was accidentally deleted while auto-rotation was disabled
> (the failure mode observed on 2026-04-21). Skip to G1 if the node is healthy.

```console
# Step 1: re-enable auto-rotation from Windows host (SSH not needed for this step)
k2s system certificate autorotation --enable

# Step 2: SSH to node and restart kubelet to trigger a fresh CSR
k2s node connect -i 172.19.1.100 -u remote
sudo systemctl restart kubelet
exit

# Step 3: watch for the new CSR on Windows host
kubectl get csr --watch
# Expected: new csr-xxxxx appears and auto-approves within seconds

# Step 4: verify cert is back
k2s node connect -i 172.19.1.100 -u remote
sudo ls -la /var/lib/kubelet/pki/kubelet-client-current.pem
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate
exit

# Step 5: verify node is Ready
kubectl get nodes
```

---

### G1 — Verify controller-manager supports auto-approval

```console
k2s node connect -i 172.19.1.100 -u remote
sudo grep -E 'cluster-signing' /etc/kubernetes/manifests/kube-controller-manager.yaml
exit
```

✅ **Verified on 2026-04-21:**
```
--cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
--cluster-signing-key-file=/etc/kubernetes/pki/ca.key
```

---

### G2 — Enable auto-rotation

> ⚠️ **CRITICAL:** Auto-rotation **must be enabled** before performing G3–G5.
> If auto-rotation is disabled when the cert is deleted, kubelet has no mechanism to
> request a new one — the `kubelet-client-current.pem` symlink will simply disappear
> and the node will be unable to communicate with the API server.
> This was confirmed by live testing on 2026-04-21.

```console
k2s system certificate autorotation --enable
# Confirm it is enabled before proceeding:
k2s system certificate autorotation --status
# Expected output must say: enabled
```

**Expected:** Exit 0, kubelet restarted, `rotateCertificates: true` in config.

---

### G3 — Check current kubelet cert expiry

```console
# SSH to node
k2s node connect -i 172.19.1.100 -u remote
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate -startdate
```

**Expected:** Cert shows valid dates (e.g. `notBefore: Apr 21 2026`, `notAfter: Apr 21 2027`). Note the serial:

```console
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial
# e.g. serial=323AF8E314DE55E8
```

✅ **Verified on 2026-04-21:** cert valid, serial recorded.

---

### G4 — Simulate rotation trigger (force CSR submission)

Since waiting 290 days is impractical, force a CSR by deleting the current kubelet cert.
**Kubelet will immediately request a new one — but ONLY if `rotateCertificates: true`.**

> ⚠️ **Lesson learned (2026-04-21):** Running this step with auto-rotation DISABLED
> causes kubelet to lose its cert with no recovery path. Always confirm `--status`
> shows `enabled` before this step.

```console
# SSH to node (from Windows host):
k2s node connect -i 172.19.1.100 -u remote

# Step 1: confirm auto-rotation is enabled on the node
sudo grep rotateCertificates /var/lib/kubelet/config.yaml
# Expected: rotateCertificates: true   <-- MUST be true before continuing

# Step 2: note the current cert serial (to verify it changes after rotation)
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial

# Step 3: delete current cert symlink + restart kubelet to trigger CSR
sudo rm /var/lib/kubelet/pki/kubelet-client-current.pem
sudo systemctl restart kubelet
exit

# Step 4: on Windows host — watch for new CSR to appear
kubectl get csr --watch
```

**Expected:**

- A **new** CSR named like `csr-xxxxx` appears with `REQUESTOR = system:node:kubemaster`
- Within seconds its `CONDITION` changes from `Pending` → `Approved,Issued`
- The AGE of the new CSR is seconds/minutes old — **not** tens of minutes (old CSRs are pre-existing)

> ⚠️ **Pitfall:** `kubectl get csr` may show old CSRs already in `Approved,Issued` state.
> Only a **newly appearing** CSR with a fresh AGE confirms the rotation fired.
> If no new CSR appears within 30 seconds, auto-rotation is likely not truly enabled.

---

### G5 — Verify new cert is picked up

```console
# SSH to node — wait ~10–30 seconds after CSR is Approved,Issued
k2s node connect -i 172.19.1.100 -u remote

sudo ls -la /var/lib/kubelet/pki/kubelet-client-*.pem
# Expected: kubelet-client-current.pem symlink EXISTS + a new timestamped .pem

sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate
```

**Expected:**

- `kubelet-client-current.pem` exists (symlink recreated by kubelet)
- Serial number is **different** from G3
- Expiry date is ~1 year from now (fresh cert)
- kubelet still running: `sudo systemctl status kubelet` → `active (running)`

> ⚠️ **Failure mode observed (2026-04-21 with auto-rotation DISABLED):**
> After deleting cert + restarting kubelet with `rotateCertificates: false`:
> - No new CSR appeared (only old CSRs from 53m, 55m ago visible)
> - `kubelet-client-current.pem` symlink was **not recreated**
> - `openssl x509` on that path gave "No such file or directory"
>
> **Recovery from this state:**
> ```console
> k2s node connect -i 172.19.1.100 -u remote
> # Re-enable auto-rotation
> # (must be done from Windows host since kubelet has no cert now — node may be NotReady)
> ```
> From Windows host:
> ```console
> k2s system certificate autorotation --enable
> # Then restart kubelet again to trigger fresh CSR
> k2s node connect -i 172.19.1.100 -u remote
> sudo systemctl restart kubelet
> exit
> kubectl get csr --watch
> ```

---

### G6 — Verify cluster health after rotation

```console
kubectl get nodes
kubectl get pods -A
```

**Expected:** All nodes `Ready`, all system pods `Running`.

---

### G7 — Verify auto-rotation interacts correctly with `renew`

```console
# Enable auto-rotation
k2s system certificate autorotation --enable

# Run control-plane cert renewal (separate operation)
k2s system certificate renew

# Check kubelet auto-rotation setting is UNCHANGED
k2s system certificate autorotation --status
```

**Expected:** `renew` succeeds; autorotation setting remains `enabled` (renew only touches
control-plane certs, not kubelet config).

---

## H — Integration with Existing Commands

| # | Status | Test | Command Sequence | Expected |
|---|--------|------|-----------------|---------|
| H1 | ⬜ TODO | Renew does not affect autorotation | `--enable` → `renew` → `--status` | Status still `enabled` |
| H2 | ⬜ TODO | Renew --force does not affect autorotation | `--enable` → `renew --force` → `--status` | Status still `enabled` |
| H3 | ⬜ TODO | Autorotation survives cluster restart | `--enable` → `k2s stop` → `k2s start` → `--status` | Status still `enabled` (config persists) |
| H4 | ⬜ TODO | Autorotation setting survives node reboot | `--enable` → `sudo reboot` (SSH) → `--status` | Status still `enabled` |

---

## I — Go Unit Tests

File: `k2s/cmd/k2s/cmd/system/certificate/autorotation_test.go`

| # | Test Name | What to Test |
|---|-----------|-------------|
| I1 | `TestDefaultFlagIsStatus` | When no flags set, `ShowStatus=true`, `Enable=false`, `Disable=false` |
| I2 | `TestEnableFlagSetsEnableTrue` | `--enable` → config has `Enable=true`, others false |
| I3 | `TestDisableFlagSetsDisableTrue` | `--disable` → config has `Disable=true`, others false |
| I4 | `TestStatusFlagSetsShowStatusTrue` | `--status` → config has `ShowStatus=true` |
| I5 | `TestMutualExclusionEnableDisable` | Cobra returns error for `--enable --disable` |
| I6 | `TestMutualExclusionEnableStatus` | Cobra returns error for `--enable --status` |
| I7 | `TestMutualExclusionDisableStatus` | Cobra returns error for `--disable --status` |
| I8 | `TestOutputFlagPropagated` | `-o` → `ShowOutput=true` in config |
| I9 | `TestShortFlagE` | `-e` behaves same as `--enable` |
| I10 | `TestShortFlagD` | `-d` behaves same as `--disable` |
| I11 | `TestShortFlagS` | `-s` behaves same as `--status` |

---

## J — Full Server Test Run (Step-by-Step)

Copy-paste sequence for manual verification on a live K2s server.

> ℹ️ Use `k2s node connect -i 172.19.1.100 -u remote` to SSH into the control plane node.
> `k2s ssh m` is **not** a valid command in this build.

```console
# ── SETUP ────────────────────────────────────────────────────────────
k2s start

# ── A: CLI HELP ───────────────────────────────────────────────────────
k2s system certificate -h
k2s system certificate autorotation -h

# ── B: STATUS (no flag = status, non-destructive) ─────────────────────
k2s system certificate autorotation
k2s system certificate autorotation --status
k2s system certificate autorotation -s

# ── C: ENABLE ────────────────────────────────────────────────────────
k2s system certificate autorotation --enable
# Verify on node:
k2s node connect -i 172.19.1.100 -u remote
sudo grep rotateCertificates /var/lib/kubelet/config.yaml
sudo systemctl is-active kubelet
sudo ls -la /var/lib/kubelet/config.yaml.autorotation.bak
exit
kubectl get nodes

# ── D: STATUS AFTER ENABLE ───────────────────────────────────────────
k2s system certificate autorotation --status
# Expected: enabled

# ── E: DISABLE ───────────────────────────────────────────────────────
k2s system certificate autorotation --disable
k2s node connect -i 172.19.1.100 -u remote
sudo grep rotateCertificates /var/lib/kubelet/config.yaml
exit
k2s system certificate autorotation --status
# Expected: disabled
kubectl get nodes

# ── F: IDEMPOTENCY ───────────────────────────────────────────────────
k2s system certificate autorotation --enable
k2s system certificate autorotation --enable
# Expected: both succeed, no error

k2s system certificate autorotation --disable
k2s system certificate autorotation --disable
# Expected: both succeed, no error

# ── G: MUTUAL EXCLUSION ──────────────────────────────────────────────
k2s system certificate autorotation --enable --disable
# Expected: error

# ── H: COEXISTENCE WITH RENEW ────────────────────────────────────────
k2s system certificate autorotation --enable
k2s system certificate renew
k2s system certificate autorotation --status
# Expected: still enabled; renew does not affect kubelet auto-rotation

# ── I: ACTUAL CSR ROTATION SIMULATION ────────────────────────────────
# IMPORTANT: confirm auto-rotation is ENABLED before deleting the cert
k2s system certificate autorotation --enable
k2s system certificate autorotation --status
# Must show: enabled

# Note current serial
k2s node connect -i 172.19.1.100 -u remote
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate
sudo grep rotateCertificates /var/lib/kubelet/config.yaml
# Must show: rotateCertificates: true

# Delete cert and restart kubelet to force CSR
sudo rm /var/lib/kubelet/pki/kubelet-client-current.pem
sudo systemctl restart kubelet
exit

# Watch for new CSR (must be a NEWLY appearing one, not old ones)
kubectl get csr --watch
# Expected: new csr-xxxxx with REQUESTOR=system:node:kubemaster, age=seconds, Approved,Issued

# Verify new cert
k2s node connect -i 172.19.1.100 -u remote
sudo ls -la /var/lib/kubelet/pki/kubelet-client-*.pem
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate
# Expected: new serial, new expiry ~1 year from now
exit
kubectl get nodes
# Expected: both nodes Ready

# ── J: CLUSTER RESTART PERSISTENCE ──────────────────────────────────
k2s system certificate autorotation --enable
k2s stop
k2s start
k2s system certificate autorotation --status
# Expected: still enabled
```

---

## K — Extra Scenarios (Architect-Level Edge Cases)

| Scenario | Status | How to Verify |
|----------|--------|--------------|
| **Controller-manager signing keys present** | ✅ PASS | `k2s node connect -i 172.19.1.100 -u remote` then `sudo grep cluster-signing /etc/kubernetes/manifests/kube-controller-manager.yaml` — confirmed `--cluster-signing-cert-file` and `--cluster-signing-key-file` present |
| **CSR auto-approval works for this node** | ⬜ TODO | After CSR appears: `kubectl get csr` → condition should auto-change to `Approved,Issued` without manual `kubectl certificate approve` |
| **Cert saved to correct path** | ⬜ TODO | After rotation: `sudo ls /var/lib/kubelet/pki/` → `kubelet-client-current.pem` updated, old cert archived as `kubelet-client-<timestamp>.pem` |
| **No kubelet restart during pickup** | ⬜ TODO | Kubelet picks up new cert by watching CSR — `sudo systemctl status kubelet` shows same PID before and after pickup |
| **Setting survives K2s upgrade** | ⬜ TODO | Enable, upgrade K2s, check status — **NOTE:** upgrade replaces VHDX/rootfs so setting may be lost; re-enable after upgrade |
| **kubelet-config ConfigMap alignment** | ⬜ TODO | `kubectl -n kube-system get cm kubelet-config -o yaml \| grep rotateCertificates` — if K2s uses kubeadm-managed ConfigMap, this should also reflect the setting |
| **Windows worker node unaffected** | ✅ PASS | `kubectl get nodes` shows `imw1030228c` (Windows worker) stays `Ready` after enable/disable — command does not touch Windows node kubelet |
| **Multiple runs during rotation window** | ⬜ TODO | Enable auto-rotation when cert is at 80%+ lifetime — rotation should complete via CSR loop without manual intervention |

---

## L — Known Limitations / Out of Scope

| Item | Notes |
|------|-------|
| Control-plane component certs (kube-apiserver, etcd, scheduler) | Not auto-rotated by this feature. Use `k2s system certificate renew` |
| Windows worker node kubelet cert | Uses Windows Certificate Store — not handled by this command |
| Auto-rotation after K2s upgrade | Upgrade may reset kubelet config — re-run `--enable` post-upgrade |
| Cert expiry display in `--status` | Currently shows only enabled/disabled; future enhancement to also display cert expiry date |

