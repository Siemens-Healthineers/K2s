# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Teams Alerting Demo - Documentation

## Overview

This demo shows a complete **Prometheus → Microsoft Teams** alerting pipeline running on K2s.
When a Kubernetes deployment goes down, an alert fires in Prometheus, gets routed through Alertmanager,
and appears as an **Adaptive Card** in a Microsoft Teams channel within ~30-40 seconds.

---

## Architecture & Flow

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐     ┌──────────────┐     ┌───────────┐
│  nginx-demo │────▶│  Prometheus  │────▶│ Alertmanager  │────▶│ Alert Relay  │────▶│  MS Teams │
│  (scaled=0) │     │  (monitors)  │     │  (routes)     │     │  (formats)   │     │ (channel) │
└─────────────┘     └──────────────┘     └───────────────┘     └──────────────┘     └───────────┘
                                                                        │
                                                                        ▼
                                                                ┌──────────────┐
                                                                │Power Automate│
                                                                │  (webhook)   │
                                                                └──────────────┘
```

### Step-by-Step Flow

| # | Component | What Happens |
|---|-----------|-------------|
| 1 | **nginx-demo** (Deployment) | User scales replicas to 0 → pod terminates |
| 2 | **kube-state-metrics** | Exposes metric `kube_deployment_status_replicas_available{deployment="nginx-demo"} = 0` |
| 3 | **Prometheus** | Evaluates PrometheusRule every 30s, detects `== 0`, starts `for: 1s` timer |
| 4 | **Prometheus** | After 1s still firing → sends alert to Alertmanager |
| 5 | **Alertmanager** | Matches `severity: demo` → routes to `teams-k2s-alerts` receiver |
| 6 | **Alertmanager** | Waits `group_wait: 10s`, then sends webhook POST to Alert Relay |
| 7 | **Alert Relay** (Python pod) | Receives Alertmanager webhook JSON, builds an Adaptive Card |
| 8 | **Alert Relay** | POSTs Adaptive Card JSON to the Power Automate webhook URL |
| 9 | **Power Automate** | Receives card, runs flow "Post card in a chat or channel" |
| 10 | **Microsoft Teams** | Displays Adaptive Card in channel "K2s-Alerts" |

**Total time from scale-to-0 to Teams notification: ~30-40 seconds**

---

## Components Added

### 1. Alert Relay (`alert-relay` pod)

**File:** `teams-forwarder.yaml`

A lightweight Python HTTP server (using `python:3.11-alpine` image) that:
- Listens on port **9095** for Alertmanager webhook POSTs
- Parses the Alertmanager JSON payload (contains alert name, labels, annotations, status)
- Builds a **Microsoft Adaptive Card** with:
  - Alert title with firing/resolved icon
  - Summary annotation
  - Namespace and severity facts
  - Description text
- POSTs the Adaptive Card JSON to the Power Automate webhook URL
- Power Automate's "Post card in a chat or channel" action requires this exact format

**Why not use prometheus-msteams?**
The `prometheus-msteams` project sends `Content-Type: application/octet-stream` and uses the legacy MessageCard format, which is incompatible with Power Automate workflow webhooks. Our relay sends proper `application/json` with Adaptive Card format.

### 2. Alertmanager Config (`alertmanager-config.yaml`)

**File:** `alertmanager-config.yaml`

Patches the secret `alertmanager-kube-prometheus-stack-alertmanager` (the actual config used by kube-prometheus-stack) to add:
- A route matching `severity: demo` → receiver `teams-k2s-alerts`
- The `teams-k2s-alerts` receiver with webhook pointing to `http://alert-relay.monitoring.svc:9095/`
- `send_resolved: true` so Teams also gets resolution notifications

**Key:** The secret name must be `alertmanager-kube-prometheus-stack-alertmanager` — this is what the Prometheus Operator mounts into the Alertmanager pod. Custom-named secrets are ignored.

### 3. PrometheusRule (`scenario1-prometheus-rule.yaml`)

**File:** `scenario1-prometheus-rule.yaml`

