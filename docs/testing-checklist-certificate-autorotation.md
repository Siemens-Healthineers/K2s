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

| # | Test | Command | Expected Result |
|---|------|---------|----------------|
| A1 | `certificate` group shows new sub-command | `k2s system certificate -h` | `autorotation` listed alongside `renew` |
| A2 | Autorotation help text complete | `k2s system certificate autorotation -h` | Shows `--enable`, `--disable`, `--status` flags and long description |
| A3 | No flag defaults to status (non-destructive) | `k2s system certificate autorotation` | Prints current status — does **not** modify config |
| A4 | Mutually exclusive: enable + disable rejected | `k2s system certificate autorotation --enable --disable` | Error: "if any flags in the group ... are set none of the others can be" |
| A5 | Mutually exclusive: enable + status rejected | `k2s system certificate autorotation --enable --status` | Same mutual exclusion error |
| A6 | Mutually exclusive: disable + status rejected | `k2s system certificate autorotation --disable --status` | Same mutual exclusion error |
| A7 | Short flag `-e` works | `k2s system certificate autorotation -e` | Same as `--enable` |
| A8 | Short flag `-d` works | `k2s system certificate autorotation -d` | Same as `--disable` |
| A9 | Short flag `-s` works | `k2s system certificate autorotation -s` | Same as `--status` |
| A10 | `-o` (output) flag shows logs in console | `k2s system certificate autorotation -s -o` | Log lines visible in terminal |
| A11 | Unknown flag rejected | `k2s system certificate autorotation --xyz` | Error: unknown flag |

---

## B — Status Command

| # | Test | Setup | Command | Expected Result |
|---|------|-------|---------|----------------|
| B1 | Fresh cluster — key not present | Clean install, never set | `k2s system certificate autorotation --status` | Output contains: `disabled (key not present)` |
| B2 | After manual disable | Set `rotateCertificates: false` on node | `--status` | Output contains: `disabled` |
| B3 | After enable | Run `--enable` first | `--status` | Output contains: `enabled` |
| B4 | After disable | Run `--disable` after enable | `--status` | Output contains: `disabled` |
| B5 | Verify against node directly | Any state | SSH to node: `sudo grep rotateCertificates /var/lib/kubelet/config.yaml` | Value matches what CLI reported |
| B6 | Config file missing on node | Delete `/var/lib/kubelet/config.yaml` on node | `--status` | Output: `unknown (config file missing)` — no crash |

---

## C — Enable Command (Happy Path)

| # | Test | Command | Expected Result |
|---|------|---------|----------------|
| C1 | Enable on running cluster | `k2s system certificate autorotation --enable` | Exit code 0; success message printed |
| C2 | Config patched correctly | After C1 | SSH: `sudo grep rotateCertificates /var/lib/kubelet/config.yaml` → `rotateCertificates: true` |
| C3 | Kubelet restarted | After C1 | SSH: `sudo systemctl status kubelet` → `active (running)` |
| C4 | Node stays Ready | After C1 | `kubectl get nodes` → node status `Ready` |
| C5 | Backup file created | After C1 | SSH: `sudo ls /var/lib/kubelet/config.yaml.autorotation.bak` → file exists |
| C6 | Enable is idempotent | Run `--enable` twice | Second run exits 0 with no error; config still `true` |
| C7 | Enable when key already true | Set `rotateCertificates: true` manually, then run `--enable` | sed updates in-place correctly; kubelet restarts cleanly |

---

## D — Disable Command (Happy Path)

| # | Test | Command | Expected Result |
|---|------|---------|----------------|
| D1 | Disable after enable | Enable then `k2s system certificate autorotation --disable` | Exit 0; success message |
| D2 | Config patched correctly | After D1 | SSH: `sudo grep rotateCertificates /var/lib/kubelet/config.yaml` → `rotateCertificates: false` |
| D3 | Kubelet restarted | After D1 | SSH: `sudo systemctl status kubelet` → `active (running)` |
| D4 | Node stays Ready | After D1 | `kubectl get nodes` → `Ready` |
| D5 | Disable is idempotent | Run `--disable` twice | Second run exits 0; config still `false` |
| D6 | Disable on fresh cluster (key absent) | Never set | `--disable` | Appends `rotateCertificates: false` to config; kubelet restarts |

---

## E — Control Plane VM State Edge Cases

