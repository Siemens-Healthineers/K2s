<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# RTK PoC — Rollout Strategy & Validation Framework

> **Purpose**: Define the safest, most measurable path to validate RTK's value in K2s development.  
> **Scope**: 1–3 developers, explicit `rtk` prefix only, no auto-rewrite, easy rollback.  
> **Duration**: 4 weeks active PoC + 1 week analysis.

---

## 1. Controlled PoC Execution

### Participant Selection

| Criterion | Rationale |
|-----------|-----------|
| Developer uses AI coding tools daily | Ensures meaningful token volume |
| Mix of Go CLI + PowerShell + kubectl work | Covers all K2s filter categories |
| Comfortable with terminal workflows | Reduces learning-curve noise in results |
| Willing to log observations (1 min/day) | Qualitative feedback alongside metrics |

**Recommended**: 2 developers initially, add 1 more in Week 2 after Day 1-2 validation passes.

### Execution Rules

```
┌─────────────────────────────────────────────────────────────────┐
│                    PoC Operating Constraints                      │
├─────────────────────────────────────────────────────────────────┤
│ ✓ Explicit rtk prefix only (rtk go test, rtk git status)       │
│ ✓ Normal daily development workflows — no artificial load       │
│ ✓ RTK_DISABLED=1 as immediate escape valve                      │
│ ✓ Report any debugging difficulty within 24h                    │
│ ✗ No shell hooks / auto-rewrite                                 │
│ ✗ No mandatory usage — developers choose when to use rtk        │
│ ✗ No CI/CD integration during PoC                               │
│ ✗ No changes to existing build scripts                          │
└─────────────────────────────────────────────────────────────────┘
```

### Daily Developer Protocol

```
Morning:
  $ rtk gain --daily          # 5-second check: yesterday's savings

During work:
  $ rtk go test ./k2s/...    # Use rtk where natural
  $ rtk git status
  $ rtk kubectl pods

End of day:
  $ rtk gain                  # Note total savings
  $ rtk discover              # Check missed opportunities (weekly)

If issue:
  $ rtk -vvv <cmd>           # Get raw output
  $ git status               # Compare without rtk (bypass)
  → Log issue in shared doc
```

### Rollback Triggers (Automatic)

| Trigger | Action | Recovery Time |
|---------|--------|---------------|
| Developer reports missed error causing >30 min debugging | Pause PoC, investigate filter | Instant (remove prefix) |
| RTK crash/hang on any command | Report upstream, bypass command | Instant |
| 3+ developers report workflow friction in same day | Pause PoC, review feedback | Instant |
| Metrics show <30% avg savings after Week 2 | Consider discontinuation | N/A |

---

## 2. Validation Metrics

### Primary Metrics (Automated via RTK tracking)

| Metric | Definition | Source | Target |
|--------|-----------|--------|--------|
| **Token Reduction %** | `(input_tokens - output_tokens) / input_tokens × 100` | `rtk gain` | >70% |
| **Compression Ratio** | `output_tokens / input_tokens` | `rtk gain` | <0.30 |
| **Commands Optimized/Day** | Count of commands processed by RTK per day | tracking.db | >30 |
| **Savings by Command Type** | Token savings grouped by command category | `rtk gain --history` | Varies |
| **Overhead (ms)** | RTK processing time per command | `exec_time_ms` in DB | <15ms avg |

### Context Reduction Metrics (Derived)

| Metric | Calculation | Interpretation |
|--------|-------------|----------------|
| **Context Window Utilization** | `Σ output_tokens per session / 200,000` | Lower = more room for code context |
| **Noisy Log Reduction** | Savings % for log/kubectl/test commands specifically | How much noise removed |
| **Session Token Budget** | `Σ input_tokens` for all commands in a coding session | Total would-be consumption |
| **Effective Context Savings** | `Σ saved_tokens × avg_sessions_per_day` | Daily token budget freed |

### Agent Request Savings (Estimated)

