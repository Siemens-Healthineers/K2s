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
| B6 | ✅ PASS | Config file missing on node | Fresh install — `config.yaml` absent | `--status` | Output: `Kubelet config file not found at /var/lib/kubelet/config.yaml`, exits SUCCESS — no crash. Verified 2026-04-30. |

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
| D6 | ⬜ RETEST | Disable on fresh cluster (key absent) | Never set, then `--disable` | Appends `rotateCertificates: false` to config; kubelet restarts | **Bug found 2026-04-30:** backup step failed with misleading error when `config.yaml` missing. **Fixed:** script now skips backup when file absent and proceeds to create+append. Retest required after fix. |

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
> Use the **short-lifetime** approach (Option A) below to test within ~10 minutes without
> touching the cert file or restarting kubelet.

> ℹ️ **Note on SSH command:** Use `k2s node connect -i 172.19.1.100 -u remote` to SSH
> into the control plane node. `k2s ssh m` does **not** exist in this build.

> ⚠️ **K2s-specific constraint:**  
> `/etc/kubernetes/bootstrap-kubelet.conf` does **NOT** exist in K2s.  
> Kubelet uses a **combined PEM** (`kubelet-client-current.pem` contains both cert + key).  
> **NEVER delete this file** — kubelet cannot re-bootstrap and the node goes `NotReady`
> with no automatic recovery path.  
> Rotation must be triggered by kubelet detecting a cert at ≥80% of its lifetime.

---

### G1 — Verify auto-rotation is enabled and controller-manager supports signing

```console
# From Windows host:
k2s system certificate autorotation --status
# Expected: enabled

# On node:
k2s node connect -i 172.19.1.100 -u remote
sudo grep rotateCertificates /var/lib/kubelet/config.yaml
# Expected: rotateCertificates: true

sudo grep -E 'cluster-signing' /etc/kubernetes/manifests/kube-controller-manager.yaml
# Expected:
#   --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
#   --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
exit
```

✅ **Verified on 2026-04-21, 2026-04-28, and 2026-04-30:** signing keys present, auto-rotation enabled.

---

### G2 — Enable auto-rotation (if not already enabled)

```console
k2s system certificate autorotation --enable
k2s system certificate autorotation --status
# Expected output must say: enabled
```

**Expected:** Exit 0, kubelet restarted, `rotateCertificates: true` in config.

---

### G3 — Note current kubelet cert serial (baseline)

```console
k2s node connect -i 172.19.1.100 -u remote
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -startdate -enddate
exit
```

Record the serial number — it must change after rotation to confirm a new cert was issued.

✅ **Verified on 2026-04-30:** baseline serial `0205E52C922F6748`, cert valid `Apr 30 04:48:26 2026 GMT` → `Apr 30 04:53:26 2027 GMT`.

---

### G4 — Trigger rotation: Option A — Short signing duration (preferred)

**Why it works:** kubelet periodically checks its cert lifetime. When `--cluster-signing-duration`
is set to a short value (e.g. 10m) and kubelet receives a freshly rotated cert with that
lifetime, it hits the 80% threshold and generates a new CSR automatically —
without any cert file manipulation. Rotation typically occurs around 70–90% of certificate
lifetime. For a 10-minute certificate this is approximately 7–9 minutes, but actual timing
depends on kubelet's internal rotation loop and may not be immediate.

> ⚠️ **Important:** The short signing duration applies only to **newly issued** certs.
> The existing long-lived kubelet cert will not immediately trigger rotation. If this is the
> first rotation, you may need to wait for the cert currently held by kubelet to be renewed
> first (see G4b for time-shift alternative). Once the first rotation completes and kubelet
> holds a short-lived cert, subsequent rotations will occur within minutes.

