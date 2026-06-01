<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Production Hardening Roadmap — AI Assistant Addon

**Date:** May 30, 2026
**Scope:** Analysis of validated platform. No architecture changes proposed.
**Baseline:** Phase 2 acceptance-tested (all workflows passing, Ollama provider, qwen2.5:7b).

---

## Priority Legend

- CRITICAL — Service outage or data loss likely without remediation
- HIGH — Significant operational risk; should be addressed before production GA
- MEDIUM — Reduces reliability or supportability; schedule within next sprint
- LOW — Improvement opportunity; schedule at convenience

---

## 1. Operational Risks

### 1.1 Single-replica a2a-proxy is a single point of failure [HIGH]

- **Impact:** If the a2a-proxy pod is evicted, OOM-killed, or node-drained, ALL AI workflows (both deterministic and conversational) are unavailable until rescheduled.
- **Likelihood:** Medium. Pod has tight memory limits (64Mi) and is on a single control-plane node.
- **Recommendation:** Increase replica count to 2 with pod anti-affinity. The proxy is stateless and safe to scale. Add a PodDisruptionBudget (minAvailable: 1).

### 1.2 Single-replica mcp-preprocessor is a single point of failure [HIGH]

- **Impact:** Same as 1.1 — shortcuts and conversational tool calls both route through mcp-preprocessor.
- **Likelihood:** Medium.
- **Recommendation:** Increase to 2 replicas with PDB. Stateless — safe to scale.

### 1.3 Ollama cold-start after model eviction [MEDIUM]

- **Impact:** After Ollama pod restart or keep_alive expiry, first inference request takes 10-30 seconds to reload the 4.7GB model into memory.
- **Likelihood:** Medium. The OLLAMA_KEEP_ALIVE is set to 24h in the manifest, but after pod restart the model must be reloaded from disk.
- **Recommendation:** Add a startup probe with generous timeout (120s). Document expected cold-start latency. Consider a post-start hook that sends a warm-up request.

### 1.4 Hardcoded Ollama IP address (172.19.1.1) [MEDIUM]

- **Impact:** If the K2s bridge interface IP changes (custom config, Linux provider, or multi-node expansion), Ollama becomes unreachable from a2a-proxy and the keep_alive function.
- **Likelihood:** Low in standard K2s, Medium on Linux provider.
- **Recommendation:** Extract the Ollama host IP into a configurable value (ConfigMap or addon manifest flag). Currently hardcoded in: a2a-proxy ConfigMap, ollama-agent.yaml ModelConfig, ai-assistant.module.psm1 Set-OllamaKeepAlive.

### 1.5 No graceful shutdown handling for conversational requests [LOW]

- **Impact:** An in-flight LLM inference (7-18s) may be terminated mid-stream during pod rollout.
- **Likelihood:** Low (updates are infrequent).
- **Recommendation:** Set terminationGracePeriodSeconds to 120 on a2a-proxy deployment. The Go proxy already uses request context cancellation.

---

## 2. Reliability Gaps

### 2.1 PostgreSQL has no backup strategy [CRITICAL]

- **Impact:** kagent-postgresql stores session history, agent metadata, and task state. On PVC loss or corruption, all conversation history is lost permanently.
- **Likelihood:** Low for data corruption, Medium for accidental PVC deletion during addon disable/re-enable.
- **Recommendation:** Add periodic pg_dump to a hostPath or secondary PV. Document that `--keep-model-data` does NOT preserve PostgreSQL data. Consider a CronJob-based backup (daily pg_dump to /data/kagent-backup/).

### 2.2 PostgreSQL PVC uses local-path-provisioner with no redundancy [HIGH]

- **Impact:** Data lives on a single node's filesystem. Node failure = data loss.
- **Likelihood:** Low (control-plane node is the only Linux node in standard K2s).
- **Recommendation:** Document the limitation. For users with critical data, recommend external PostgreSQL or scheduled backups. In the single-node K2s context this is acceptable with documented RTO/RPO.

