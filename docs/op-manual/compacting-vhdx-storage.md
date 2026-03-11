<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Compacting VHDX Storage

The Kubemaster VM uses a dynamically expanding VHDX. It grows when data is written but **does not shrink** when data is deleted (the "High Water Mark" issue). Use `k2s system compact` to reclaim wasted space after operations like importing/deleting container images or downloading large files.

## How It Works

1. **fstrim** – Runs inside the VM to notify Hyper-V which blocks are free.
2. **Optimize-VHD** – Physically shrinks the VHDX file on the Windows host.
3. **Restart** – Cluster is stopped for compaction and restarted by default.

## Usage

```console
k2s system compact
```

Skip confirmation prompts:

```console
k2s system compact --yes
```

Compact but keep cluster stopped afterwards:

```console
k2s system compact --no-restart
k2s start  # restart manually when ready
```

## Troubleshooting

**VHDX locked / still mounted:**

```powershell
Dismount-VHD -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\KubeMaster.vhdx"
```

**No space saved:** The VHDX may already be compacted or contain mostly active data. Check disk usage inside the VM:

```console
k2s node connect -i 172.19.1.100 -u remote
df -h /
```

**WSL installations:** `k2s system compact` is only available for Hyper-V installations.

## Related Commands

- `k2s stop` / `k2s start` – Stop or start the cluster
- `k2s status` – Check cluster status