| Metric | Calculation | Notes |
|--------|-------------|-------|
| **Estimated Premium Requests Saved** | `total_saved_tokens / avg_tokens_per_request` | ~4000 tokens/request baseline |
| **Input Token Reduction per Turn** | Compare accumulated context size with/without RTK | Requires A/B comparison |
| **Iteration Reduction** | Track how many agent turns needed per task | Qualitative — less noise → better first-try responses |

### Developer Productivity Indicators (Qualitative + Quantitative)

| Indicator | Measurement | Method |
|-----------|-------------|--------|
| Time-to-resolution | Did debugging take longer/shorter? | Developer daily log |
| AI response quality | Did AI give better answers with compressed context? | Subjective 1-5 rating |
| Workflow friction | How often did developer need to bypass RTK? | Count of raw-command usage |
| Context overflow incidents | Times AI said "context too long" or truncated | Count from AI tool |
| Cognitive load | Did compressed output make terminal easier to read? | Subjective rating |

### Debugging Quality Impact

| Metric | Method | Pass Criteria |
|--------|--------|---------------|
| Error message preservation | Compare rtk vs raw for failed commands | 100% of errors visible |
| File:line info retention | Check build/test failures include source locations | 100% preserved |
| Stack trace completeness | Test with panics/exceptions | Full trace in output |
| Exit code accuracy | Automated test across all command types | 100% match |
| Tee recovery usability | On failure, verify raw output accessible | File exists + readable |

---

## 3. Real-World Testing Scenarios — Validation Matrix

### Build & Test Workflows

| Scenario | RTK Command | Validation Criteria | Priority |
|----------|-------------|--------------------| ---------|
| Go build success | `rtk go build ./k2s/cmd/k2s` | Output: minimal or "ok" | P1 |
| Go build failure | `rtk go build ./nonexistent/` | File:line errors preserved, exit code ≠ 0 | P1 |
| Go test all pass | `rtk go test ./k2s/internal/cli/...` | Summary: "N passed" | P1 |
| Go test with failures | `rtk go test ./k2s/test/...` | Failed test names + assertion messages | P1 |
| Go test race detector | `rtk go test -race ./...` | Race condition details preserved | P2 |
| Go test verbose | `rtk go test -v ./...` | Still compressed (verbose is pre-rtk) | P2 |
| bgo/bgow build scripts | `rtk bgow` | Success/error status via TOML filter | P2 |
| Pester unit tests | `rtk pwsh -File addons.module.unit.tests.ps1` | Failures preserved, passing suppressed | P2 |

### Git Operations

| Scenario | RTK Command | Validation Criteria | Priority |
|----------|-------------|--------------------| ---------|
| Status (clean) | `rtk git status` | "clean" or minimal output | P1 |
| Status (dirty) | `rtk git status` | Modified/staged files listed | P1 |
| Diff (small) | `rtk git diff` | Key changes visible | P1 |
| Diff (large, 500+ lines) | `rtk git diff` | Significant reduction, summary useful | P2 |
| Log (recent) | `rtk git log -10` | Commit messages readable | P1 |
| Push/pull | `rtk git push` | "ok" + branch/ref info | P1 |
| Merge conflict | `rtk git merge feature` | Conflict details preserved | P1 |
| Commit | `rtk git commit -m "msg"` | "ok" + short hash | P1 |

### Kubernetes & Log Operations

| Scenario | RTK Command | Validation Criteria | Priority |
|----------|-------------|--------------------| ---------|
| Pods (all healthy) | `rtk kubectl pods` | Summary: "N/N healthy" | P1 |
| Pods (with failures) | `rtk kubectl pods` | Problem pods highlighted | P1 |
| Cluster unreachable | `rtk kubectl pods` | Connection error preserved, exit ≠ 0 | P1 |
| Pod logs | `rtk kubectl logs <pod>` | Deduplicated, key errors shown | P2 |
| Describe (verbose) | `rtk kubectl describe pod/x` | Events/conditions focused | P2 |
| Apply manifests | `rtk kubectl apply -f dir/` | Created/changed resources shown | P2 |
| Services | `rtk kubectl services` | Compact service list | P3 |

### CI/CD-Style Outputs