### 2.3 No health check integration in a2a-proxy for upstream (kagent-controller) [MEDIUM]

- **Impact:** If kagent-controller is down, conversational requests timeout after 600s instead of failing fast.
- **Likelihood:** Low (controller has liveness probe, auto-restarts).
- **Recommendation:** Add circuit breaker or upstream health check in a2a-proxy that returns a fast 503 with informative message when kagent-controller is unreachable.

### 2.4 mcp-preprocessor startup race condition [LOW]

- **Impact:** mcp-preprocessor retries DNS for ~30s until k2s-tools pod is ready. During this window, shortcut requests fail.
- **Likelihood:** Only during addon enable/update.
- **Recommendation:** Add init container or startup probe that waits for k2s-tools service. Low priority as the retry logic already handles this.

---

## 3. Security Gaps

### 3.1 No authentication on the A2A ingress endpoint [HIGH]

- **Impact:** Any user or process with network access to the ingress IP can invoke AI queries, enumerate cluster resources, and consume LLM compute. Read-only tools expose pod names, IPs, events, logs, and configmaps.
- **Likelihood:** High in shared networks. K2s is typically single-tenant, but ingress IP is reachable from the local network.
- **Recommendation:** Add basic authentication (nginx auth annotations) or integrate with the existing K2s auth mechanism. At minimum, add IP allowlist via nginx.ingress.kubernetes.io/whitelist-source-range.

### 3.2 No rate limiting on API endpoints [HIGH]

- **Impact:** A tight loop of conversational queries can exhaust Ollama CPU/memory (8Gi limit), causing OOM and pod restart. A flood of shortcut queries generates heavy kubectl load.
- **Likelihood:** Medium (accidental tight loop in UI, or if ingress is exposed).
- **Recommendation:** Add nginx rate-limiting annotations (limit-rps: 5) on kagent-controller-ingress. Add in-process rate limiting in a2a-proxy (token bucket, 10 req/s).

### 3.3 PostgreSQL password is a static base64 value in committed YAML [MEDIUM]

- **Impact:** The password "kagent" (base64: a2FnZW50) is checked into the repository. Anyone with repo access knows the DB credentials.
- **Likelihood:** Low exploitation risk (PostgreSQL is ClusterIP-only, not exposed), but fails security audit.
- **Recommendation:** Generate a random password during addon enable (kubectl create secret --from-literal with random value). Update kagent.yaml to reference the existing secret rather than declare it.

### 3.4 Ollama container runs as root (runAsNonRoot: false) [MEDIUM]

- **Impact:** Container escape from Ollama would grant root on the node.
- **Likelihood:** Low (Ollama is a well-maintained project, seccompProfile is set).
- **Recommendation:** Investigate running Ollama as non-root (upstream supports it with correct volume permissions). At minimum document the risk and the compensating controls (seccomp, no hostPath except /data/ollama).

### 3.5 k2s-tools RBAC grants read access to configmaps cluster-wide [LOW]

- **Impact:** AI agent can read all configmaps in all namespaces, which may contain sensitive configuration data.
- **Likelihood:** Low (configmaps rarely contain secrets; Secrets resource is correctly excluded).
- **Recommendation:** Consider excluding configmaps or restricting to specific namespaces. Document that the AI agent has cluster-wide read access to configmaps.

### 3.6 No NetworkPolicy isolating kagent namespace [LOW]

- **Impact:** Any pod in the cluster can reach kagent-controller, PostgreSQL, and internal services.
- **Likelihood:** Low (standard K2s has limited workloads).
- **Recommendation:** Add NetworkPolicy allowing ingress only from: ingress-nginx namespace (for external), within kagent namespace (inter-component), and ai-assistant namespace (Ollama).

---

## 4. Upgrade Risks

### 4.1 No version pinning on Kagent framework images [HIGH]