| # | Test | Setup | Expected |
|---|------|-------|---------|
| E1 | VM stopped (Hyper-V) — status | Stop VM via Hyper-V Manager | Script auto-starts VM, reads status, **stops VM** (started by script) |
| E2 | VM stopped (Hyper-V) — enable | Stop VM | Script starts VM, patches config, restarts kubelet, stops VM after |
| E3 | VM started manually before command | Start VM manually, then run `--enable` | Script does **NOT** stop VM (was not started by this script) |
| E4 | WSL not running — status | `wsl --shutdown`, then run `--status` | Script starts WSL, reads status, shuts down WSL only if it started it |
| E5 | WSL started manually | Start WSL first, then run `--enable` | WSL is **not** shut down after command |
| E6 | vEthernet switch missing (Hyper-V) | Delete switch manually | Script creates switch, proceeds, removes switch in finally block |
| E7 | SSH connection fails | Block port 22 on VM | Clear SSH error surfaced to user; no silent failure |
| E8 | VM fails to start entirely | Rename VHDX or disable VM | Error from `Start-VM` / `Start-WSL` surfaced; no partial state left |

---

## F — Error & Failure Edge Cases

| # | Test | Setup | Expected |
|---|------|-------|---------|
| F1 | Backup fails (disk full) | Fill `/var/lib` to 100% on node | Error: "Failed to back up kubelet config before patching"; config unchanged |
| F2 | Patch fails → backup auto-restored | Break the sed command (e.g. lock the file) | Patch step fails; script detects ExitCode ≠ 0; restores backup; throws error |
| F3 | kubelet restart fails after patch | Lock the kubelet unit: `sudo systemctl mask kubelet` | Config is patched; error: "Failed to restart kubelet after patching config" |
| F4 | Config file corrupt / unreadable | `sudo chmod 000 /var/lib/kubelet/config.yaml` | Permission denied from SSH command; error surfaced |
| F5 | Config file is empty | `sudo truncate -s 0 /var/lib/kubelet/config.yaml` | `sed` appends key cleanly; no crash |
| F6 | Run without Administrator | Open non-elevated PowerShell | `#Requires -RunAsAdministrator` triggers clear PS error before any action |
| F7 | Both `--enable` and `--disable` flags | `--enable --disable` | Cobra rejects before any PS script runs |
| F8 | `rotateCertificates` key has extra spaces | Config has `rotateCertificates :  true` (extra space) | `sed 's/rotateCertificates:.*/...'` still matches (`:.*` is greedy) |

---

## G — Auto-Rotation End-to-End Flow (The 5-Step Loop)

This validates that after enabling, Kubernetes actually performs the rotation cycle.

> ⚠️ Full end-to-end rotation takes months on a production cert.  
> Use the **forced simulation** approach below to test within minutes.

### G1 — Verify controller-manager supports auto-approval

```console
# SSH into control plane node
k2s ssh m

# Check controller-manager has signing keys configured
sudo grep -E 'cluster-signing' /etc/kubernetes/manifests/kube-controller-manager.yaml
```

**Expected:** Lines like `--cluster-signing-cert-file` and `--cluster-signing-key-file` present.

---

### G2 — Enable auto-rotation

```console
k2s system certificate autorotation --enable
```

**Expected:** Exit 0, kubelet restarted, `rotateCertificates: true` in config.

---

### G3 — Check current kubelet cert expiry

```console
# SSH to node
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate -startdate
```

**Expected:** Cert shows valid dates. Note the expiry date.

---

### G4 — Simulate rotation trigger (force CSR submission)

Since waiting 290 days is impractical, force a CSR by deleting the current kubelet cert
(kubelet will immediately request a new one if auto-rotation is enabled):

```console
# SSH to node
# Step 1: note the current cert serial
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial

# Step 2: delete current cert to force immediate CSR
sudo rm /var/lib/kubelet/pki/kubelet-client-current.pem
sudo systemctl restart kubelet

# Step 3: on Windows host — watch for new CSR to appear
kubectl get csr --watch
```

**Expected:**

- A new CSR named like `csr-xxxxx` appears with `REQUESTOR = system:node:<nodename>`
- Within seconds its `CONDITION` changes from `Pending` → `Approved,Issued`
- `kubectl get csr` shows the cert approved

---

### G5 — Verify new cert is picked up

```console
# SSH to node — wait ~10 seconds after CSR approved
sudo ls -la /var/lib/kubelet/pki/kubelet-client-*.pem
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate
```

