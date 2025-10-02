<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->
<!-- markdownlint-disable MD041 -->

# AI Assistant Project Instructions

These instructions help AI coding agents work effectively in the K2s repository.
Keep responses concise, explain reasoning only when non-obvious, and prefer concrete edits.

## 1. Project Overview
K2s is a Windows-first Kubernetes distribution bundling required components and optional addons. Core goals: mixed Windows/Linux workload support, offline installation, minimal footprint. The repo produces multiple executables under `k2s/cmd/*` plus helper artifacts (PowerShell scripts, addons manifests, Windows networking utilities).

## 2. Architecture & Code Organization
- `k2s/cmd/*`: One package per executable. Keep only CLI-specific logic here; delegate domain logic.
- `k2s/internal/*`: Reusable internal Go packages (not public). Higher abstraction/domain config lives under `internal/core`.
- `k2s/addons/*`: Addon enable/disable scripts + Kubernetes manifests; automation consumes these via the `k2s addons` command.
- `bin/`: Vendor-supplied or generated helper executables (kubectl-like shortcuts, container runtime tools, build helpers). Do NOT modify binaries here; automation may overwrite.
- `docs/`: End-user + operations docs (MkDocs based). Update when changing user-visible behavior.
- `smallsetup/`: Windows bootstrap helpers (PowerShell modules, configuration artifacts).
- Logging: central log dir is `<SystemDrive>\var\log` (`internal/logging`). Each CLI may create component-specific logs.

## 3. CLI & Flag Conventions
- Main CLI uses Cobra (`cmd/k2s/cmd/**`). Avoid custom flag parsing there—add new commands under the correct functional sub-tree (e.g. `image`, `addons`, `system`).
- Smaller utilities (`vfprules`, `cplauncher`, etc.) use Go `flag` + helpers from `internal/cli` (e.g. `NewVersionFlag`, verbosity constants). Reuse helpers instead of duplicating version or verbosity handling.
- Version printing uses `internal/version` with linker-injected build info.
- Prefer lowercase UUIDs where applicable (see `vfprules`).

## 4. Logging Patterns
- Use `slog` via helpers in `internal/logging` or the structured wrapper used in the main k2s CLI (`cmd/k2s/utils/logging`).
- For standalone tools: create a component log file using `logging.SetupDefaultFileLogger(logDir, name, slog.LevelDebug, "component", cliName)`; then log structured key/value pairs.
- Honor verbosity flags (`-v` / `--verbosity`) in the main CLI. Do not introduce ad-hoc environment variables for log levels.

## 5. Error Handling
- Main CLI: Return rich errors as `*common.CmdFailure` when you want controlled user-facing output + structured logging.
- Utilities: Fail fast with `log.Fatalf` only for unrecoverable startup errors; otherwise prefer `slog.Error` then `os.Exit(1)`.
- Avoid panics except in truly exceptional, non-runtime scenarios (e.g. impossible invariant breaches). Wrap unexpected errors before surfacing.

## 6. Build & Tooling
- Primary binaries built via Go toolchain (module root `k2s/go.mod`). Use `go build ./...` for compilation; `go test ./...` for unit tests.
- Some artifacts (e.g. `pause.c`, `cphook.c`) require MinGW-w64 (documented under `cmd/cplauncher/README.md`). Keep build instructions accurate if dependencies change.
- Linker flags inject version data; replicate existing pattern (see workflows) when adding new binaries.

## 7. Testing
- Unit tests colocated next to code under `internal/**` and some `cmd/*` helpers.
- E2E framework under `test/e2e` (Go + DSL helpers). Avoid adding slow tests to unit packages; place integration / system scenarios under `test/e2e`.
- When modifying CLI surface, add or update tests that parse and assert command behavior (Cobra commands or flag-driven tools).

## 8. Windows-Specific Concerns
- Numerous tools rely on Windows networking (HNS/VFP). Keep P/Invoke / syscall code minimal and well-contained (see `cplauncher` and `vfprules`). Prefer reusing existing wrappers before adding new syscall logic.
- Paths should use `filepath` helpers; avoid hard-coded drive letters except where intentionally using `host.SystemDrive()`.

## 9. Addons & Manifests
- Addons follow a pattern: `Enable.ps1`, `Disable.ps1`, `Get-Status.ps1`, optional `Update.ps1`, plus a `addon.manifest.yaml`. Follow existing naming & manifest schema when creating new addons.
- Groups of Kubernetes dependencies may be managed by Dependabot grouping in `.github/dependabot.yml`.

## 10. Introducing New Code
When adding a new utility or command:
1. Decide if it belongs inside the monolithic `k2s` CLI (Cobra) or as a separate small exe.
2. Reuse `internal` packages—do not duplicate logic (search first).
3. Add flags consistently; for version support: `versionFlag := cli.NewVersionFlag(<name>)`.
4. Add structured logging early (create log file if persistent output needed).
5. Provide or update README in the new command folder with specific build/test instructions.
6. Update docs if user-facing behavior changes.

## 11. Common Pitfalls
- Duplicating logging setup instead of using `logging.SetupDefaultFileLogger`.
- Forgetting to set verbosity before constructing log handlers in the root CLI.
- Hardcoding temp directories instead of using helper utilities under `internal/os`.
- Adding external dependencies without updating Dependabot config if grouping needed.

## 12. Example: Adding a New Cobra Subcommand
```go
cmd := &cobra.Command{Use: "foo", Short: "Demo" , RunE: func(cmd *cobra.Command, args []string) error {
    slog.Info("executing", "args", args)
    return nil
}}
parent.AddCommand(cmd)
```

## 13. Example: Small Utility With Version Flag
```go
const cliName = "mytool"
func main(){
  versionFlag := cli.NewVersionFlag(cliName)
  flag.Parse()
  if *versionFlag { ve.GetVersion().Print(cliName); return }
  // logic
}
```

Refine these instructions if new patterns emerge. Keep this file lean and current.