```console
# Step 1: SSH to node, patch kube-controller-manager manifest
k2s node connect -i 172.19.1.100 -u remote

# Backup the manifest
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml \
        /etc/kubernetes/manifests/kube-controller-manager.yaml.bak

# Inject --cluster-signing-duration=10m (after the existing cluster-signing-key-file line)
# Ensure the flag is not already present before inserting to avoid duplicate entries in the manifest.
sudo grep -q 'cluster-signing-duration' /etc/kubernetes/manifests/kube-controller-manager.yaml || \
sudo sed -i '/cluster-signing-key-file/a\    - --cluster-signing-duration=10m' \
    /etc/kubernetes/manifests/kube-controller-manager.yaml

# Verify
sudo grep 'cluster-signing' /etc/kubernetes/manifests/kube-controller-manager.yaml

# Wait for kube-controller-manager pod to restart (~30–40s)
sleep 40
sudo crictl pods --name kube-controller-manager 2>/dev/null || \
  kubectl --kubeconfig /etc/kubernetes/admin.conf get pod -n kube-system -l component=kube-controller-manager

# Restart kubelet ONCE to ensure it is running cleanly after controller-manager changes.
# Note: restart does NOT force certificate rotation — kubelet follows its normal rotation loop.
sudo systemctl restart kubelet
sleep 5
sudo systemctl status kubelet --no-pager | head -5
exit
```

> ℹ️ **What to expect after G4:**  
> - If the current kubelet cert is already short-lived (issued after the previous test), rotation
>   will typically occur within 7–9 minutes once kubelet is using a short-lived certificate — watch `kubectl get csr --watch` (step G5).  
> - If the current cert has a long remaining lifetime (e.g. 1 year), the first CSR will appear
>   only when kubelet's internal cert manager triggers it based on the 80% threshold.  
>   In that case, use Option B (time shift) below to force it immediately.

---

### G4b — Trigger rotation: Option B — System time shift (alternative)

> Use this if Option A is not feasible (e.g. current cert has a long remaining lifetime and G4 Option A has not yet issued a short-lived cert). Time shift is **disruptive** and should only be used on an isolated test node.

```console
k2s node connect -i 172.19.1.100 -u remote

# Record current cert expiry
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate

# Advance system clock past 80% of cert lifetime
# Example: cert valid Apr 30 2026 → Apr 30 2027 (1 year) → advance to ~Feb 19 2027 (~295 days)
sudo timedatectl set-ntp false
sudo date -s "2027-02-19 10:43:00"

# Restart kubelet — it will now see cert as near-expiry and generate CSR
sudo systemctl restart kubelet
sleep 50
sudo systemctl status kubelet --no-pager | head -5
exit
```

> ⚠️ **Restore time after test:**
> ```console
> k2s node connect -i 172.19.1.100 -u remote
> sudo timedatectl set-ntp true
> # NTP may take a few minutes to re-sync; verify with: timedatectl status
> exit
> ```
>
> ⚠️ **Known issue (observed 2026-04-30):** After `set-ntp true`, NTP sync may be slow.
> `System clock synchronized: no` may persist briefly. This is expected — `timesyncd` will
> correct the clock gradually. The node clock **will not snap back to real time instantly**.
> This is a test-environment side effect only — in production, the clock is never manually changed.

✅ **Verified on 2026-04-30:** advancing to `2027-02-19 10:43:00` (295 days forward on a 1-year cert = ~80.8% lifetime) triggered a new CSR `csr-74qsg` within ~68 seconds. New cert file `kubelet-client-2027-02-19-10-43-09.pem` created and symlinked as `kubelet-client-current.pem`. Serial changed from `0205E52C922F6748` confirming rotation completed.

---

### G5 — Observe CSR generated by kubelet

Watch from the Windows host for a **new** CSR from `system:node:kubemaster`:

```console
kubectl get csr --watch
```

**Expected — a NEW CSR appears (age = seconds):**

```
NAME        AGE   SIGNERNAME                                    REQUESTOR                REQUESTEDDURATION   CONDITION
csr-XXXXX   5s    kubernetes.io/kube-apiserver-client-kubelet   system:node:kubemaster   <none>              Approved,Issued
```