**Expected:**

- The serial number is **different** from Step G4
- The expiry date is ~1 year from now (fresh cert)
- kubelet is still running without restart: `sudo systemctl status kubelet`

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

| # | Test | Command Sequence | Expected |
|---|------|-----------------|---------|
| H1 | Renew does not affect autorotation | `--enable` → `renew` → `--status` | Status still `enabled` |
| H2 | Renew --force does not affect autorotation | `--enable` → `renew --force` → `--status` | Status still `enabled` |
| H3 | Autorotation survives cluster restart | `--enable` → `k2s stop` → `k2s start` → `--status` | Status still `enabled` (config persists) |
| H4 | Autorotation setting survives node reboot | `--enable` → `sudo reboot` (SSH) → `--status` | Status still `enabled` |

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

Copy-paste sequence for manual verification on a live K2s server:

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
k2s ssh m "sudo grep rotateCertificates /var/lib/kubelet/config.yaml"
k2s ssh m "sudo systemctl is-active kubelet"
kubectl get nodes
# Verify backup:
k2s ssh m "sudo ls -la /var/lib/kubelet/config.yaml.autorotation.bak"

# ── D: STATUS AFTER ENABLE ───────────────────────────────────────────
k2s system certificate autorotation --status
# Expected: enabled

# ── E: DISABLE ───────────────────────────────────────────────────────
k2s system certificate autorotation --disable
k2s ssh m "sudo grep rotateCertificates /var/lib/kubelet/config.yaml"
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
k2s system certificate autorotation --enable
k2s ssh m "sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate"
k2s ssh m "sudo rm /var/lib/kubelet/pki/kubelet-client-current.pem && sudo systemctl restart kubelet"
kubectl get csr --watch
# Expected: new CSR appears and is auto-approved within seconds
k2s ssh m "sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -serial -enddate"
# Expected: new serial, new expiry date
kubectl get nodes
# Expected: node Ready, no disruption

# ── J: CLUSTER RESTART PERSISTENCE ──────────────────────────────────
k2s system certificate autorotation --enable
k2s stop
k2s start
k2s system certificate autorotation --status
# Expected: still enabled
```

---

## K — Extra Scenarios (Architect-Level Edge Cases)

| Scenario | How to Verify |
|----------|--------------|
| **Controller-manager signing keys present** | `k2s ssh m "sudo grep cluster-signing /etc/kubernetes/manifests/kube-controller-manager.yaml"` — must show `--cluster-signing-cert-file` and `--cluster-signing-key-file` |
| **CSR auto-approval works for this node** | After CSR appears: `kubectl get csr` → condition should auto-change to `Approved,Issued` without manual `kubectl certificate approve` |
| **Cert saved to correct path** | After rotation: `k2s ssh m "sudo ls /var/lib/kubelet/pki/"` → `kubelet-client-current.pem` updated, old cert archived as `kubelet-client-<timestamp>.pem` |
| **No kubelet restart during pickup** | Kubelet picks up new cert by watching CSR — `sudo systemctl status kubelet` shows same PID before and after pickup |
| **Setting survives K2s upgrade** | Enable, upgrade K2s, check status — **NOTE:** upgrade replaces VHDX/rootfs so setting may be lost; re-enable after upgrade and document this |
| **kubelet-config ConfigMap alignment** | `kubectl -n kube-system get cm kubelet-config -o yaml \| grep rotateCertificates` — if K2s uses kubeadm-managed ConfigMap, this should also reflect the setting |
| **Windows worker node** | Windows node kubelet uses Windows Certificate Store — `rotateCertificates` in Linux config does not apply. Verify the command does not attempt to SSH into the Windows worker node |
| **Multiple runs during rotation window** | Enable auto-rotation when cert is at 80%+ lifetime — rotation should complete successfully via CSR loop without any manual intervention |

---

## L — Known Limitations / Out of Scope

| Item | Notes |
|------|-------|
| Control-plane component certs (kube-apiserver, etcd, scheduler) | Not auto-rotated by this feature. Use `k2s system certificate renew` |
| Windows worker node kubelet cert | Uses Windows Certificate Store — not handled by this command |
| Auto-rotation after K2s upgrade | Upgrade may reset kubelet config — re-run `--enable` post-upgrade |
| Cert expiry display in `--status` | Currently shows only enabled/disabled; future enhancement to also display cert expiry date |