Defines the alert rule:
- **Name:** `NginxDemoPodUnavailable`
- **Expression:** `kube_deployment_status_replicas_available{namespace="demo-alerts", deployment="nginx-demo"} == 0`
- **For:** `1s` (fires almost immediately for demo purposes; production would use 30s-5m)
- **Labels:** `severity: demo` (matches the Alertmanager route), `team: k2s`
- **Must have:** `release: kube-prometheus-stack` label — Prometheus Operator's ruleSelector requires this

### 4. Demo Application (`scenario1-nginx-demo.yaml`)

**File:** `scenario1-nginx-demo.yaml`

- Creates namespace `demo-alerts`
- Deploys `nginx:1.25-alpine` with 1 replica
- Minimal resources (25m CPU, 32Mi memory)
- Has readiness probe on port 80

### 5. Power Automate Flow (external)

**Not in repo** — configured in https://make.powerautomate.com

- **Trigger:** "When a HTTP request is received" (generates the webhook URL)
- **Action:** "Post card in a chat or channel" — posts the incoming Adaptive Card JSON to Teams
- **Team/Channel:** K2s-Alerts

---

## Demo Commands

### One-Time Setup (before first demo)

```powershell
cd C:\ws\K2s\docs\dev-guide\demos\teams-alerting-demo
.\demo.ps1 setup
```

This deploys all 4 components and configures Alertmanager. Takes ~30 seconds.

### Trigger Alert (during demo)

```powershell
.\demo.ps1 fire
```

Scales `nginx-demo` to 0 replicas. Alert appears in Teams within **~30-40 seconds**.

### Resolve Alert (during demo)

```powershell
.\demo.ps1 resolve
```

Scales `nginx-demo` back to 1. Resolution card appears in Teams within ~60 seconds.

### Check Status

```powershell
.\demo.ps1 status
```

Shows: relay pod status, demo app status, PrometheusRule, Alertmanager config, and relay logs.

### Cleanup (after demo)

```powershell
.\demo.ps1 cleanup
```

Removes all demo resources (namespace, rule, relay deployment).

---

## Demo Script (What to Say)

### Introduction (~1 min)

> "Let me show you how K2s handles alerting. We have Prometheus monitoring our cluster,
> and we've configured it to send alerts to Microsoft Teams when something goes wrong."

> "Here's the pipeline: Prometheus detects a problem → Alertmanager routes it →
> our Alert Relay formats it as an Adaptive Card → Power Automate posts it to Teams."

### Show the Setup (~30 sec)

> "We have a simple nginx deployment running in the cluster. Prometheus has a rule
> that fires when this deployment has zero available replicas."

Show Prometheus UI at http://localhost:9090 → Alerts tab → show `NginxDemoPodUnavailable` is inactive.

### Fire the Alert (~30 sec + wait)

> "Now I'll simulate a failure by scaling the deployment to zero."

```powershell
.\demo.ps1 fire
```

> "The alert pipeline takes about 30 seconds — Prometheus needs to detect the change
> and Alertmanager batches notifications for efficiency."

Switch to Teams and wait for the card to appear.

### Show the Alert in Teams

> "There it is — we get an Adaptive Card with the alert name, namespace, severity,
> and description. This is fully automated, no manual intervention needed."

### Resolve

> "Now let's fix it:"

```powershell
.\demo.ps1 resolve
```

> "And we'll get a resolution notification in Teams confirming the issue is fixed."

---

## Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| Alert not firing in Prometheus | `kubectl get prometheusrules -n monitoring` | Ensure label `release: kube-prometheus-stack` exists |
| Alert firing but not in Alertmanager | Port-forward 9093, check `/api/v2/alerts` | Restart Alertmanager: `kubectl delete pod -n monitoring -l app.kubernetes.io/name=alertmanager` |
| Relay not receiving webhooks | `kubectl logs -l app=alert-relay -n monitoring` | Check Alertmanager config has `url: http://alert-relay.monitoring.svc:9095/` |
| Relay forwarded (HTTP 202) but no Teams | Check Power Automate run history | Flow action needs "Post card in a chat or channel" with Adaptive Card body |
| Power Automate returns 400 | Check relay logs for error | Ensure relay sends `"type": "AdaptiveCard"` at top level |

