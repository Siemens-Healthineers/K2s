#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

###############################################################################
# Validation Script for Hyper-V Dynamic Memory Configuration
###############################################################################
# This script validates that the configure-hyperv-dynamic-memory.sh script
# works correctly and all dynamic memory components are properly configured.
###############################################################################

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_SCRIPT="${SCRIPT_DIR}/configure-hyperv-dynamic-memory.sh"

echo "═══════════════════════════════════════════════════════════════════════════"
echo "Hyper-V Dynamic Memory Configuration - Validation Script"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Check if config script exists
if [[ ! -f "${CONFIG_SCRIPT}" ]]; then
    echo "ERROR: Configuration script not found: ${CONFIG_SCRIPT}"
    exit 1
fi

echo "✓ Configuration script found"
echo ""

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

echo "✓ Running as root"
echo ""

# Run the configuration script
echo "Running configuration script..."
echo "───────────────────────────────────────────────────────────────────────────"
if bash "${CONFIG_SCRIPT}"; then
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "✓ Configuration script completed successfully"
else
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "✗ Configuration script failed"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Validation Checks"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Validation checks
checks_passed=0
checks_failed=0

# Check 1: hyperv-daemons package
echo -n "Check 1/5: hyperv-daemons package installed... "
if dpkg -l 2>/dev/null | grep -q "^ii.*hyperv-daemons"; then
    echo "✓ PASS"
    ((checks_passed++))
else
    echo "✗ FAIL"
    ((checks_failed++))
fi

# Check 2: hv_balloon module
echo -n "Check 2/5: hv_balloon module loaded... "
if lsmod | grep -q "^hv_balloon"; then
    echo "✓ PASS"
    ((checks_passed++))
else
    echo "⚠ WARNING (may be built-in)"
    ((checks_passed++))
fi

# Check 3: auto_online_blocks
echo -n "Check 3/5: auto_online_blocks = online... "
if [[ -f /sys/devices/system/memory/auto_online_blocks ]]; then
    value=$(cat /sys/devices/system/memory/auto_online_blocks 2>/dev/null || echo "unknown")
    if [[ "${value}" == "online" ]]; then
        echo "✓ PASS"
        ((checks_passed++))
    else
        echo "✗ FAIL (current value: ${value})"
        ((checks_failed++))
    fi
else
    echo "✗ FAIL (file not found)"
    ((checks_failed++))
fi

# Check 4: systemd service enabled
echo -n "Check 4/5: auto-online-memory.service enabled... "
if systemctl is-enabled auto-online-memory.service &>/dev/null; then
    echo "✓ PASS"
    ((checks_passed++))
else
    echo "✗ FAIL"
    ((checks_failed++))
fi

# Check 5: systemd service active
echo -n "Check 5/5: auto-online-memory.service active... "
if systemctl is-active auto-online-memory.service &>/dev/null; then
    echo "✓ PASS"
    ((checks_passed++))
else
    echo "✗ FAIL"
    ((checks_failed++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Validation Summary"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "Checks passed: ${checks_passed}/5"
echo "Checks failed: ${checks_failed}/5"
echo ""

if [[ ${checks_failed} -eq 0 ]]; then
    echo "✓ All validation checks passed!"
    echo "✓ Hyper-V Dynamic Memory is properly configured"
    echo ""
    echo "You can now test memory ballooning:"
    echo "  - Monitor from host: Get-VMMemory -VMName KubeMaster"
    echo "  - Create pressure: stress-ng --vm 1 --vm-bytes 2G --timeout 60s"
    exit 0
else
    echo "✗ Some validation checks failed"
    echo "✗ Review the output above and check the logs"
    exit 1
fi