- **Impact:** Images are pinned to 0.9.0 (good), but a2a-proxy and mcp-preprocessor use `latest` tag. After rebuild, old cached images may be used, or conversely, a rebuild may introduce breaking changes.
- **Likelihood:** Medium (images are locally built with imagePullPolicy: Never, so "latest" is stable per-build, but confusing for troubleshooting).
- **Recommendation:** Tag local images with a version derived from git SHA or addon version. E.g., `shsk2s.azurecr.io/a2a-proxy:v4.2-$(git rev-parse --short HEAD)`. Update manifests accordingly during build.

### 4.2 Update.ps1 does not re-build proxy images [MEDIUM]

- **Impact:** After a code change to a2a-proxy or mcp-preprocessor, `k2s addons update ai-assistant` re-applies manifests but doesn't rebuild the container images. Users must manually disable+re-enable.
- **Likelihood:** Medium (developers will hit this during iteration).
- **Recommendation:** Add image rebuild step to Update.ps1 (call Build-LocalProxyImages), or add a --rebuild flag.

### 4.3 CRD upgrade is server-side apply but no migration path [MEDIUM]

- **Impact:** Kagent CRD version changes (v1alpha1 → v1alpha2 already exists) could make existing Agent CRs incompatible.
- **Likelihood:** Low now (versions are stable), Medium at next Kagent upgrade.
- **Recommendation:** Add CRD version check before update. If schema breaking change detected, delete old CRs before re-applying. Document the upgrade path in README.

### 4.4 No rollback mechanism [LOW]

- **Impact:** If an update breaks the system, the only recovery is full disable+re-enable (losing PostgreSQL data).
- **Likelihood:** Low.
- **Recommendation:** Document manual rollback steps. Consider storing previous manifest set for quick revert.

---

## 5. Backup/Recovery Gaps

### 5.1 No documented disaster recovery procedure [HIGH]

- **Impact:** Team has no playbook for: Ollama model corruption, PostgreSQL data loss, control-plane node failure, or ingress misconfiguration.
- **Likelihood:** N/A (process gap).
- **Recommendation:** Create runbook covering: (1) Full re-enable procedure, (2) PostgreSQL restore from backup, (3) Ollama model re-pull, (4) Ingress troubleshooting. Store in docs/op-manual/ or addon README.

### 5.2 Ollama model data not backed up [MEDIUM]

- **Impact:** If /data/ollama is corrupted or node disk fails, model must be re-downloaded (4.7GB, requires network or offline package).
- **Likelihood:** Low.
- **Recommendation:** Document that models are recoverable via `ollama pull` if network is available, or from offline package. Not a backup priority unless air-gapped with no package access.

### 5.3 `--keep-model-data` flag is misleading [LOW]

- **Impact:** Users may think `--keep-model-data` preserves ALL state. It only preserves the Ollama PVC, not PostgreSQL data, agent history, or configuration.
- **Likelihood:** Low.
- **Recommendation:** Clarify in help text and documentation what is and is not preserved.

---

## 6. Documentation Gaps

### 6.1 No troubleshooting guide [HIGH]

- **Impact:** Support engineers and users have no reference for common failure modes.
- **Likelihood:** N/A (process gap).
- **Recommendation:** Document: Ollama not responding, mcp-preprocessor DNS retries, kagent-controller CrashLoopBackOff, ingress 404/502, conversational timeout, model not loaded.

### 6.2 No capacity planning documentation [MEDIUM]

- **Impact:** Users don't know memory/CPU requirements for different models or workload levels.
- **Likelihood:** N/A (process gap).
- **Recommendation:** Document: qwen2.5:7b requires ~6GB RAM under load, Ollama deployment limits should match model size + 2GB overhead, control-plane node minimum 16GB RAM for Ollama provider.

### 6.3 No architecture decision records (ADRs) [LOW]

- **Impact:** Future maintainers won't understand why decisions were made (e.g., why a2a-proxy exists, why deterministic shortcuts bypass LLM, why Ollama uses host bridge IP).
- **Likelihood:** N/A.
- **Recommendation:** Add ADR folder under addons/ai-assistant/docs/ with key decisions documented.