- The CSR `AGE` must be seconds/minutes old — pre-existing CSRs (tens of minutes old) do **not** count.
- `CONDITION` changes `Pending` → `Approved,Issued` automatically (controller-manager auto-approves).
- If no new CSR appears within 10 minutes, run the following on the node to debug immediately:

```console
k2s node connect -i 172.19.1.100 -u remote
sudo journalctl -u kubelet -f | grep -i cert
```

> ℹ️ **First rotation timing note:**
> First rotation depends on the current certificate lifetime. If the existing cert is
> long-lived (e.g. 1 year), rotation may not happen immediately — kubelet will only
> trigger when its cert reaches the 70–90% lifetime threshold. After the first successful
> rotation, kubelet will receive a short-lived cert and subsequent rotations will occur
> quickly (within minutes).

✅ **Verified on 2026-04-30 (G4b time-shift method):** New CSR `csr-74qsg` appeared with `AGE=68s`, `REQUESTOR=system:node:kubemaster`, `CONDITION=Approved,Issued`. Auto-approved by controller-manager without manual intervention (K scenario: **CSR auto-approval works for this node** → ✅ PASS).

---

### G5a — Confirm rotation in kubelet logs (on node)

```console
k2s node connect -i 172.19.1.100 -u remote
sudo journalctl -u kubelet --since "10 minutes ago" --no-pager | \
  grep -iE "certif|rotat|CSR|renew|expir" | tail -20
exit
```

**Expected log lines confirming rotation fired:**

```
certificate rotation …
rotating certificates
certificate request submitted
```

> ℹ️ If no CSR appears, check kubelet logs to confirm whether rotation logic is being triggered.
> The absence of rotation log lines means kubelet's cert is not yet at the rotation threshold.

---

### G6 — Verify new cert is picked up (no kubelet restart needed)

```console
k2s node connect -i 172.19.1.100 -u remote

sudo ls -la /var/lib/kubelet/pki/kubelet-client-*.pem
# Expected: kubelet-client-current.pem symlink updated to a NEW timestamped .pem

sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate
# Expected: serial DIFFERENT from G3 baseline; new expiry date
exit
```

**Expected:**

- `kubelet-client-current.pem` symlink points to a new timestamped file
- Serial number changed from G3 baseline
- kubelet still running (`sudo systemctl status kubelet` → `active (running)`)
- **No manual kubelet restart was needed** — pickup is automatic

✅ **Verified on 2026-04-30:** After CSR `csr-74qsg` was Approved,Issued:
- New file: `kubelet-client-2027-02-19-10-43-09.pem` (1114 bytes — cert only, no private key embed)
- Old file: `kubelet-client-2026-04-30-04-53-27.pem` (2830 bytes — original combined PEM)
- Symlink: `kubelet-client-current.pem → kubelet-client-2027-02-19-10-43-09.pem`
- Serial changed from baseline `0205E52C922F6748`
- kubelet remained `active (running)` throughout — no restart needed for pickup
- Both nodes stayed `Ready` (`kubectl get nodes`)

---

### G7 — Restore controller-manager to original configuration

After rotation test is complete, remove the short signing-duration flag (if G4 Option A was used):

```console
k2s node connect -i 172.19.1.100 -u remote

# Restore original manifest from backup
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml.bak \
        /etc/kubernetes/manifests/kube-controller-manager.yaml

# Verify --cluster-signing-duration is gone
sudo grep 'cluster-signing-duration' /etc/kubernetes/manifests/kube-controller-manager.yaml
# Expected: no output (line must not exist)

# Wait for controller-manager to restart
sleep 40
exit
```

✅ **Verified on 2026-04-30:** manifest restored from backup, `cluster-signing-duration` line absent, controller-manager pod restarted (RESTARTS=2 confirmed in `kubectl get pods -A`).

---

### G8 — Verify cluster health after rotation

```console
kubectl get nodes
# Expected: both nodes Ready

kubectl get pods -A
# Expected: all system pods Running
```