### Useful Commands

```powershell
# Port-forward Prometheus
Start-Job { kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 }

# Check Alertmanager config
$s = kubectl get secret alertmanager-kube-prometheus-stack-alertmanager -n monitoring -o jsonpath='{.data.alertmanager\.yaml}'
[System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))

# Check relay logs
kubectl logs -l app=alert-relay -n monitoring

# Check alert status in Alertmanager API
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# Then: http://localhost:9093/#/alerts
```

---

## File Structure

```
docs/dev-guide/demos/teams-alerting-demo/
├── demo.ps1                        # Main demo script (setup/fire/resolve/cleanup/status)
├── teams-forwarder.yaml            # Alert Relay deployment (ConfigMap + Deployment + Service)
├── alertmanager-config.yaml        # Alertmanager routing config (patches correct secret)
├── scenario1-nginx-demo.yaml       # Demo app (Namespace + Deployment + Service)
├── scenario1-prometheus-rule.yaml  # PrometheusRule (NginxDemoPodUnavailable)
├── scenario2-prometheus-rule.yaml  # Alternative scenario (replica count)
├── scenario3-test-alert.yaml       # Instant test alert (always-firing vector(1))
└── README.md                       # This document
```

---

## Prerequisites

- K2s installed with **monitoring addon** enabled (`k2s addons enable monitoring`)
- Power Automate flow configured with:
  - Trigger: "When a HTTP request is received"
  - Action: "Post card in a chat or channel" (Teams) using `triggerBody()` as the card content
- Network access from cluster to `*.powerplatform.com:443`

---

## What We Added on Top of kube-prometheus-stack

The **monitoring addon** (`k2s addons enable monitoring`) installs `kube-prometheus-stack` which provides:
- Prometheus (metrics collection & alerting engine)
- Alertmanager (alert routing, grouping, silencing)
- Grafana (dashboards)
- kube-state-metrics (Kubernetes object metrics)
- node-exporter (host-level metrics)

**None of these were modified.** We added the following components to enable the Teams integration:

| What We Added | Type | Namespace | Purpose |
|---------------|------|-----------|---------|
| `alert-relay` Deployment | Pod (python:3.11-alpine) | monitoring | Converts Alertmanager webhook format → Adaptive Card JSON for Power Automate |
| `alert-relay` Service | ClusterIP :9095 | monitoring | Exposes the relay pod to Alertmanager within the cluster |
| `alert-relay-script` ConfigMap | ConfigMap | monitoring | Contains the Python relay script (mounted into the pod) |
| `alertmanager-kube-prometheus-stack-alertmanager` Secret (patched) | Secret | monitoring | Added `teams-k2s-alerts` route + receiver to existing Alertmanager config |
| `nginx-demo-alerts` PrometheusRule | CRD | monitoring | Defines the `NginxDemoPodUnavailable` alert rule |
| `nginx-demo` Deployment + Service | Pod (nginx:1.25-alpine) | demo-alerts | Demo target application that we scale to 0 to trigger alerts |
| `demo-alerts` Namespace | Namespace | — | Isolated namespace for the demo app |
| Power Automate Flow (external) | Cloud service | — | Receives Adaptive Card webhook, posts to Teams channel |

### Why Each Component is Needed

**Alert Relay** — Alertmanager can send webhooks natively, but Power Automate's "Post card in a chat or channel" action requires a **valid Adaptive Card JSON** as the request body. Alertmanager sends its own JSON format (with `alerts[]`, `groupLabels`, etc.). The relay bridges this gap by transforming Alertmanager's format into an Adaptive Card.

**Alertmanager Config Patch** — kube-prometheus-stack's Alertmanager uses a specific secret (`alertmanager-kube-prometheus-stack-alertmanager`) for its config. We patch it to add a routing rule: any alert with `severity: demo` gets sent to our relay webhook. Without this, alerts go to the `default` receiver (which does nothing).

**PrometheusRule** — Tells Prometheus what condition to alert on. Must have label `release: kube-prometheus-stack` to be picked up by the Prometheus Operator. Without this, Prometheus doesn't know to watch our demo deployment.