### 6.4 README lacks operational commands section [LOW]

- **Impact:** Quick-reference is in ai-assistant-status.md but not in the user-facing README.
- **Likelihood:** N/A.
- **Recommendation:** Add operational commands section to README.md.

---

## 7. Monitoring Gaps

### 7.1 No alerting on component failure [HIGH]

- **Impact:** If kagent-controller, a2a-proxy, or Ollama fails, no one is notified. Users discover issues only when they try to use the UI.
- **Likelihood:** N/A (monitoring gap).
- **Recommendation:** If monitoring addon is enabled, add PrometheusRule alerts for: pod restarts > 3 in 5m, readiness probe failures, Ollama health check failures. Prometheus scrape annotations are already present on a2a-proxy and mcp-preprocessor.

### 7.2 No request latency metrics exposed [MEDIUM]

- **Impact:** Cannot identify performance degradation trends over time.
- **Likelihood:** N/A.
- **Recommendation:** a2a-proxy already exposes /metrics. Verify it includes: request_duration_seconds histogram (by shortcut vs conversational), upstream_latency_seconds, error_count. If not present, add them.

### 7.3 No Ollama model status monitoring [MEDIUM]

- **Impact:** If model is unloaded from memory, first request has 10-30s cold-start with no visibility.
- **Likelihood:** Medium (after keep_alive expiry).
- **Recommendation:** Add periodic model status check in a2a-proxy (already has OllamaMonitor). Expose metric: ollama_model_loaded (0 or 1). The status shortcut already checks this — consider a dedicated Prometheus metric.

### 7.4 No PostgreSQL metrics [LOW]

- **Impact:** Cannot detect disk space exhaustion, connection pool saturation, or slow queries.
- **Likelihood:** Low (light workload).
- **Recommendation:** Consider postgres_exporter sidecar if monitoring addon is present. Low priority for current scale.

---

## 8. Supportability Gaps

### 8.1 No diagnostic bundle collection command [HIGH]

- **Impact:** When users report issues, support must manually gather: pod logs, events, agent CRs, configmaps, ingress status, Ollama model list.
- **Likelihood:** N/A.
- **Recommendation:** Add `k2s addons diagnose ai-assistant` or a diagnostic script that collects all relevant state into a tarball. Pattern exists in other K2s components.

### 8.2 Log correlation across components is difficult [MEDIUM]

- **Impact:** A single user request touches: ingress → a2a-proxy → kagent-controller → k2s-assistant → k2s-tools → mcp-preprocessor. No request ID is propagated consistently across all hops.
- **Likelihood:** N/A.
- **Recommendation:** Propagate X-Request-Id header through all components. a2a-proxy already generates UUIDs — ensure they appear in kagent-controller and mcp-preprocessor logs.

### 8.3 No version identification in running components [LOW]

- **Impact:** Cannot determine which version of a2a-proxy or mcp-preprocessor is deployed without checking image digests.
- **Likelihood:** N/A.
- **Recommendation:** Embed build version (git SHA) in binaries. Log it at startup. Expose via /version endpoint.

---

## 9. Team Onboarding Gaps

### 9.1 No local development guide for a2a-proxy/mcp-preprocessor [MEDIUM]

- **Impact:** New developers cannot iterate quickly on the Go proxy components.
- **Likelihood:** N/A.
- **Recommendation:** Document: (1) How to build (`bgol`), (2) How to test locally (unit tests, mock MCP server), (3) How to deploy changes (`k2s addons update ai-assistant` after rebuild), (4) How to view logs.

### 9.2 No integration test beyond smoke test [MEDIUM]

- **Impact:** Regression detection relies on manual Phase 2-style acceptance tests.
- **Likelihood:** N/A.
- **Recommendation:** Promote Invoke-SmokeTest.ps1 to CI. Add Go integration tests for a2a-proxy using httptest and mock upstream.

