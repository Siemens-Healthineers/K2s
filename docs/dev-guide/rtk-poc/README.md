<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# RTK Proof-of-Concept — K2s Token Optimization

## Overview

This PoC validates [RTK (Rust Token Killer)](https://github.com/rtk-ai/rtk) for reducing LLM token consumption in K2s AI-assisted development workflows. Scope is limited to 1–3 developers running normal day-to-day workflows.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Developer Workstation                              │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐    ┌──────────────┐    ┌──────────────────────────┐    │
│  │ AI Agent    │    │   Terminal   │    │   RTK Binary (v0.34+)    │    │
│  │ (Copilot/   │◄───│  (PowerShell │◄───│                          │    │
│  │  Claude/    │    │   / bash)    │    │  ┌────────────────────┐  │    │
│  │  Cursor)    │    │              │    │  │ Built-in Filters   │  │    │
│  └─────────────┘    └──────────────┘    │  │ (100+ commands)    │  │    │
│        ▲                                │  └────────────────────┘  │    │
│        │ compressed                     │  ┌────────────────────┐  │    │
│        │ output                         │  │ .rtk/filters.toml  │  │    │
│        │                                │  │ (K2s-specific)     │  │    │
│        │                                │  └────────────────────┘  │    │
│        │                                │  ┌────────────────────┐  │    │
│        │                                │  │ SQLite Tracking    │  │    │
│        │                                │  │ (history.db)       │  │    │
│        │                                │  └─────────┬──────────┘  │    │
│        │                                └────────────┼─────────────┘    │
│        │                                             │                  │
│        │                                             ▼                  │
│        │                                ┌──────────────────────────┐    │
│        │                                │  Metrics Exporter        │    │
│        │                                │  (PowerShell scheduled)  │    │
│        │                                │  → JSON → Prometheus     │    │
│        │                                └─────────┬────────────────┘    │
│        │                                          │                     │
└────────┼──────────────────────────────────────────┼─────────────────────┘
         │                                          │
         │                                          ▼
         │                              ┌────────────────────────┐
         │                              │  Prometheus            │
         │                              │  (scrape /metrics)     │
         │                              └───────────┬────────────┘
         │                                          │
         │                                          ▼
         │                              ┌────────────────────────┐
         │                              │  Grafana               │
         │                              │  (dashboards)          │
         │                              └────────────────────────┘
```

## Quick Start

```powershell
# 1. Install RTK
.\scripts\Install-Rtk.ps1

# 2. Verify installation
rtk --version
rtk gain

# 3. Run validation tests
.\scripts\Test-RtkValidation.ps1

# 4. Start metrics exporter (background)
.\scripts\Start-RtkMetricsExporter.ps1

# 5. Normal development — use rtk prefix
rtk go test ./k2s/...
rtk git status
rtk kubectl pods

# 6. Check savings
rtk gain --daily
```

## Rollback

```powershell
# Instant disable (session-level)
$env:RTK_DISABLED = "1"

# Or just stop using rtk prefix — all commands work normally without it

# Full uninstall
.\scripts\Uninstall-Rtk.ps1
```

## Deliverables

| File | Purpose |
|------|---------|
| `scripts/Install-Rtk.ps1` | Automated RTK installation |
| `scripts/Uninstall-Rtk.ps1` | Clean rollback |
| `scripts/Test-RtkValidation.ps1` | Validation test scenarios |
| `scripts/Start-RtkMetricsExporter.ps1` | Prometheus metrics exporter |
| `prometheus/rtk-metrics.yml` | Prometheus scrape config |
| `prometheus/rtk-rules.yml` | Alerting rules |
| `grafana/rtk-dashboard.json` | Grafana dashboard |
| `../../.rtk/filters.toml` | K2s-specific TOML filters |

## Constraints

- **Lightweight**: Single binary + TOML config, no daemon
- **Non-invasive**: Explicit `rtk` prefix; no auto-rewrite on native Windows
- **Reversible**: Remove binary + delete `.rtk/` folder = complete rollback
- **Observable**: All savings tracked in SQLite + exported to Prometheus
- **Safe**: Tee system preserves full output on failures; `-vvv` for raw output anytime