**Demo App** — A simple nginx pod that we can kill (scale to 0) and revive (scale to 1) to trigger/resolve alerts on demand.

**Power Automate** — Microsoft's cloud automation platform. It provides the webhook URL and handles the "last mile" delivery from our cluster to a Teams channel. This is needed because Teams doesn't expose a direct incoming webhook API anymore (legacy Office 365 connectors were retired).

### What Stays After Cleanup

After `.\demo.ps1 cleanup`:
- ❌ Removed: alert-relay, nginx-demo, demo-alerts namespace, PrometheusRule
- ⚠️ Remains: Alertmanager config patch (teams route stays in the secret — harmless, just routes to a non-existent service)
- ✅ Unchanged: All kube-prometheus-stack components (Prometheus, Grafana, etc.)

---

## Alternative Approaches to Achieve Teams Alerting

There are multiple ways to get Prometheus alerts into Microsoft Teams. Here's a comparison of the options:

### Option A: Alert Relay + Power Automate (What We Use) ✅

```
Alertmanager → webhook → Alert Relay pod → Power Automate → Teams
```

| Pros | Cons |
|------|------|
| Full control over card formatting | Requires Power Automate license/flow |
| Works with new Teams Workflow webhooks | Extra pod in cluster |
| Adaptive Cards look professional | Depends on external cloud service |
| Supports firing + resolved notifications | |

### Option B: Alertmanager Native `msteams_configs` (Alertmanager v0.27+)

```
Alertmanager → msteams_configs → Teams Workflow webhook directly
```

| Pros | Cons |
|------|------|
| No extra pod needed | Only works with Teams Workflow webhook URLs (not Power Automate HTTP triggers) |
| Built into Alertmanager | Limited card customization |
| Simplest setup | Requires Alertmanager 0.27+ |

**Config example:**
```yaml
receivers:
  - name: teams
    msteams_configs:
      - webhook_url: "https://your-org.webhook.office.com/..."
```

### Option C: prometheus-msteams Forwarder (Legacy)

```
Alertmanager → webhook → prometheus-msteams pod → Teams connector
```

| Pros | Cons |
|------|------|
| Well-known OSS project | Uses deprecated Office 365 connectors (retired by Microsoft) |
| Pre-built Docker image | Sends `Content-Type: application/octet-stream` — breaks Power Automate |
| Template support | MessageCard format is legacy, not Adaptive Card |

### Option D: Grafana Alerting → Teams

```
Prometheus → Grafana evaluates alerts → Grafana contact point → Teams webhook
```

| Pros | Cons |
|------|------|
| UI-based alert rule creation | Bypasses Alertmanager (loses grouping/inhibition) |
| Built-in Teams contact point | Alert rules live in Grafana, not as PrometheusRules in Git |
| No extra components | Dual alerting path (Prometheus + Grafana) can be confusing |

### Option E: Custom Webhook + Azure Function / Logic App

```
Alertmanager → webhook → Azure Function → Teams
```

| Pros | Cons |
|------|------|
| Serverless (no pod) | Requires Azure subscription |
| Can do complex transformations | More infrastructure outside cluster |
| Auto-scales | Latency from cold starts |

### Option F: Email-based (Alertmanager → SMTP → Teams Channel Email)

```
Alertmanager → email_configs → Teams channel email address
```

| Pros | Cons |
|------|------|
| No extra components | Slow (email delivery can take minutes) |
| Built into Alertmanager | Plain text, no rich formatting |
| Works offline with local SMTP | Looks unprofessional in Teams |
| | Requires SMTP server accessible from cluster |

---

### Why We Chose Option A

1. **Power Automate is already available** in our Microsoft 365 tenant — no extra cost
2. **Adaptive Cards** provide rich, professional-looking notifications with structured data
3. **Full control** over what appears in the card (we format it ourselves in the relay)
4. **Works with `send_resolved: true`** — Teams gets both firing and resolution notifications
5. **No dependency on deprecated APIs** — Office 365 connectors were retired, Workflow webhooks require Adaptive Card format anyway
6. **Portable pattern** — the relay can be pointed at any webhook (Slack, Discord, etc.) by changing the URL and payload format