| Scenario | RTK Command | Validation Criteria | Priority |
|----------|-------------|--------------------| ---------|
| SSH apt-get install | `rtk ssh user@vm "apt-get install -y pkg"` | Errors shown, progress stripped | P2 |
| SSH dpkg-query | via TOML filter | Compact package list | P2 |
| Helm install | `rtk helm install ...` | Status shown, warnings stripped | P2 |
| Docker build | `rtk docker build .` | Errors preserved, layer progress stripped | P3 |
| MkDocs build | `rtk mkdocs build` | Warnings/errors shown, info stripped | P3 |

### Failure & Debugging Scenarios

| Scenario | RTK Command | Critical Validation | Priority |
|----------|-------------|--------------------| ---------|
| Go panic with stack trace | `rtk go test` (panicking test) | **Full stack trace in output** | P1 |
| Segfault / signal | `rtk go test` (SIGSEGV) | **Signal info + core dump path** | P1 |
| Compilation error chain | `rtk go build` (multiple errors) | **All errors shown, not just first** | P1 |
| kubectl OOMKilled | `rtk kubectl describe pod/x` | **OOMKilled reason visible** | P1 |
| Test timeout | `rtk go test -timeout 5s` | **Timeout message + which test** | P1 |
| Permission denied | `rtk kubectl apply -f ...` | **RBAC error message preserved** | P1 |
| Network timeout | `rtk git push` (to unreachable remote) | **Timeout error visible** | P1 |

### Long AI-Agent Sessions

| Scenario | What to Measure | Target |
|----------|----------------|--------|
| 30-min Claude Code session | Total tokens with/without RTK | >60% reduction |
| Multi-file refactoring task | Number of agent iterations needed | Fewer with RTK (qualitative) |
| Debugging workflow | Time from error to fix | No regression |
| Context window saturation | Point at which AI loses context | Later with RTK |
| Repeated command execution | Token cost of git status × 10 in session | 80% savings on repetition |

---

## 4. Observability Improvements

### Missing Metrics (Add to Exporter)

| Metric | Type | Why |
|--------|------|-----|
| `rtk_commands_bypassed_total` | Counter | Commands run without rtk prefix (estimate via discover) |
| `rtk_tee_files_created_total` | Counter | How often full output recovery is needed |
| `rtk_filter_type_applied` | Counter with label `{filter="toml\|builtin\|passthrough"}` | Which filter layer handled the command |
| `rtk_session_duration_seconds` | Histogram | How long developers use RTK per sitting |
| `rtk_context_window_pressure` | Gauge | Estimated % of 200K context consumed by terminal output |
| `rtk_overhead_ms_p99` | Summary | Tail latency — catches slow commands |
| `rtk_errors_total` | Counter | RTK internal failures (filter crashes, DB errors) |

### Dashboard Improvements

Add these panels to the existing Grafana dashboard:

| Panel | Type | Description |
|-------|------|-------------|
| **Savings Heatmap** | Heatmap | Hour-of-day vs day-of-week savings intensity |
| **Compression Distribution** | Histogram | Distribution of savings % across all commands |
| **Command Category Trend** | Stacked area | Daily token savings by category (git/go/k8s/system) |
| **Overhead Percentiles** | Time series | p50, p90, p99 of RTK processing time |
| **Bypass Rate** | Time series | Ratio of rtk-commands to total commands (adoption) |
| **Filter Coverage** | Pie chart | builtin vs toml vs passthrough distribution |
| **Tee File Count** | Stat + trend | How often raw output recovery is triggered |
| **Weekly Summary Table** | Table | Week-over-week comparison of key metrics |

### Alert Tuning

| Alert | Current | Recommended Change |
|-------|---------|-------------------|
| `RtkLowCompression` | <40% for 1h | Change to: <40% for **4h** (short spikes during debugging are normal) |
| `RtkNoActivity` | 0 commands in 24h | Add **weekday-only** condition (no alerts on weekends) |
| **NEW**: `RtkHighOverhead` | — | Alert if `p99 overhead > 100ms` for 30min |
| **NEW**: `RtkTeeSpike` | — | Alert if `tee_files_created > 10 in 1h` (may indicate filter issues) |
| **NEW**: `RtkFilterError` | — | Alert immediately if `rtk_errors_total` increases |