### 9.3 No contribution guide for adding new shortcuts [LOW]

- **Impact:** Adding a new deterministic shortcut requires understanding the entire shortcutRouter pattern.
- **Likelihood:** N/A.
- **Recommendation:** Add CONTRIBUTING section to shortcuts.go or a separate doc explaining: pattern matching, handler signature, MCP tool call patterns.

---

## 10. Production Readiness Improvements

### 10.1 Add resource quotas for kagent namespace [MEDIUM]

- **Impact:** Runaway pod (e.g., Ollama or PostgreSQL) could consume all node resources.
- **Likelihood:** Low (limits are set on all containers).
- **Recommendation:** Add ResourceQuota on kagent namespace as defense-in-depth. Set namespace-level limits matching sum of all pod limits + 20% headroom.

### 10.2 Add pod topology spread constraints [LOW]

- **Impact:** All pods land on kubemaster. If kubemaster has resource pressure, all AI components degrade simultaneously.
- **Likelihood:** Low (kubemaster is the only Linux node in standard K2s).
- **Recommendation:** Future improvement when multi-node Linux support is added. Document the constraint.

### 10.3 Add startup probes to kagent-controller [LOW]

- **Impact:** kagent-controller has 2 restarts during initial enable (CRD initialization). Without startup probe, liveness probe may kill it during legitimate initialization.
- **Likelihood:** Low (restarts resolve naturally).
- **Recommendation:** Add startupProbe with failureThreshold: 10, periodSeconds: 5 (50s startup window).

---

## Prioritized Roadmap

### Phase 3A: Critical + High (1-2 weeks)

1. PostgreSQL backup CronJob (2.1)
2. Authentication on ingress (3.1)
3. Rate limiting (3.2)
4. Diagnostic bundle command (8.1)
5. Troubleshooting guide (6.1)
6. Disaster recovery runbook (5.1)
7. Replica scaling for a2a-proxy + mcp-preprocessor with PDB (1.1, 1.2)
8. Alerting rules (7.1)
9. Image versioning strategy (4.1)

### Phase 3B: Medium (2-4 weeks)

10. Configurable Ollama IP (1.4)
11. PostgreSQL password generation (3.3)
12. Ollama non-root investigation (3.4)
13. Circuit breaker in a2a-proxy (2.3)
14. Update.ps1 image rebuild (4.2)
15. Capacity planning docs (6.2)
16. Request latency metrics verification (7.2)
17. Ollama model status metric (7.3)
18. Log correlation via request ID (8.2)
19. Local dev guide (9.1)
20. Integration tests in CI (9.2)
21. Resource quotas (10.1)
22. CRD upgrade path documentation (4.3)

### Phase 3C: Low (opportunistic)

23. NetworkPolicy for kagent namespace (3.6)
24. ConfigMap read restriction (3.5)
25. Graceful shutdown (1.5)
26. mcp-preprocessor startup optimization (2.4)
27. Rollback documentation (4.4)
28. --keep-model-data documentation clarity (5.3)
29. ADRs (6.3)
30. README operational commands (6.4)
31. PostgreSQL metrics (7.4)
32. Version endpoint (8.3)
33. Shortcut contribution guide (9.3)
34. Startup probes on kagent-controller (10.3)
35. Pod topology spread (10.2)

---

## Summary

| Priority | Count | Key Theme |
|----------|-------|-----------|
| CRITICAL | 1 | PostgreSQL backup |
| HIGH | 9 | Auth, rate limiting, HA, monitoring, docs |
| MEDIUM | 14 | Security hardening, observability, developer experience |
| LOW | 11 | Polish, defense-in-depth, future-proofing |

**Overall assessment:** The platform is functionally complete and stable. The primary production gaps are operational (no backup, no auth, single replicas) rather than functional. Addressing Phase 3A items would bring the system to enterprise-grade production readiness.

