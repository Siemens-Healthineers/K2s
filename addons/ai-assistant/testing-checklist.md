<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon — Testing Checklist

Use this checklist when validating the `ai-assistant` addon.  
The addon deploys **Ollama** (local LLM runtime) + **HolmesGPT** (Kubernetes AI agent) + injects the **AI Assistant plugin** into the Headlamp dashboard.

> **How to use this file:**  
> Work top-to-bottom. Complete each numbered section before moving to the next.  
> Mark `[x]` when a check passes, add a note when it fails.

---

## One-time Setup (do this first, once per test session)

### Step 1 — Install K2s and enable dashboard

```console
k2s install -f
k2s addons enable dashboard --ingress nginx
```

Verify dashboard is up:

```console
k2s addons status dashboard
```

Expected output includes: `IsHeadlampRunning = True`

---

### Step 2 — Open Headlamp in your browser

```console
kubectl port-forward svc/headlamp -n dashboard 4466:4466
```

Open: `http://localhost:4466/dashboard/`

Generate a login token and paste it into the login screen:

```console
kubectl -n dashboard create token headlamp --duration 8h
```

Keep this browser tab open for the entire test session.

---

### Step 3 — Enable the AI Assistant addon

```console
k2s addons enable ai-assistant
```

This takes **5–15 minutes** on first run (model download). Watch progress:

```console
kubectl get pods -n ai-assistant -w
```

Wait until both pods show `Running`:

```
ollama-xxxx          1/1   Running
holmesgpt-holmes-xxxx  1/1   Running
```

---

### Step 4 — Configure the plugin in Headlamp

1. In Headlamp, go to **Settings → Plugins → AI Assistant**
2. Under **Provider**, select **Local Models**
3. Set **Base URL** to: `http://ollama.ai-assistant.svc.cluster.local:11434`
4. Set **Model** to: `llama3.2`
5. Click **Save**
6. Click the **AI icon** (robot icon) in the top-right app bar

The chat panel should open on the right side.

---

## Section 1 — Addon Installation Checks

After `k2s addons enable ai-assistant` completes, run these commands to verify the installation.

---

### 1.1 — Namespace and storage

```console
kubectl get ns ai-assistant
kubectl get pvc ollama-models -n ai-assistant
```

- [ ] Namespace `ai-assistant` exists
- [ ] PVC `ollama-models` is in `Bound` state with 20Gi

---

### 1.2 — Ollama is running and model is available

```console
kubectl wait --for=condition=Available deployment/ollama -n ai-assistant --timeout=300s
kubectl exec -n ai-assistant deployment/ollama -- ollama list
```

- [ ] `deployment/ollama` becomes Available within 5 minutes
- [ ] `ollama list` shows `llama3.2` in the output

---

### 1.3 — HolmesGPT is running

```console
kubectl wait --for=condition=Available deployment/holmesgpt-holmes -n ai-assistant --timeout=120s
kubectl logs -n ai-assistant deployment/holmesgpt-holmes --tail=20
```

- [ ] `deployment/holmesgpt-holmes` becomes Available
- [ ] Logs show the AG-UI server started (look for `Uvicorn running` or `Starting server`)

---

### 1.4 — Cross-namespace proxy is wired

```console
kubectl get endpoints holmesgpt-holmes -n default -o yaml
kubectl get svc holmesgpt-holmes -n ai-assistant -o jsonpath='{.spec.clusterIP}'
```

- [ ] Endpoints object exists in `default` namespace
- [ ] The IP shown in the Endpoints `subsets[].addresses[].ip` matches the ClusterIP from the second command

---

### 1.5 — Plugin is injected into Headlamp

```console
kubectl get deployment headlamp -n dashboard \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}'
```

- [ ] Output includes `ai-assistant-plugin`

```console
kubectl rollout status deployment headlamp -n dashboard --timeout=120s
```

- [ ] Headlamp rollout completes with no errors

---

### 1.6 — Status command shows all green

```console
k2s addons status ai-assistant
```

- [ ] `IsOllamaRunning      = True`
- [ ] `IsHolmesGptRunning   = True`
- [ ] `IsHolmesProxyWired   = True`
- [ ] `IsAiPluginInjected   = True`

---

## Section 2 — Headlamp UI Checks

Verify the plugin loaded correctly in the browser before running chat tests.

---

### 2.1 — AI icon is visible

- [ ] Reload Headlamp (`F5`)
- [ ] A robot/AI icon appears in the **top-right app bar**
- [ ] Hovering over it shows tooltip: `AI Assistant`

---

### 2.2 — Chat panel opens and closes

- [ ] Click the AI icon → chat panel slides in from the right
- [ ] Click the AI icon again → chat panel closes
- [ ] Panel can be resized by dragging its left edge (cursor changes to `↔`)

