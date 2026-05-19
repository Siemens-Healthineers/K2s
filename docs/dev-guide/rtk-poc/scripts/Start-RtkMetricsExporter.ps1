<#
.SYNOPSIS
    Exports RTK token tracking data as Prometheus-compatible metrics.

.DESCRIPTION
    Reads RTK's SQLite tracking database and exposes metrics via a lightweight
    HTTP endpoint (or writes to a textfile for node_exporter textfile collector).

    Two modes:
    - HTTP server: Serves /metrics endpoint on configurable port
    - Textfile: Writes .prom file for Prometheus node_exporter

.PARAMETER Mode
    "http" for HTTP server, "textfile" for file output.

.PARAMETER Port
    HTTP port (default: 9191). Only used in HTTP mode.

.PARAMETER OutputFile
    Path to .prom output file. Only used in textfile mode.

.PARAMETER IntervalSeconds
    How often to refresh metrics (default: 60).

.NOTES
    SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
    SPDX-License-Identifier: MIT
#>

[CmdletBinding()]
param(
    [ValidateSet("http", "textfile")]
    [string]$Mode = "textfile",

    [int]$Port = 9191,

    [string]$OutputFile = "$env:TEMP\rtk_metrics.prom",

    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'

# ── Metric generation ──
function Get-RtkMetrics {
    <#
    .SYNOPSIS
        Queries RTK tracking and generates Prometheus metrics text.
    #>

    $metrics = [System.Text.StringBuilder]::new()

    # Get JSON data from rtk gain
    try {
        $gainJson = & rtk gain --all --format json 2>&1 | Out-String
        $data = $gainJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        # RTK not available or no data
        [void]$metrics.AppendLine("# HELP rtk_exporter_up Whether RTK metrics exporter can reach RTK")
        [void]$metrics.AppendLine("# TYPE rtk_exporter_up gauge")
        [void]$metrics.AppendLine("rtk_exporter_up 0")
        return $metrics.ToString()
    }

    [void]$metrics.AppendLine("# HELP rtk_exporter_up Whether RTK metrics exporter can reach RTK")
    [void]$metrics.AppendLine("# TYPE rtk_exporter_up gauge")
    [void]$metrics.AppendLine("rtk_exporter_up 1")

    # RTK JSON uses nested structure: { "summary": { ... }, "daily": [...] }
    $summary = if ($data.summary) { $data.summary } else { $data }

    # ── Total commands ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_commands_total Total commands processed by RTK")
    [void]$metrics.AppendLine("# TYPE rtk_commands_total counter")
    $totalCommands = if ($summary.total_commands) { $summary.total_commands } else { 0 }
    [void]$metrics.AppendLine("rtk_commands_total $totalCommands")

    # ── Total tokens saved ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_tokens_saved_total Total tokens saved by RTK compression")
    [void]$metrics.AppendLine("# TYPE rtk_tokens_saved_total counter")
    $totalSaved = if ($summary.total_saved) { $summary.total_saved } else { 0 }
    [void]$metrics.AppendLine("rtk_tokens_saved_total $totalSaved")

    # ── Total input tokens ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_tokens_input_total Total input tokens before RTK compression")
    [void]$metrics.AppendLine("# TYPE rtk_tokens_input_total counter")
    $totalInput = if ($summary.total_input) { $summary.total_input } else { 0 }
    [void]$metrics.AppendLine("rtk_tokens_input_total $totalInput")

    # ── Total output tokens ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_tokens_output_total Total output tokens after RTK compression")
    [void]$metrics.AppendLine("# TYPE rtk_tokens_output_total counter")
    $totalOutput = if ($summary.total_output) { $summary.total_output } else { 0 }
    [void]$metrics.AppendLine("rtk_tokens_output_total $totalOutput")

    # ── Average savings percentage ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_savings_percent_avg Average token savings percentage")
    [void]$metrics.AppendLine("# TYPE rtk_savings_percent_avg gauge")
    $avgSavings = if ($summary.avg_savings_pct) { $summary.avg_savings_pct } else { 0 }
    [void]$metrics.AppendLine("rtk_savings_percent_avg $avgSavings")

    # ── Compression ratio ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_compression_ratio Current compression ratio (output/input)")
    [void]$metrics.AppendLine("# TYPE rtk_compression_ratio gauge")
    if ($totalInput -gt 0) {
        $ratio = [math]::Round($totalOutput / $totalInput, 4)
    } else {
        $ratio = 1.0
    }
    [void]$metrics.AppendLine("rtk_compression_ratio $ratio")

    # ── Per-command breakdown (from history) ──
    try {
        $historyJson = & rtk gain --history --format json 2>&1 | Out-String
        $history = $historyJson | ConvertFrom-Json -ErrorAction Stop

        if ($history -and $history.Count -gt 0) {
            [void]$metrics.AppendLine("")
            [void]$metrics.AppendLine("# HELP rtk_command_savings_tokens Tokens saved per command type")
            [void]$metrics.AppendLine("# TYPE rtk_command_savings_tokens gauge")

            [void]$metrics.AppendLine("")
            [void]$metrics.AppendLine("# HELP rtk_command_count_total Commands executed per type")
            [void]$metrics.AppendLine("# TYPE rtk_command_count_total counter")

            # Group by command base (first word after 'rtk')
            $grouped = $history | Group-Object { ($_.rtk_cmd -split '\s+')[1] } |
                Where-Object { $_.Name }

            foreach ($group in $grouped) {
                $cmdType = $group.Name -replace '[^a-zA-Z0-9_]', '_'
                $count = $group.Count
                $savedSum = ($group.Group | Measure-Object -Property saved_tokens -Sum).Sum

                [void]$metrics.AppendLine("rtk_command_count_total{command_type=`"$cmdType`"} $count")
                [void]$metrics.AppendLine("rtk_command_savings_tokens{command_type=`"$cmdType`"} $savedSum")
            }
        }
    }
    catch {
        # History not available — skip per-command metrics
    }

    # ── Estimated cost savings (at $3/MTok for input) ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_estimated_cost_savings_usd Estimated USD saved based on token reduction")
    [void]$metrics.AppendLine("# TYPE rtk_estimated_cost_savings_usd gauge")
    $costSaved = [math]::Round($totalSaved * 0.000003, 4)  # $3 per million tokens
    [void]$metrics.AppendLine("rtk_estimated_cost_savings_usd $costSaved")

    # ── Estimated premium requests saved ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_premium_requests_saved_estimate Estimated premium requests saved (at ~4000 tokens/request)")
    [void]$metrics.AppendLine("# TYPE rtk_premium_requests_saved_estimate gauge")
    $requestsSaved = [math]::Floor($totalSaved / 4000)
    [void]$metrics.AppendLine("rtk_premium_requests_saved_estimate $requestsSaved")

    # ── Tee files (raw output recovery) ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_tee_files_total Number of tee recovery files (full output saved on failure)")
    [void]$metrics.AppendLine("# TYPE rtk_tee_files_total gauge")
    $teeDir = if ($env:RTK_TEE_DIR) { $env:RTK_TEE_DIR }
              elseif ($env:LOCALAPPDATA) { "$env:LOCALAPPDATA\rtk\tee" }
              else { "$env:HOME/.local/share/rtk/tee" }
    $teeCount = 0
    if (Test-Path $teeDir) {
        $teeCount = (Get-ChildItem -Path $teeDir -Filter "*.log" -ErrorAction SilentlyContinue | Measure-Object).Count
    }
    [void]$metrics.AppendLine("rtk_tee_files_total $teeCount")

    # ── Overhead statistics ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_overhead_ms_avg Average RTK processing overhead in milliseconds")
    [void]$metrics.AppendLine("# TYPE rtk_overhead_ms_avg gauge")
    $avgOverhead = if ($summary.avg_time_ms) { $summary.avg_time_ms } else { 0 }
    [void]$metrics.AppendLine("rtk_overhead_ms_avg $avgOverhead")

    # ── Missed optimization opportunities (from discover) ──
    try {
        $discoverJson = & rtk discover --all --format json 2>&1 | Out-String
        $discoverData = $discoverJson | ConvertFrom-Json -ErrorAction Stop
        $missedCount = if ($discoverData.Count) { $discoverData.Count } else { 0 }

        [void]$metrics.AppendLine("")
        [void]$metrics.AppendLine("# HELP rtk_missed_opportunities_total Commands that could be optimized but were not routed through RTK")
        [void]$metrics.AppendLine("# TYPE rtk_missed_opportunities_total gauge")
        [void]$metrics.AppendLine("rtk_missed_opportunities_total $missedCount")
    }
    catch {
        # discover not available or no data
    }

    # ── Context window pressure estimate ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_context_pressure_ratio Estimated terminal output as fraction of 200K context window")
    [void]$metrics.AppendLine("# TYPE rtk_context_pressure_ratio gauge")
    # Estimate: output tokens from last 30 commands as proxy for a session
    $contextPressure = if ($totalOutput -gt 0 -and $totalCommands -gt 0) {
        $avgOutputPerCmd = $totalOutput / $totalCommands
        $sessionCmds = [math]::Min($totalCommands, 30)
        [math]::Round(($avgOutputPerCmd * $sessionCmds) / 200000, 4)
    } else { 0 }
    [void]$metrics.AppendLine("rtk_context_pressure_ratio $contextPressure")

    # ── Session info ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_info RTK version and configuration info")
    [void]$metrics.AppendLine("# TYPE rtk_info gauge")
    $version = (& rtk --version 2>&1) -replace 'rtk\s+', ''
    [void]$metrics.AppendLine("rtk_info{version=`"$version`",mode=`"explicit`",project=`"k2s`"} 1")

    # ── Timestamp ──
    [void]$metrics.AppendLine("")
    [void]$metrics.AppendLine("# HELP rtk_last_scrape_timestamp_seconds Unix timestamp of last metrics collection")
    [void]$metrics.AppendLine("# TYPE rtk_last_scrape_timestamp_seconds gauge")
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [void]$metrics.AppendLine("rtk_last_scrape_timestamp_seconds $timestamp")

    return $metrics.ToString()
}

# ── Main loop ──
Write-Host "[RTK-Metrics] Starting RTK metrics exporter (mode: $Mode)" -ForegroundColor Cyan

if ($Mode -eq "textfile") {
    Write-Host "[RTK-Metrics] Output: $OutputFile (refresh: ${IntervalSeconds}s)" -ForegroundColor Cyan
    Write-Host "[RTK-Metrics] Press Ctrl+C to stop" -ForegroundColor Yellow
    Write-Host ""

    while ($true) {
        try {
            $metricsText = Get-RtkMetrics
            Set-Content -Path $OutputFile -Value $metricsText -Encoding UTF8 -NoNewline
            $timestamp = Get-Date -Format "HH:mm:ss"
            Write-Host "[RTK-Metrics] [$timestamp] Wrote metrics ($($metricsText.Length) bytes)" -ForegroundColor Gray
        }
        catch {
            Write-Host "[RTK-Metrics] Error collecting metrics: $_" -ForegroundColor Red
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
elseif ($Mode -eq "http") {
    Write-Host "[RTK-Metrics] Serving on http://localhost:$Port/metrics" -ForegroundColor Cyan
    Write-Host "[RTK-Metrics] Press Ctrl+C to stop" -ForegroundColor Yellow
    Write-Host ""

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response

            if ($request.Url.AbsolutePath -eq "/metrics") {
                $metricsText = Get-RtkMetrics
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($metricsText)
                $response.ContentType = "text/plain; charset=utf-8"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
                Write-Host "[RTK-Metrics] $(Get-Date -Format 'HH:mm:ss') GET /metrics (200)" -ForegroundColor Gray
            }
            elseif ($request.Url.AbsolutePath -eq "/health") {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("ok")
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            else {
                $response.StatusCode = 404
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("Not Found. Try /metrics")
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            $response.Close()
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
}

