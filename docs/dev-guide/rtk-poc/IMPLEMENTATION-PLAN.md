<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# RTK PoC — Implementation Plan

## Timeline: 4 Weeks

```
Week 1: Setup & Baseline
├── Day 1-2: Install RTK, verify on 1 workstation
├── Day 3-4: Run validation suite, tune filters
└── Day 5:   Baseline metrics collection begins

Week 2: Integration & Observation
├── Day 1-2: Expand to 2-3 developers
├── Day 3-4: Start metrics exporter, establish baseline token usage
└── Day 5:   First weekly review (adjust filters if needed)

Week 3: Active Evaluation
├── All week: Normal development with RTK prefix
├── Track: token savings, failures, debugging incidents
└── Friday: Second weekly review

Week 4: Analysis & Recommendations
├── Day 1-3: Compile metrics, analyze results
├── Day 4:   Document findings, write recommendations
└── Day 5:   Decision point: expand / continue / discontinue
```

---

## Validation Scenarios

### ✅ Must Pass (Blocking)

| Scenario | Expected Behavior | Validation |
|----------|-------------------|------------|
| `rtk go build` with errors | All file:line errors preserved | Manual inspection |
| `rtk go test` with failures | Failed test names + messages preserved | Compare with raw |
| `rtk git status` | Modified/staged files visible | Manual inspection |
| `rtk kubectl pods` (cluster down) | Connection error preserved | Exit code != 0 |
| `rtk -vvv <any>` | Full raw output shown | Compare with direct command |
| Exit code propagation | `$LASTEXITCODE` matches underlying tool | Automated test |

### ✅ Should Pass (Non-Blocking)

| Scenario | Expected Behavior |
|----------|-------------------|
| `rtk go test` — 90%+ reduction | Output significantly shorter |
| `rtk git log` — commit messages preserved | Key info retained |
| `rtk kubectl pods` — problem pods highlighted | Failures prominently shown |
| K2s-specific TOML filters | Pester/PowerShell output compressed |
| `rtk gain` shows data | Tracking database populated |

### ⚠️ Known Limitations (Accepted)

| Limitation | Workaround |
|------------|------------|
| No auto-rewrite on native Windows | Use explicit `rtk` prefix |
| PowerShell native commands not intercepted | Use TOML filters for PS output |
| New/unknown commands pass through unfiltered | Add TOML rules as discovered |
| Token estimation is heuristic (chars/4) | Acceptable for PoC comparison |

---

## Rollback Strategy

### Level 1: Per-Command Bypass
```powershell
# Skip RTK for a single command
git status    # Just don't use rtk prefix
```

### Level 2: Session Disable
```powershell
$env:RTK_DISABLED = "1"
# All rtk commands now pass through unfiltered
```

### Level 3: Verbose/Debug Mode
```powershell
rtk -vvv go test ./...    # Shows full raw output alongside filtered
```

### Level 4: Full Uninstall
```powershell
.\scripts\Uninstall-Rtk.ps1
# Removes: binary, config, tracking data, PATH entry
# Does NOT remove: .rtk/filters.toml (inert without binary)
```

### Level 5: Repository Cleanup
```powershell
git rm -r .rtk/
# Removes project-level filters (only needed if discontinuing)
```

**Recovery time**: Instant (Level 1-3), <1 minute (Level 4), <5 minutes (Level 5)

---

## Risk Analysis

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Error info hidden during debugging | Medium | High | Tee system + `-vvv` + bypass |
| Developer forgets to use rtk prefix | High | Low | No harm — just less savings |
| TOML filter too aggressive | Low | Medium | `on_empty` messages indicate filtering occurred |
| RTK binary crash/hang | Very Low | Medium | Timeout + bypass immediately |
| Tracking DB corruption | Very Low | Low | Delete and recreate (no data loss risk) |
| Token estimation inaccurate | Medium | Low | Relative comparison still valid |

---

## Success Criteria

| Metric | Minimum | Target | Method |
|--------|---------|--------|--------|
| Average token reduction | >50% | >75% | `rtk gain` |
| Critical info preservation | 100% | 100% | Validation test suite |
| Developer satisfaction | 3/5 | 4/5 | Short survey at Week 4 |
| Overhead per command | <50ms | <15ms | `rtk gain` exec_time |
| Commands processed/day | >20 | >50 | Tracking data |
| Zero debugging regressions | 0 incidents | 0 incidents | Incident tracking |

---

## Decision Framework (Week 4)

| Outcome | Criteria | Action |
|---------|----------|--------|
| **Expand** | >60% savings, 0 debug regressions, >3/5 satisfaction | Roll out to full team |
| **Continue PoC** | Mixed results, need more data | Extend 2 weeks, adjust filters |
| **Discontinue** | <40% savings OR debug regressions OR <3/5 satisfaction | Uninstall, document learnings |

---

## Observability Checklist

- [ ] RTK installed on PoC workstations
- [ ] `.rtk/filters.toml` committed to repo
- [ ] Metrics exporter running (textfile or HTTP mode)
- [ ] Prometheus scraping RTK metrics
- [ ] Grafana dashboard imported
- [ ] Alerting rules loaded
- [ ] Weekly `rtk gain --daily` review scheduled
- [ ] `rtk discover` run weekly to find optimization gaps
- [ ] Validation test suite passing
- [ ] Developer feedback channel established