---

### 2.3 — Holmes indicator is Connected

- [ ] Open the chat panel
- [ ] Look for the **Holmes** status indicator (small dot or label near the top of the panel)
- [ ] It shows **Connected** (green)

If it shows **Disconnected**, check:
```console
kubectl get pods -n ai-assistant -l app=holmesgpt
kubectl get endpoints holmesgpt-holmes -n default
```

---

### 2.4 — Settings page is accessible

- [ ] Go to **Settings → Plugins → AI Assistant** (or click gear icon inside the chat panel)
- [ ] Page loads without errors
- [ ] Provider dropdown shows **Local Models** selected
- [ ] Base URL and Model fields show the values you configured in Setup Step 4

---

## Section 3 — Practical Chat Scenarios

> **Before each scenario:** The chat panel must be open and Holmes must show **Connected**.  
> Type the exact prompt shown, press Enter or click Send, and wait for the full response.

---

### Chat Scenario A — "How is the cluster doing?"

**Purpose:** Basic cluster health summary. The easiest possible first test.

**No setup needed.**

**Type this prompt:**
```
How is the cluster doing? Give me a health summary.
```

**What to check:**
- [ ] Response arrives within 60 seconds
- [ ] Response mentions node(s) — e.g. "1 node is Ready" or similar
- [ ] Response mentions running namespaces or workloads
- [ ] Holmes indicator stays **Connected** throughout

**Cross-check with kubectl:**
```console
kubectl get nodes
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

The AI answer should roughly reflect what these two commands show. It does not need to be exact — it should not invent namespaces or pods that do not exist.

---

### Chat Scenario B — "Why is my nginx pod failing?" (CrashLoopBackOff)

**Purpose:** Test Holmes diagnosis of a crashing pod. The most common real-world debugging scenario.

**Setup — create a pod that always crashes:**
```console
kubectl run nginx-broken --image=nginx:latest -n default -- /bin/sh -c "exit 1"
```

Wait ~30 seconds, then confirm it is crashing:
```console
kubectl get pod nginx-broken -n default
```

Expected status: `CrashLoopBackOff` or `Error`

**Type this prompt:**
```
Why is the pod nginx-broken in the default namespace failing?
```

**What to check:**
- [ ] Response arrives within 60 seconds
- [ ] Response mentions `CrashLoopBackOff`
- [ ] Response explains the container exits immediately (exit code 1)
- [ ] Response suggests checking logs with something like `kubectl logs nginx-broken --previous`
- [ ] Response does **not** suggest cloud-provider-specific fixes

**Cleanup:**
```console
kubectl delete pod nginx-broken -n default
```

---

### Chat Scenario C — "Pod is stuck in ImagePullBackOff"

**Purpose:** Test diagnosis of a bad image name — another very common real problem.

**Setup — create a pod with a made-up image:**
```console
kubectl run bad-image --image=doesnotexist-registry.io/fake:v99 -n default
```

Wait ~20 seconds, then confirm:
```console
kubectl get pod bad-image -n default
```

Expected status: `ErrImagePull` or `ImagePullBackOff`

**Type this prompt:**
```
The pod bad-image in the default namespace is not starting. What is wrong with it?
```

**What to check:**
- [ ] Response identifies `ImagePullBackOff` or `ErrImagePull`
- [ ] Response mentions the image name `doesnotexist-registry.io/fake:v99`
- [ ] Response suggests checking the image name/tag or registry access

**Cleanup:**
```console
kubectl delete pod bad-image -n default
```

---

### Chat Scenario D — "What pods need my attention?"

**Purpose:** Test scanning across all namespaces for multiple unhealthy workloads at once.

**Setup — create two different problem pods:**
```console
kubectl run crash-1 --image=busybox -n default -- /bin/sh -c "exit 1"
kubectl run pending-1 --image=nginx -n default \
  --overrides='{"spec":{"nodeSelector":{"nosuchnode":"true"}}}'
```

Wait ~30 seconds, then confirm both are unhealthy:
```console
kubectl get pods crash-1 pending-1 -n default
```

Expected: `crash-1` = `CrashLoopBackOff`, `pending-1` = `Pending`

**Type this prompt:**
```
What pods need my attention right now?
```

**What to check:**
- [ ] Response mentions `crash-1` with a crash-related reason
- [ ] Response mentions `pending-1` with a scheduling-related reason (no matching node)
- [ ] Response does **not** flag healthy system pods like `coredns` as problems
- [ ] Both issues are explained with different root causes

**Cleanup:**
```console
kubectl delete pod crash-1 pending-1 -n default
```

---

### Chat Scenario E — "Show me the logs of a failing pod"

**Purpose:** Test that the AI fetches and interprets real pod logs from the cluster.

**Setup — create a pod that prints an error and exits:**
```console
kubectl run log-test --image=busybox -n default --restart=Never -- \
  /bin/sh -c "echo 'ERROR: database connection refused'; sleep 2; exit 1"