✅ **Verified on 2026-04-30:** Both `kubemaster` (control-plane) and `imw1030228c` (worker) `Ready`. All system pods `Running`. (`kube-controller-manager-kubemaster` showed RESTARTS=2 reflecting the two manifest changes during testing — expected.)

---

### G9 — Verify auto-rotation interacts correctly with `renew`

```console
# Enable auto-rotation
k2s system certificate autorotation --enable

# Run control-plane cert renewal (separate operation)
k2s system certificate renew

# Check kubelet auto-rotation setting is UNCHANGED
k2s system certificate autorotation --status
# Expected: still enabled
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
# Enable auto-rotation first
k2s system certificate autorotation --enable
k2s system certificate autorotation --status
# Must show: enabled

# Note current cert serial (baseline)
k2s node connect -i 172.19.1.100 -u remote
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -startdate -enddate
sudo grep rotateCertificates /var/lib/kubelet/config.yaml
# Must show: rotateCertificates: true

# Patch controller-manager to use short signing duration
# (enables short-lived certificates; rotation will occur once kubelet enters its rotation window)
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml \
        /etc/kubernetes/manifests/kube-controller-manager.yaml.bak
# Ensure the flag is not already present before inserting to avoid duplicate entries.
sudo grep -q 'cluster-signing-duration' /etc/kubernetes/manifests/kube-controller-manager.yaml || \
sudo sed -i '/cluster-signing-key-file/a\    - --cluster-signing-duration=10m' \
    /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo grep 'cluster-signing' /etc/kubernetes/manifests/kube-controller-manager.yaml
# Wait for controller-manager restart, then restart kubelet once to ensure it is running cleanly.
# Note: restart does NOT force rotation — kubelet follows its normal rotation loop.
sleep 40
sudo systemctl restart kubelet
sleep 5
sudo systemctl status kubelet --no-pager | head -5
exit

# Watch for a NEW CSR from system:node:kubemaster (must be newly appearing, not old ones)
# NOTE: First rotation depends on current certificate lifetime. If the existing cert is
# long-lived, rotation may not happen immediately. After the first successful rotation,
# kubelet holds a short-lived cert and subsequent rotations occur within minutes.
kubectl get csr --watch
# Expected: new csr-xxxxx with REQUESTOR=system:node:kubemaster, age=seconds, Approved,Issued

# Verify new cert was picked up (no kubelet restart needed — pickup is automatic)
k2s node connect -i 172.19.1.100 -u remote
sudo ls -la /var/lib/kubelet/pki/kubelet-client-*.pem
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate
# Expected: serial DIFFERENT from baseline, new expiry date
sudo systemctl status kubelet --no-pager | head -5
# Expected: active (running)
exit
kubectl get nodes
# Expected: both nodes Ready

# Restore controller-manager
k2s node connect -i 172.19.1.100 -u remote
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml.bak \
        /etc/kubernetes/manifests/kube-controller-manager.yaml
sleep 40
exit

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
| **CSR auto-approval works for this node** | ✅ PASS | After CSR `csr-74qsg` appeared (2026-04-30): condition auto-changed to `Approved,Issued` within seconds — no manual `kubectl certificate approve` needed |
| **Cert saved to correct path** | ✅ PASS | After rotation (2026-04-30): `kubelet-client-current.pem` symlink updated to `kubelet-client-2027-02-19-10-43-09.pem`; old cert archived as `kubelet-client-2026-04-30-04-53-27.pem` |
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
| Time-shift test side effect | After `sudo date -s` + `set-ntp true`, NTP re-sync is gradual. Node clock may remain in future for minutes. Cluster API requests using Windows host time still work because the cert is valid for both past and future dates relative to the shifted node time. **In production, the clock is never manually changed — kubelet auto-rotation fires naturally when cert reaches 80% lifetime without any operator action.** |
| Node clock stuck after time-shift test | If the node remains at the shifted time after `set-ntp true`, run `k2s stop && k2s start` to get a fresh VHDX state — the Hyper-V VM clock re-syncs from the Windows host on restart. |

