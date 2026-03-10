<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Compacting VHDX Storage

## Overview

When running K2s on Hyper-V, the Kubemaster VM uses a **dynamically expanding VHDX** file as its virtual hard disk. While this VHDX grows automatically when you write data (pull images, create files), it **does not automatically shrink** when you delete data. This is known as the **"High Water Mark" issue**.

Over time, this can lead to wasted disk space on your Windows host—especially after operations like:
- Importing and deleting container images
- Building container images with large intermediate layers
- Downloading files to `/tmp` inside the VM
- Kubernetes logs accumulating and rotating

The `k2s system compact` command reclaims this wasted space.

---

## How It Works

The compaction process involves three key operations:

### 1. **fstrim** (Linux Guest)
Inside the VM, deleted files are marked as "free" by the ext4 filesystem, but Hyper-V doesn't know about this. The `fstrim` command sends **TRIM/DISCARD** notifications to the hypervisor, telling it which blocks are truly unused.

```bash
sudo fstrim -v /
# Example output: /: 2.3 GiB (2468364288 bytes) trimmed
```

### 2. **Optimize-VHD** (Windows Host)
With the freed blocks marked by `fstrim`, Windows can now physically shrink the VHDX file using `Optimize-VHD -Mode Full`. This operation compacts the file to remove the "holes" left by deleted data.

### 3. **Cluster Restart** (Optional)
The cluster is **always stopped** during compaction — `Optimize-VHD` requires exclusive access to the VHDX. By default the cluster is automatically restarted afterwards. Use `--no-restart` to keep it stopped, for example when you need to perform further maintenance before bringing it back up.

---

## Usage

### Basic Usage

Compact VHDX and automatically restart the cluster:

```console
k2s system compact
```

**Expected output:**
```
=====================================
   K2s VHDX Compaction              
=====================================
Target VM: kubemaster
VHDX path: C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\kubemaster.vhdx
Current VHDX size: 8.45 GB

[Step 1/6] Running fstrim inside VM to mark freed blocks...
Connecting to kubemaster (172.19.1.100)...
Running fstrim -v /...
fstrim result: /: 2.3 GiB (2468364288 bytes) trimmed
fstrim completed successfully

[Step 2/6] Cluster is currently running and must be stopped for compaction.
Stop cluster now? (y/n): y
Stopping cluster...
Cluster stopped successfully

[Step 3/6] Mounting VHDX (read-only)...
VHDX mounted successfully

[Step 4/6] Optimizing VHDX (this may take 5-10 minutes)...
Optimization completed in 6.2 minutes

[Step 5/6] Dismounting VHDX...
VHDX dismounted successfully

=====================================
   Compaction Results               
=====================================
Before:      8.45 GB
After:       5.78 GB
Saved:       2.67 GB (31.6%)
=====================================

[Step 6/6] Restarting cluster...
Cluster restarted successfully

VHDX compaction completed successfully!
```

---

## Command Options

### Skip Confirmation Prompts

Useful for automation or CI/CD pipelines:

```console
k2s system compact --yes
```

### Keep Cluster Stopped

The cluster is **always stopped** during compaction (required for VHDX optimization). By default it is restarted automatically when done. Use `--no-restart` to keep it stopped afterwards — useful for maintenance windows where you need to perform other operations before bringing the cluster back up:

```console
k2s system compact --no-restart
```

After maintenance, manually restart:

```console
k2s start
```


---

## When to Compact

You should consider compacting the VHDX when:

1. **After bulk image operations**: Pulling and deleting many container images
2. **After addon installations**: Some addons download large images
3. **Periodic maintenance**: Monthly or quarterly, depending on usage patterns
4. **Low disk space warnings**: When your Windows host is running low on disk space
5. **After build operations**: If you build images inside the cluster

---

## Expected Results

Typical space savings:

| Scenario | Before | After | Saved |
|----------|--------|-------|-------|
| Fresh install | 3.5 GB | 3.5 GB | 0 GB (no waste) |
| After pulling 5 large images | 8.5 GB | 8.5 GB | 0 GB (active data) |
| After deleting those 5 images | 8.5 GB | 4.0 GB | 4.5 GB (reclaimed) |
| Heavy use (months) | 15 GB | 6 GB | 9 GB (reclaimed) |

**Note**: You won't see savings if:
- No data has been deleted since last compaction
- The VHDX is mostly full with active data
- fstrim wasn't run (automatic if cluster is running)

---

## Performance Considerations

### Optimization Time

The `Optimize-VHD` operation time depends on:
- **VHDX size**: Larger files take longer
- **Disk speed**: SSD = 2-5 minutes, HDD = 10-20 minutes
- **Amount of free space**: More fragmentation = longer optimization

