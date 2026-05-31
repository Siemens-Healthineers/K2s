# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
One-command Teams alerting demo. Triggers an alert and shows it in Microsoft Teams.

.DESCRIPTION
Usage:
  .\demo.ps1 setup     # One-time: deploys all infrastructure
  .\demo.ps1 fire      # Triggers alert - Teams notification in ~60s
  .\demo.ps1 resolve   # Resolves alert - Teams resolution in ~60s
  .\demo.ps1 status    # Show current state of demo components
  .\demo.ps1 cleanup   # Removes all demo resources

.EXAMPLE
  # Before your first demo (one-time):
  .\demo.ps1 setup

  # During demo meeting:
  .\demo.ps1 fire       # Wait ~60s, alert appears in Teams
  .\demo.ps1 resolve    # Wait ~60s, resolution appears in Teams

  # After demo:
  .\demo.ps1 cleanup
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'fire', 'resolve', 'cleanup', 'status')]
    [string]$Action = 'fire'
)

$ErrorActionPreference = 'Stop'
$demoDir = $PSScriptRoot

switch ($Action) {
    'setup' {
        Write-Host "`n=== Setting up Teams alerting demo ===" -ForegroundColor Cyan

        # Step 1: Deploy the alert relay (Alertmanager -> Power Automate)
        Write-Host "`n[1/5] Deploying alert relay..." -ForegroundColor White
        kubectl apply -f "$demoDir\teams-forwarder.yaml"

        # Step 2: Patch Alertmanager config to route 'severity: demo' to relay
        Write-Host "[2/5] Configuring Alertmanager routing..." -ForegroundColor White
        kubectl apply -f "$demoDir\alertmanager-config.yaml"

        # Step 3: Restart Alertmanager to pick up new config
        Write-Host "[3/5] Restarting Alertmanager..." -ForegroundColor White
        kubectl delete pod -n monitoring -l app.kubernetes.io/name=alertmanager --wait=false 2>$null
        Start-Sleep 5

        # Step 4: Deploy demo application
        Write-Host "[4/5] Deploying demo app (nginx)..." -ForegroundColor White
        kubectl apply -f "$demoDir\scenario1-nginx-demo.yaml"

        # Step 5: Deploy PrometheusRule
        Write-Host "[5/5] Deploying PrometheusRule..." -ForegroundColor White
        kubectl apply -f "$demoDir\scenario1-prometheus-rule.yaml"

        # Wait for pods
        Write-Host "`nWaiting for relay pod..." -ForegroundColor Yellow
        kubectl wait --for=condition=ready pod -l app=alert-relay -n monitoring --timeout=120s
        Write-Host "Waiting for demo app..." -ForegroundColor Yellow
        kubectl wait --for=condition=ready pod -l app=nginx-demo -n demo-alerts --timeout=60s

        Write-Host "`n[OK] Setup complete!" -ForegroundColor Green
        Write-Host "     Run '.\demo.ps1 fire' to trigger an alert." -ForegroundColor Green
        Write-Host "     Alert will appear in Teams channel 'K2s-Alerts' within ~60s." -ForegroundColor Green
    }

    'fire' {
        Write-Host "`n[ALERT] Scaling nginx-demo to 0 replicas..." -ForegroundColor Red
        kubectl scale deployment nginx-demo -n demo-alerts --replicas=0
        Write-Host ""
        Write-Host "  Alert pipeline: Prometheus -> Alertmanager -> Relay -> Power Automate -> Teams" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  [WAIT] Watch your Teams channel 'K2s-Alerts'!" -ForegroundColor Yellow
        Write-Host "         Alert fires after ~30s (for: 30s) + ~10s (group_wait) = ~40-60s" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Run '.\demo.ps1 resolve' when ready to fix it." -ForegroundColor Cyan
    }

    'resolve' {
        Write-Host "`n[RESOLVE] Scaling nginx-demo back to 1 replica..." -ForegroundColor Green
        kubectl scale deployment nginx-demo -n demo-alerts --replicas=1
        kubectl wait --for=condition=ready pod -l app=nginx-demo -n demo-alerts --timeout=60s
        Write-Host ""
        Write-Host "  [OK] Pod is back. Resolution notification in Teams within ~60s." -ForegroundColor Green
    }

    'status' {
        Write-Host "`n=== Demo Status ===" -ForegroundColor Cyan

        Write-Host "`n--- Alert Relay ---" -ForegroundColor White
        kubectl get pods -l app=alert-relay -n monitoring --no-headers 2>$null

        Write-Host "`n--- Demo App (namespace: demo-alerts) ---" -ForegroundColor White
        kubectl get pods -n demo-alerts --no-headers 2>$null
        kubectl get deployment nginx-demo -n demo-alerts --no-headers 2>$null

        Write-Host "`n--- PrometheusRules ---" -ForegroundColor White
        kubectl get prometheusrules nginx-demo-alerts -n monitoring --no-headers 2>$null

        Write-Host "`n--- Alertmanager Config (teams route) ---" -ForegroundColor White
        $secret = kubectl get secret alertmanager-kube-prometheus-stack-alertmanager -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' 2>$null
        if ($secret) {
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret))
            if ($decoded -match 'teams-k2s-alerts') {
                Write-Host "  [OK] Alertmanager has 'teams-k2s-alerts' receiver configured" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Alertmanager does NOT have teams route - run setup again" -ForegroundColor Yellow
            }
        }

        Write-Host "`n--- Relay Logs (last 5 lines) ---" -ForegroundColor White
        kubectl logs -l app=alert-relay -n monitoring --tail=5 2>$null
        Write-Host ""
    }

    'cleanup' {
        Write-Host "`n=== Cleaning up demo resources ===" -ForegroundColor Cyan
        kubectl delete namespace demo-alerts --wait=false --ignore-not-found
        kubectl delete prometheusrule nginx-demo-alerts -n monitoring --ignore-not-found
        kubectl delete deployment alert-relay -n monitoring --ignore-not-found
        kubectl delete service alert-relay -n monitoring --ignore-not-found
        kubectl delete configmap alert-relay-script -n monitoring --ignore-not-found
        # Also clean old forwarder resources if present
        kubectl delete deployment alertmanager-teams-forwarder -n monitoring --ignore-not-found
        kubectl delete service alertmanager-teams-forwarder -n monitoring --ignore-not-found
        kubectl delete configmap teams-forwarder-config -n monitoring --ignore-not-found
        kubectl delete secret alertmanager-teams-config -n monitoring --ignore-not-found
        Write-Host "`n[OK] Cleanup complete!" -ForegroundColor Green
        Write-Host "     Note: Alertmanager config was NOT reverted (teams route remains)." -ForegroundColor DarkGray
    }
}