### Useful Dimensions/Labels

```yaml
# Add to all metrics where applicable:
labels:
  developer: "dev1|dev2|dev3"      # Per-developer comparison (anonymous ID)
  command_type: "git|go|kubectl|system|toml"
  filter_source: "builtin|toml|passthrough"
  outcome: "success|failure"        # Based on exit code
  session: "morning|afternoon"      # Rough time categorization
  project: "k2s"                    # For multi-project environments
```

### Trend Analysis Ideas

| Analysis | Method | Insight |
|----------|--------|---------|
| Savings trend over time | Linear regression on daily savings % | Is RTK becoming more/less effective? |
| Command frequency evolution | Week-over-week command type distribution | Are developers using RTK for new command types? |
| Filter gap detection | `rtk discover` output over time | Diminishing returns or new opportunities? |
| Session efficiency | Tokens saved per hour of development | Normalizes for different workloads |
| Decay detection | Savings % drop after tool updates | Tool output format changes breaking filters |

---

## 5. Risk Analysis — Deep Dive

### Scenarios Where Semantic Compression May Hide Details

| Scenario | What's Hidden | Detection | Impact |
|----------|--------------|-----------|--------|
| **Go test: data race** | Goroutine stack traces | Race output is unique — RTK should pass through | Medium |
| **Go test: table-driven subtests** | Individual subtest names in large tables | Only failures shown; passing subtest names lost | Low |
| **git diff: whitespace changes** | Whitespace-only diffs compressed to summary | May miss formatting issues | Low |
| **kubectl: pending pods** | Pods stuck in Pending (not CrashLoop) | RTK highlights CrashLoop but Pending is "healthy-ish" | Medium |
| **kubectl: resource limits** | Memory/CPU limits in describe | Stripped as "noise" unless OOMKilled | Medium |
| **SSH: locale/encoding warnings** | Locale warnings that explain garbled output | Stripped as banner noise | Low |
| **PowerShell: cmdlet verbose** | Verbose stream details during provisioning | Stripped by TOML filter; errors preserved | Low-Medium |

### Debugging Edge Cases

| Edge Case | Risk | Mitigation |
|-----------|------|------------|
| Error message spans multiple lines | RTK's line-by-line filtering might split context | RTK preserves all lines on non-zero exit (tee) |
| Error is in stdout, not stderr | Some tools (Go) put errors on stdout | RTK filters by content, not stream |
| Binary/garbled output | Non-UTF8 bytes in command output | RTK's `strip_ansi` handles; raw saved in tee |
| Interleaved stdout/stderr ordering | Concurrent output from parallel tests | RTK captures post-execution, ordering preserved |
| Very large output (>1MB) | Long test suite or big log dump | `max_lines` cap applies; tee saves full output |
| Command output changes between versions | Tool upgrade changes output format | Filter stops matching → passthrough (safe failure) |

### Operational Risks

| Risk | Likelihood | Severity | Detection | Response |
|------|-----------|----------|-----------|----------|
| RTK binary becomes unavailable (deleted, PATH broken) | Low | Low | Command fails with "rtk not found" | Remove prefix, continue normally |
| SQLite DB locked (parallel access) | Very Low | None | Tracking silently skipped | No user impact; metrics gap |
| TOML filter regex causes catastrophic backtracking | Very Low | Medium | Command hangs | Kill + add to `exclude_commands` |
| New Go version changes test output format | Low | Low | Savings drop for `go test` | Update RTK (upstream fix) |
| Developer becomes over-reliant on RTK summaries | Medium | Low | Misses deployment issue | Verify critical ops with raw output |

### Developer Workflow Friction Points

| Friction | Who's Affected | Mitigation |
|----------|---------------|------------|
| Typing `rtk ` prefix on every command | All participants | Aliases: `alias rg='rtk git'` in profile |
| Forgetting to use prefix with AI tools | Copilot/Claude users | Document in copilot-instructions.md |
| Output looks different than expected | New RTK users | 1-week adjustment period; `-v` for more detail |
| Unsure if error is real or RTK artifact | During first week | Compare with raw output; trust exit codes |
| Configuration confusion | New users | Single config file, clear docs |