**Typical times:**
- Small VHDX (< 10 GB): 2-5 minutes
- Medium VHDX (10-30 GB): 5-10 minutes
- Large VHDX (> 30 GB): 10-20 minutes

### Cluster Downtime

The cluster is stopped during optimization. Plan accordingly:
- **Interactive use**: Run during off-hours
- **CI/CD**: Use `--yes` flag to avoid prompts
- **Production**: Schedule maintenance windows

---

## Troubleshooting

### Error: VM Not Stopped

**Symptom:**
```
Error: Failed to stop VM within timeout period.
```

**Solution:**
Manually stop the cluster first:

```console
k2s stop
k2s system compact
```

---

### Error: VHDX Locked

**Symptom:**
```
Error: Failed to mount VHDX: The process cannot access the file...
```

**Solution:**
1. Ensure VM is fully stopped:
   ```powershell
   Get-VM kubemaster | Select-Object Name, State
   ```
2. Check for mounted VHDX:
   ```powershell
   Get-VHD | Where-Object { $_.Attached -eq $true }
   ```
3. Manually dismount if needed:
   ```powershell
   Dismount-VHD -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\kubemaster.vhdx"
   ```

---

### Warning: fstrim Failed

**Symptom:**
```
Warning: fstrim failed: connection timeout
```

**Impact:** Optimization will still run, but may reclaim less space.

**Solution:**
- Check VM network connectivity
- Manually SSH and run `fstrim`:
  ```console
  k2s node connect -i 172.19.1.100 -u remote
  sudo fstrim -v /
  exit
  ```
- Re-run compact:
  ```console
  k2s system compact
  ```

---

### No Space Saved

**Symptom:**
```
Before:      8.45 GB
After:       8.42 GB
Saved:       0.03 GB (0.4%)
```

**Possible causes:**
1. **No deleted data**: VHDX is full of active files
2. **fstrim not run**: Run manually and retry
3. **Recent compaction**: Already compacted recently

**Verification:**
Check actual disk usage inside VM:
```console
k2s node connect -i 172.19.1.100 -u remote
df -h /
sudo du -sh /var/lib/containerd
exit
```

---

## WSL Installations

**Note:** The `compact` command is **only available for Hyper-V installations**. WSL-based K2s installations use a different storage backend (ext4 on a VHD in WSL's own location) and do not suffer from the High Water Mark issue in the same way.

If you run `k2s system compact` on a WSL installation:

```
K2s is running on WSL. VHDX compaction is only available for Hyper-V installations.
```

---

## Automation

### Scheduled Compaction

Create a scheduled task to compact monthly:

```powershell
$action = New-ScheduledTaskAction -Execute "k2s.exe" -Argument "system compact --yes"
$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At 3am
Register-ScheduledTask -TaskName "K2s Monthly Compact" -Action $action -Trigger $trigger -RunLevel Highest
```

### Pre-Flight Check

Before compaction, check available space:

```powershell
$vhdx = Get-VHD -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\kubemaster.vhdx"
$fileSize = [math]::Round($vhdx.FileSize / 1GB, 2)
Write-Host "Current VHDX size: $fileSize GB"

if ($fileSize -gt 20) {
    Write-Host "VHDX is large. Consider running: k2s system compact"
}
```

---

## Related Commands

- `k2s stop` - Stop the cluster
- `k2s start` - Start the cluster
- `k2s status` - Check cluster status
- `k2s system upgrade` - Upgrade K2s (also works with compacted VHDX)

---

## Technical Details

### Why Doesn't VHDX Auto-Shrink?

Dynamic VHDXs expand automatically for performance and safety reasons, but auto-shrinking would require:
1. Constant monitoring of filesystem free space (performance overhead)
2. Risk of data loss if shrink happens during writes
3. Frequent compaction (slow, reduces SSD lifespan)

Manual compaction gives you control over when this expensive operation happens.

### TRIM vs. Compact

| Operation | Where | What It Does | Shrinks VHDX? |
|-----------|-------|--------------|---------------|
| `fstrim` | Inside VM | Marks blocks as free | No |
| `Optimize-VHD` | Windows host | Physically shrinks file | Yes |

**Both are required** for successful compaction.

### Block Alignment

VHDXs use 1MB blocks by default. The final size after compaction is rounded to the nearest block boundary, so you may see slight differences from expected sizes.

---

## See Also

- [Delta Packages](delta-packages.md) - How K2s handles offline updates
- [Creating Offline Packages](creating-offline-package.md) - Building K2s packages
- [Upgrading K2s](upgrading-k2s.md) - Upgrading without losing data