```

Wait ~10 seconds:
```console
kubectl get pod log-test -n default
```

Expected status: `Error` or `Completed` (it ran and exited)

**Type this prompt:**
```
Show me the logs of the pod log-test in the default namespace and explain what went wrong.
```

**What to check:**
- [ ] Response includes the exact log line `ERROR: database connection refused`
- [ ] Response explains the pod exited due to the application error
- [ ] Response suggests a next step (e.g. check if a database service is reachable)

**Cleanup:**
```console
kubectl delete pod log-test -n default
```

---

### Chat Scenario F — "Generate a YAML for a nginx Deployment"

**Purpose:** Test YAML generation and the Apply button. No broken cluster state needed.

**No setup needed.**

**Type this prompt:**
```
Generate a Kubernetes YAML for a simple nginx Deployment with 2 replicas in the default namespace.
```

**What to check:**
- [ ] Response contains a YAML code block (syntax-highlighted, starts with `apiVersion:`)
- [ ] YAML contains `kind: Deployment`
- [ ] YAML contains `replicas: 2`
- [ ] YAML contains `image: nginx`
- [ ] An **Apply** button appears below the YAML block in the chat
- [ ] Clicking **Apply** opens an editor dialog with the YAML pre-filled
- [ ] Dialog title says `Apply Deployment` (not View or Delete)
- [ ] Clicking **Apply** in the dialog creates the deployment:
  ```console
  kubectl get deployment -n default
  ```

**Cleanup:**
```console
kubectl delete deployment nginx -n default
```
_(adjust the name if the AI used a different name like `nginx-deployment`)_

---

### Chat Scenario G — "How do I scale a deployment?"

**Purpose:** Test general Kubernetes how-to knowledge. No cluster setup needed.

**No setup needed.**

**Type this prompt:**
```
How do I scale the headlamp deployment in the dashboard namespace to 2 replicas?
```

**What to check:**
- [ ] Response provides the exact `kubectl scale` command:
  ```console
  kubectl scale deployment headlamp -n dashboard --replicas=2
  ```
  _(or equivalent `kubectl patch` form — both are correct)_
- [ ] Run the command and verify it works:
  ```console
  kubectl scale deployment headlamp -n dashboard --replicas=2
  kubectl get deployment headlamp -n dashboard
  ```
  Expected: `READY 2/2`
- [ ] Scale back when done:
  ```console
  kubectl scale deployment headlamp -n dashboard --replicas=1
  ```

---

### Chat Scenario H — "Pod is stuck in Pending (resource limits)"

**Purpose:** Test diagnosis of a pod that cannot be scheduled because it requests more resources than any node has.

**Setup — create a pod with impossible resource requests:**
```console
kubectl run resource-hog --image=nginx -n default \
  --overrides='{"spec":{"containers":[{"name":"resource-hog","image":"nginx","resources":{"requests":{"cpu":"100","memory":"500Gi"}}}]}}'