---

## 6. Success Criteria — Decision Matrix

### Quantitative Criteria

| Metric | Reject (<) | Continue (range) | Expand (>) | Source |
|--------|-----------|-----------------|------------|--------|
| Average token savings | <40% | 40-65% | >65% | `rtk gain` |
| Critical info preservation | <100% | 100% | 100% | Validation suite |
| Commands optimized/day/dev | <15 | 15-40 | >40 | tracking.db |
| Overhead p99 | >100ms | 30-100ms | <30ms | tracking.db |
| Debugging regressions | ≥2 incidents | 1 incident | 0 incidents | Dev log |
| Filter coverage | <50% commands | 50-75% | >75% | `rtk discover` |

### Qualitative Criteria

| Indicator | Reject | Continue | Expand |
|-----------|--------|----------|--------|
| Developer satisfaction (1-5) | <3 | 3-3.9 | ≥4 |
| Would recommend to colleague? | No | Maybe | Yes |
| AI response quality improved? | Worse | No change | Better |
| Want to keep using? | No | Indifferent | Yes |
| Debugging experience | Degraded | Same | Same or better |

### Decision Matrix

```
                    Quantitative Score
                    Low (0-3)    Mid (4-6)    High (7-10)
                  ┌────────────┬────────────┬────────────┐
Qualitative  High │  Continue  │   Expand   │   Expand   │
Score        Mid  │  Continue  │  Continue  │   Expand   │
             Low  │   Reject   │  Continue  │  Continue  │
                  └────────────┴────────────┴────────────┘
```

### Scoring Method

**Quantitative (0-10 points):**
- Token savings >70%: +3 pts
- Token savings 50-70%: +2 pts
- Zero debug regressions: +3 pts
- Commands/day/dev >40: +2 pts
- Overhead <30ms: +1 pt
- Filter coverage >75%: +1 pt

**Qualitative (0-10 points):**
- Satisfaction ≥4/5: +3 pts
- "Would recommend": +2 pts
- AI response quality improved: +3 pts
- "Want to keep using": +2 pts

### Timeline for Decision

```
Week 2 Friday: First checkpoint
  → If debugging regression OR satisfaction <2: STOP immediately
  → Otherwise: continue

Week 3 Friday: Second checkpoint
  → If quantitative score <3 AND qualitative <3: recommend REJECT
  → Otherwise: continue to full evaluation

Week 4 Friday: Final decision
  → Score all criteria
  → Apply decision matrix
  → Document recommendation with data
```

---

## 7. Future Opportunities

### Near-Term (If PoC succeeds — Weeks 5-12)

