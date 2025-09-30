# Windows HostProcess Containers: Binding to a Network Compartment

## Overview

Running existing (often legacy or closed-source) native Windows applications in Kubernetes can be challenging when you need modern platform capabilities (service mesh, observability, scaling) but the binaries were never built for container-awareness or multi-instance coexistence. On Windows, **network compartments** provide a logical isolation boundary for network configuration (interfaces, routes, policies, DNS) similar in spirit to a network namespace on Linux, but they are not automatically created for HostProcess containers (which execute directly in the host context).

This pattern enables you to:

- Place an unmodified native Windows process into an isolated network compartment
- Assign the process a stable per-instance IP (via the anchor pod's compartment networking)
- Inject mesh sidecars / data-plane capabilities at the compartment boundary (via the anchor, if mesh supports Windows)
- Scale to multiple parallel instances—each with its own compartment/IP—without port conflicts
- Gradually migrate or encapsulate legacy services without rewriting them for container semantics

We achieve this by combining:

1. An ordinary Windows (non-HostProcess) "anchor" pod that the kubelet / CNI associates with a compartment.
2. A HostProcess container that runs a privileged launcher which switches into the anchor's compartment before starting the legacy (or new) executable.

The repository includes a demonstrative launcher (`cplauncher`) that locates an anchor pod by label, resolves the compartment ID, switches the thread's compartment (Win32 API), and then execs the target workload binary—yielding a running process that behaves as if it were inside the anchor pod's network context.

The end-to-end test `hostprocess_test.go` under `test/e2e/cluster/hostprocess` validates this pattern by deploying:

1. An anchor Windows pod (regular container) owning the target compartment.
2. A HostProcess deployment that runs `cplauncher` as `NT AUTHORITY\\SYSTEM` on the Windows node, which then spawns the workload binary (`albumswin.exe`) bound to the anchor's compartment.
3. A ClusterIP Service + Linux curl client deployment to exercise cross-OS reachability.

## Why This Pattern?
Windows HostProcess containers execute directly on the host and can start arbitrary processes with elevated permissions. However, binding those processes to a different compartment than the default host compartment requires explicit Win32 API calls (e.g. `SetCurrentThreadCompartmentId`) before listening sockets are opened. The pattern here externalizes the compartment selection logic to a launcher tool that:

- Discovers the target compartment by locating a labeled anchor pod.
- Extracts and validates required network context (e.g. IP addresses, annotations, labels).
- Sets the thread's network compartment.
- Starts the desired executable while streaming logs.
- Exits with a meaningful status for observability.

### Benefits Summary
| Category | Benefit | Detail |
|----------|---------|--------|
| Service Mesh Enablement | Mesh integration for native apps | Mesh sidecars or per-compartment proxies can operate on traffic without modifying the legacy binary. |
| Horizontal Scaling | Instance-per-compartment model | Each replica gets a dedicated IP (from separate compartments), avoiding port binding collisions. |
| Operational Isolation | Fault containment | Misconfiguration or route pollution stays within the compartment, reducing blast radius. |
| Zero/Low Downtime Upgrades | Rolling compartment bring-up | Bring up new anchor + HostProcess pair, cut over service, then retire old pair. |
| Security / Least Privilege | Constrained network view | Compartment-scoped policies act before traffic reaches the broader host stack. |
| Legacy Migration Path | No code changes | Run closed-source EXEs unchanged while still onboarding to Kubernetes primitives. |
| Observability | Structured logs & metrics layering | Launcher can inject env/config for exporters without modifying the binary. |
| Multi-Tenancy | Compartment segmentation | Distinct tenants or workloads get logical separation atop the same node. |
| Network Policy Semantics | Fine-grained egress/ingress shaping | Combine compartment with Windows ACL / HNS rules enforceable per anchor. |
| Resource Governance | Predictable networking | Avoids accidental shared listener collisions when multiple processes expect the same port. |
| Debuggability | Deterministic placement | Known mapping (anchor label -> compartment -> process) simplifies triage. |
| Compliance / Audit | Traceable bootstrap path | Launcher logs capture environment & compartment decisions for audits. |
| Progressive Modernization | Hybrid patterns | Can layer on sidecars (metrics, security scanners) incrementally. |

> NOTE: While HostProcess containers run with elevated host privileges, the network compartment switch confines *network presence* of the launched process to the intended virtual environment derived from the anchor.

## Components
| Component | Purpose |
|-----------|---------|
| Anchor Pod (`albums-compartment-anchor`) | Provides compartment context; simple pause-based Windows container labeled `app=cp-albums-win`. |
| HostProcess Deployment (`albums-win-hp-app-hostprocess`) | Runs the `cplauncher` executable in a HostProcess container and launches the workload binary. |
| Launcher (`cplauncher.exe`) | Performs label-based discovery and compartment switch, then executes target process. |
| Workload Binary (`albumswin.exe`) | Example HTTP service (built during tests) exposing diagnostics on port 8080. |
| ConfigMap (`hostprocess-launcher-env`) | Injects filesystem base paths for launcher and workload into the HostProcess container environment. |
| Linux Curl Deployment (`curl`) | Validates cross-platform reachability to the Windows workload (service + direct pod IP). |

## Deployment Flow
1. Namespace and ConfigMap are created.
2. Anchor pod starts and establishes the compartment.
3. HostProcess deployment starts the base image (HostProcess capable) and runs `cmd.exe /c %CPLAUNCHER_BASE%\cplauncher.exe ... %ALBUMS_WIN%`.
4. `cplauncher` finds the anchor pod (label selector `app=cp-albums-win`), determines the compartment, switches, and launches `albumswin.exe`.
5. The workload listens on port 8080; a Service exposes it on port 80.
6. Tests verify:
   - Deployment availability & pod readiness.
   - `cplauncher` logs (PID line, completion status, IP info).
   - Reachability via Service from host and from a Linux curl pod.
   - Direct pod IP reachability from the curl pod (bypassing the Service).

## Key YAML Snippet (HostProcess Deployment excerpt)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: albums-win-hp-app-hostprocess
spec:
  template:
    spec:
      securityContext:
        windowsOptions:
          hostProcess: true
          runAsUserName: "NT AUTHORITY\\SYSTEM"
      hostNetwork: true
      containers:
        - name: cplauncher
          image: mcr.microsoft.com/oss/kubernetes/windows-host-process-containers-base-image:v1.0.0
          env:
            - name: CPLAUNCHER_BASE
              valueFrom:
                configMapKeyRef:
                  name: hostprocess-launcher-env
                  key: CPLAUNCHER_BASE
            - name: ALBUMS_WIN
              valueFrom:
                configMapKeyRef:
                  name: hostprocess-launcher-env
                  key: ALBUMS_WIN
          command:
            - "cmd.exe"
            - "/c"
            - "%CPLAUNCHER_BASE%\\cplauncher.exe"
            - "-label"
            - "app=cp-albums-win"
            - "-namespace"
            - "k2s"
            - "--"
            - "%ALBUMS_WIN%"
          volumeMounts:
            - name: host-ws
              mountPath: C:/ws
      volumes:
        - name: host-ws
          hostPath:
            path: C:/ws
            type: Directory
```

## Launcher Execution Model
`cplauncher.exe` is invoked with:
```
-label app=cp-albums-win -namespace k2s -- <target-exe>
```
It performs:
1. Kubernetes API query (via `kubectl` access or in-process REST) for pods matching the label.
2. Selection (first ready pod) and extraction of compartment metadata.
3. Windows API calls to set the current thread's compartment.
4. Process creation for the target executable, proxying stdout/stderr.
5. Exit with child exit code (propagated for orchestration / liveness checks).

## Building the Workload Binary During Tests
The E2E test dynamically builds `albumswin.exe` from source under `test/e2e/cluster/hostprocess/albumswin/` to ensure reproducibility. The resulting path is stored in `TEST_ALBUMS_WIN` and injected through the ConfigMap as `ALBUMS_WIN`.

## Direct Pod Reachability
In addition to Service-based access, the test validates direct HTTP access to the pod IP on port 8080 from the Linux curl pod. This confirms:
- Cross-OS pod-to-pod networking
- Compartment binding does not isolate the application from expected cluster networking

Test logic pattern:
1. Resolve hostprocess pod name via label.
2. Read `.status.podIP`.
3. `kubectl exec` into curl pod: `curl -s -o /dev/null -w %{http_code} http://<podIP>:8080/` expecting `200`.

## Operational Considerations
| Aspect | Guidance |
|--------|----------|
| Privilege | HostProcess runs as `NT AUTHORITY\\SYSTEM`; restrict image & command surface. |
| Auditing | Capture `cplauncher` logs under central logging (`C:/var/log`) for forensic analysis. |
| Retry Logic | If compartment resolution fails, launcher should emit clear error and non-zero exit code. |
| Versioning | Keep launcher and workload binaries versioned; tests rebuild to ensure freshness. |
| Security | Limit RBAC of the HostProcess identity to only required read operations (pods list/get). |
| Compartment Hygiene | Clean up anchors on scale down | Ensure old anchors are deleted so compartments do not accumulate stale routes. |
| Mesh Compatibility | Verify mesh Windows support | Some meshes have partial parity; validate sidecar or proxy injection strategy early. |
| Logging Location | Centralize log sinks | Mount `C:/var/log` (already shown) or forward to external collectors. |
| Timeouts & Retries | Launcher should bound discovery | Add flags (e.g. `-timeout`) to fail fast when anchor is absent. |
| Path Injection | Avoid hard-coding | Use ConfigMaps / env (as done) to keep launcher & workload paths flexible. |
| Supply Chain | Sign launcher binary | Ensure provenance (code signing) since it runs as SYSTEM. |

## Troubleshooting
| Symptom | Possible Cause | Action |
|---------|----------------|--------|
| HostProcess pod CrashLoopBackOff | Launcher path incorrect | Verify ConfigMap values and volume mounts. |
| No matching anchor pod found | Label mismatch | Ensure `app=cp-albums-win` label on anchor pod. |
| HTTP 5xx from curl | Workload failed post-launch | Inspect `kubectl logs` of HostProcess pod. |
| Direct pod curl fails but Service works | Network policy / compartment quirks | Check HNS policies and compartment ID correctness. |

## Extending the Pattern
To adapt this model:
1. Create a new anchor pod with a unique label (e.g. `app=my-anchor`).
2. Deploy HostProcess launcher with `-label app=my-anchor` and optional timeouts.
3. Package your workload binary; inject its path via ConfigMap or image layer.
4. Add Service / NetworkPolicy as required.
5. Extend tests to assert readiness + reachability.
6. (Optional) Introduce a mesh-compatible anchor image containing a sidecar injector or pre-baked proxy.
7. Add health probes (readiness / liveness) that query the launched process through loopback inside the compartment.

## References
- Kubernetes Windows HostProcess Containers: https://kubernetes.io/docs/concepts/windows/intro/#hostprocess-containers
- Windows Network Compartments (Microsoft Docs): https://learn.microsoft.com/windows/win32/api/netioapi/nf-netioapi-setcurrentthreadcompartmentid

---
_Last updated: 2025-09-30_