```

Confirm it is stuck:
```console
kubectl get pod resource-hog -n default
```

Expected status: `Pending`

**Type this prompt:**
```
The pod resource-hog in the default namespace is stuck in Pending state. Why?
```

**What to check:**
- [ ] Response identifies insufficient CPU or memory as the cause
- [ ] Response mentions the requested values are too high for the available nodes
- [ ] Response suggests lowering the resource requests

**Cleanup:**
```console
kubectl delete pod resource-hog -n default
```

---

### Chat Scenario I — "What is running in the ai-assistant namespace?"

**Purpose:** Test namespace-scoped resource discovery. Confirms the AI scopes queries correctly without confusion.

**No setup needed** — the ai-assistant namespace is already running.

**Type this prompt:**
```
What is running in the ai-assistant namespace?
```

**What to check:**
- [ ] Response lists the `ollama` deployment
- [ ] Response lists the `holmesgpt-holmes` deployment
- [ ] Response mentions the `ollama-models` PVC or storage
- [ ] Response does **not** confuse `ai-assistant` namespace with `dashboard` or `default`

**Cross-check:**
```console
kubectl get all -n ai-assistant
kubectl get pvc -n ai-assistant
```

---

### Chat Scenario J — Multi-turn conversation (context memory)

**Purpose:** Verify the chat remembers context within the same session.

**No setup needed.** Use the same open chat panel (do NOT click New Chat / Reset).

**Message 1 — ask about deployments:**
```
How many deployments are in the dashboard namespace?
```

Note the answer — it should say `1` (the `headlamp` deployment).

**Message 2 — follow up without repeating context:**
```
How many pods does that deployment have running?
```

**What to check:**
- [ ] Message 2 response correctly refers to the `headlamp` deployment from Message 1
- [ ] Response does **not** ask "which deployment?" — it uses session context
- [ ] Answer matches:
  ```console
  kubectl get pods -n dashboard -l app.kubernetes.io/name=headlamp
  ```

**Message 3 — test reset:**
- Click the **New Chat** or **Reset** button (broom/trash icon) in the chat panel
- Type: `What were we just talking about?`

**What to check:**
- [ ] After reset, the AI responds with no memory of the previous conversation
- [ ] Response does not reference `headlamp` or `dashboard` unprompted

---

## Section 4 — Disable and Cleanup Checks

Run these after the chat scenarios to verify clean teardown.

---

### 4.1 — Disable the addon

```console
k2s addons disable ai-assistant
```

After the command completes, verify each resource is gone:

```console
kubectl get ns ai-assistant
kubectl get clusterrole holmesgpt-reader
kubectl get clusterrolebinding holmesgpt-reader
kubectl get svc holmesgpt-holmes -n default
kubectl get endpoints holmesgpt-holmes -n default
```

- [ ] All five commands return `not found`

```console
kubectl get deployment headlamp -n dashboard \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}'
```

- [ ] Output is **empty** (ai-assistant-plugin is gone)

```console
kubectl rollout status deployment headlamp -n dashboard --timeout=120s
```

- [ ] Headlamp rollout completes — no crashloop

- [ ] Reload Headlamp in the browser — **AI icon is gone** from the app bar

---

### 4.2 — Disable with `--keep-model-data`

Re-enable first:
```console
k2s addons enable ai-assistant
```

Wait for it to be ready, then disable with flag:
```console
k2s addons disable ai-assistant --keep-model-data
```

Check:
```console
kubectl get pvc ollama-models -n ai-assistant
kubectl get ns ai-assistant
```

- [ ] PVC `ollama-models` still exists and is `Bound`
- [ ] Namespace `ai-assistant` still exists (needed to keep the PVC)
- [ ] All deployments, services, and RBAC are gone:
  ```console
  kubectl get deploy,svc -n ai-assistant
  kubectl get clusterrole holmesgpt-reader
  ```

Re-enable and check model is not re-downloaded:
```console
k2s addons enable ai-assistant
kubectl logs -n ai-assistant deployment/ollama --since=3m | Select-String -Pattern "pull"
```

- [ ] No `pull` lines in the logs — model was already on the PVC

---

## Section 5 — Additional Checks

These are quick spot-checks. Run them in any order after Section 1 passes.

---

### 5.1 — Double-enable returns a warning (not a crash)

```console
k2s addons enable ai-assistant
```
_(while it is already enabled)_

- [ ] Command returns a **warning** message: `already enabled, nothing to do`
- [ ] Exit code is non-zero (warning)
- [ ] No new resources are created

---

### 5.2 — Double-disable returns a warning (not a crash)

```console
k2s addons disable ai-assistant
k2s addons disable ai-assistant
```
_(second call while already disabled)_

- [ ] Second call returns a **warning** message: `already disabled, nothing to do`
- [ ] No error or exception

---

### 5.3 — Enable with a different model

```console
k2s addons enable ai-assistant --model phi3
```

- [ ] `ollama list` shows `phi3`:
  ```console
  kubectl exec -n ai-assistant deployment/ollama -- ollama list
  ```
- [ ] ConfigMap contains `phi3`:
  ```console
  kubectl get configmap holmesgpt-model-config -n ai-assistant -o jsonpath='{.data}'
  ```

Cleanup:
```console
k2s addons disable ai-assistant
```

---

### 5.4 — RBAC: HolmesGPT cannot write to the cluster

```console
kubectl get clusterrole holmesgpt-reader \
  -o jsonpath='{range .rules[*]}{.verbs}{"\n"}{end}'
```

- [ ] Output contains only `get`, `list`, `watch` — no `create`, `update`, `delete`, or `patch`

---

### 5.5 — Additional model survives Ollama pod restart

```console
kubectl exec -n ai-assistant deployment/ollama -- ollama pull tinyllama
kubectl exec -n ai-assistant deployment/ollama -- ollama list
kubectl rollout restart deployment/ollama -n ai-assistant
kubectl rollout status deployment/ollama -n ai-assistant --timeout=120s
kubectl exec -n ai-assistant deployment/ollama -- ollama list
```

- [ ] `tinyllama` appears in `ollama list` before the restart
- [ ] `tinyllama` still appears in `ollama list` after the restart (stored on PVC)

---

## Sign-off

| Role | Name | Date | Result |
|---|---|---|---|
| Developer | | | ☐ Pass / ☐ Fail |
| Reviewer  | | | ☐ Pass / ☐ Fail |