| Opportunity | Description | Effort | Impact |
|-------------|-------------|--------|--------|
| **Copilot instructions integration** | Add RTK guidance to `.github/copilot-instructions.md` | Low | Medium |
| **CI/CD log compression** | Pipe CI output through RTK filters for artifact size reduction | Medium | Low |
| **Team-wide rollout** | Expand to full K2s development team | Low | High |
| **Custom filter library** | Build comprehensive K2s-specific TOML filter set | Medium | Medium |
| **RTK binary in bin/** | Vendor RTK alongside other K2s tools (kubectl, helm, etc.) | Low | Medium |

### Medium-Term (Months 2-6)

| Opportunity | Description | Effort | Impact |
|-------------|-------------|--------|--------|
| **AI Token Observability Platform** | Centralized dashboard tracking token usage across all developers/tools | High | High |
| **Context-Quality Scoring** | Metric that measures signal-to-noise ratio of context sent to LLMs | High | High |
| **Semantic Diff Compression** | Custom filter for `k2s system package` delta output — preserve diff semantics, compress noise | Medium | Medium |
| **MCP Context Optimization** | If K2s builds MCP server, integrate RTK-style filtering in tool responses | Medium | High |
| **Organization-wide standards** | Define "AI Context Hygiene" standards for all projects | Medium | High |

### Long-Term (6+ Months)

| Opportunity | Description |
|-------------|-------------|
| **AI Engineering Standards** | Org-wide guidelines: context optimization, prompt engineering, token budgeting |
| **LLM Cost Attribution** | Per-project, per-developer token cost tracking (tie RTK savings to $$$) |
| **Adaptive Compression** | ML model that learns per-developer what context they value vs noise |
| **Cross-Session Memory** | Don't re-send context that was already shown in conversation |
| **Predictive Context Loading** | Pre-compress likely-needed files based on current task |
| **Protocol-Level Integration** | Propose RTK-style filtering as extension to MCP/LSP standards |

### Context-Quality Scoring (Concept)

A future metric to quantify how "good" the context sent to an LLM is:

```
Context Quality Score = (semantic_density × relevance) / noise_ratio

Where:
  semantic_density  = meaningful_tokens / total_tokens
  relevance         = tokens_related_to_task / total_tokens  
  noise_ratio       = (progress_bars + banners + duplicates) / total_tokens
```

**PoC measurement approach**: Compare AI response quality (correct fixes, fewer iterations) when using RTK vs raw output. If RTK users get correct answers in fewer iterations, context quality improved.

### Organization-Wide AI Engineering Standards (Vision)

```
┌─────────────────────────────────────────────────────────────────┐
│              AI Engineering Maturity Model                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│ Level 1: Ad-hoc                                                  │
│   • Developers use AI tools with raw terminal output             │
│   • No context optimization                                      │
│   • No cost awareness                                            │
│                                                                  │
│ Level 2: Aware (← current state)                                 │
│   • Token/cost awareness exists                                  │
│   • .contextignore / copilot-instructions.md established         │
│   • Individual developers experiment with optimization           │
│                                                                  │
│ Level 3: Optimized (← goal after successful PoC)                 │
│   • RTK or equivalent deployed team-wide                         │
│   • Metrics tracked (token savings, context quality)             │
│   • Filters maintained alongside code                            │
│   • AI context optimization is part of dev workflow              │
│                                                                  │
│ Level 4: Systematic                                              │
│   • Organization-wide AI engineering standards                   │
│   • Cost attribution per project/team                            │
│   • Context quality SLOs (Service Level Objectives)              │
│   • Automated filter generation for new tools                    │
│   • CI/CD integration for token-optimized log artifacts          │
│                                                                  │
│ Level 5: Adaptive                                                │
│   • ML-driven compression tuning                                 │
│   • Cross-session context memory                                 │
│   • Predictive context loading                                   │
│   • Self-healing filters (detect format changes, auto-update)    │
│   • Protocol-level context optimization (MCP extensions)         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Appendix: Weekly Review Template

```markdown
# RTK PoC — Weekly Review (Week N)

## Metrics Snapshot
- Total commands this week: ___
- Average savings %: ___
- Top command type: ___
- Overhead p99: ___ms
- Tee files created (failures): ___

## Developer Feedback
- Developer 1: [satisfaction 1-5] [notes]
- Developer 2: [satisfaction 1-5] [notes]
- Developer 3: [satisfaction 1-5] [notes]

## Issues / Debugging Incidents
- [ ] (none) OR describe incident

## Filter Adjustments Made
- [ ] (none) OR describe change

## Missed Opportunities (rtk discover)
- Command X: ___% potential savings
- Command Y: ___% potential savings

## Decision
- [ ] Continue as-is
- [ ] Adjust filters (specify)
- [ ] Pause PoC (specify reason)
- [ ] Ready for decision point

## Action Items for Next Week
1. ___
2. ___
```

---

## Appendix: Developer Daily Log Template

```markdown
# RTK Daily Log — [Date]

Developer: ___

## Usage
- Approx rtk commands today: ___
- Bypassed (raw commands) today: ___
- `rtk gain` daily savings: ___% (___tokens)

## Quality
- AI response quality today (1-5): ___
- Any errors missed due to compression? [yes/no]
  - If yes: describe ___
- Any debugging difficulty? [yes/no]
  - If yes: describe ___

## Notes
- [freeform observations]
```

