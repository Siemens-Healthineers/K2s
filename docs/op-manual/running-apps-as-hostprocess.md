# Running Native Windows Applications with HostProcess + Network Compartments

## Overview

Running existing (often legacy or closed-source) native Windows applications in Kubernetes can be challenging when you need modern platform capabilities (service mesh, observability, scaling) but the binaries were never built for container-awareness or multi-instance coexistence. On Windows, **network compartments** provide a logical isolation boundary for network configuration (interfaces, routes, policies, DNS) similar in spirit to a network namespace on Linux, but they are not automatically created for HostProcess containers (which execute directly in the host context).

<div align="center">

![Overview](assets/compartments.png)
</div>

This pattern enables you to:

- Place an unmodified native Windows process into an isolated network compartment
- Assign the process a stable per-instance IP (via the anchor pod's compartment networking)
- Inject mesh sidecars / data-plane capabilities at the compartment boundary (via the anchor, if mesh supports Windows)
- Scale to multiple parallel instances—each with its own compartment/IP—without port conflicts
- Gradually migrate or encapsulate legacy services without rewriting them for container semantics

We achieve this by combining:

1. An ordinary Windows (non-HostProcess) "anchor" pod that the kubelet / CNI associates with a compartment.
2. A HostProcess container that runs a privileged launcher which switches into the anchor's compartment before starting the legacy (or new) executable.

This guide shows how to run an existing (possibly legacy / closed‑source) Windows application inside Kubernetes while giving it its **own isolated network context** (a Windows network compartment) and a stable IP address, *without* modifying the binary. The isolation is achieved by pairing:

1. An **anchor pod** (ordinary Windows container) which the Windows CNI stack places into a compartment and wires with an interface + IP.
2. A **HostProcess container** that launches the real application *after* switching its thread into the anchor's compartment using the helper launcher `cplauncher`.

This pattern preserves compatibility (run any EXE), improves multi‑instance scalability (no port collisions), and enables advanced platform add‑ons (service mesh, traffic capture, zero‑downtime rotation) around software that cannot be easily containerized in the traditional sense.

## Why This Pattern?
Windows HostProcess containers execute directly on the host and can start arbitrary processes with elevated permissions. However, binding those processes to a different compartment than the default host compartment requires explicit Win32 API calls (e.g. `SetCurrentThreadCompartmentId`) before listening sockets are opened. The pattern here externalizes the compartment selection logic to a launcher tool that:

- Discovers the target compartment by locating a labeled anchor pod.
- Extracts and validates required network context (e.g. IP addresses, annotations, labels).
- Sets the thread's network compartment.
- Starts the desired executable while streaming logs.
- Exits with a meaningful status for observability.

### Benefits
| Theme | Value | Detail |
|-------|-------|--------|
| Service Mesh | Sidecar / proxy enablement | Anchor pod can host or trigger mesh injection; your legacy EXE traffic is transparently managed. |
| Per‑Instance IP | No port conflicts | Each replica gets its own compartment + IP; multiple instances can all listen on the same port (e.g. 8080). |
| Gradual Modernization | No code changes needed | Keep shipping the old binary while layering on Kubernetes services, probes, policies. |
| Traffic Governance | Fine‑grained routing/shaping | Compartment boundaries + HNS policies restrict blast radius of misconfiguration. |
| Security & Isolation | Network surface reduction | Only the intended interface/routes are visible to the process after compartment switch. |
| Scaling & Rollouts | Safer blue/green | Stand up a new anchor+HostProcess pair, cut over Service selector, retire old pair. |
| Observability | Consistent log path | Launcher streams child stdout/stderr; you can attach log collectors at host or compartment scope. |
| Multi‑Tenancy | Logical segmentation | Multiple teams share a node but remain partitioned at network compartment level. |
| Compliance & Audit | Deterministic bootstrap log | Launcher emits parameters (anchor label, namespace, target exe); auditable trail. |
| Troubleshooting | Predictable mapping | Label -> anchor -> compartment -> process chain simplifies root cause analysis. |

> NOTE: While HostProcess containers run with elevated host privileges, the network compartment switch confines *network presence* of the launched process to the intended virtual environment derived from the anchor.

## Core Building Blocks
| Block | Description |
|-------|-------------|
| Anchor Pod | Minimal Windows container (e.g. pause) labeled for discovery; obtains IP + compartment. |
| Launcher (`cplauncher.exe`) | HostProcess binary that resolves anchor label, switches compartment, then execs target app. |
| HostProcess Pod | Runs on the host, but logically network‑scoped after launcher switches compartment. |
| Target Application | Any native EXE (HTTP server, OPC server, DICOM listener, etc.). |
| Volume Mount (optional) | Provides application binaries/config from the host or projected content. |
| Service | Stable virtual IP / discovery endpoint pointing at the HostProcess pod label. |

## High-Level Flow
1. Deploy (or already have) a namespace.
2. Create anchor pod with distinct label (e.g. `app=my-anchor-1`).
3. Deploy HostProcess object referencing that label via `cplauncher -label app=my-anchor-1 -namespace <ns> -- <your.exe> <args>`.
4. `cplauncher` resolves anchor pod -> extracts compartment -> switches thread -> launches application.
5. (Optional) Expose via a Service with selector `app=my-legacy-app`.
6. Scale by repeating (anchor, HostProcess pair) or using a Deployment (1:1 pods) where each new replica references a unique anchor label (pattern generation or pre-created anchors).

## Full Generic Example
Below is a generalized manifest (anchor + HostProcess) based on `cplauncher.example.yaml`. Adjust label values, paths, and image versions to fit your environment.

```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: myapp-compartment-anchor
  namespace: apps
  labels:
    app: myapp-anchor-1    # label used by cplauncher discovery
spec:
  nodeSelector:
    kubernetes.io/os: windows
  containers:
    - name: pause
      image: <your-registry>/pause-win:v1.5.0
      imagePullPolicy: IfNotPresent
  restartPolicy: Always
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-hostprocess
  namespace: apps
  labels:
    app: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      nodeSelector:
        kubernetes.io/os: windows
      securityContext:
        windowsOptions:
          hostProcess: true
          runAsUserName: "NT AUTHORITY\\SYSTEM"
      hostNetwork: true
      containers:
        - name: cplauncher
          image: mcr.microsoft.com/oss/kubernetes/windows-host-process-containers-base-image:v1.0.0
          imagePullPolicy: IfNotPresent
          command:
            - "C:\\apps\\bin\\cplauncher.exe"  # adjust path (volume / host mount)
            - "-label"; "app=myapp-anchor-1"
            - "-namespace"; "apps"
            - "-timeout"; "30s"             # optional: implement in launcher
            - "--"
            - "C:\\apps\\legacy\\myapp.exe"; "--config"; "C:\\apps\\config\\prod.json"
          volumeMounts:
            - name: host-apps
              mountPath: C:/apps
      volumes:
        - name: host-apps
          hostPath:
            path: C:/apps
            type: Directory
```

### Parameter Breakdown
| Flag / Element | Purpose | Notes |
|----------------|---------|-------|
| `-label app=myapp-anchor-1` | Selects anchor pod | Must uniquely identify one running anchor. |
| `-namespace apps` | Scopes pod lookup | Avoid cross-namespace ambiguity. |
| `-timeout 30s` | (Optional) Fails fast if anchor absent | Add to launcher implementation. |
| `--` | Separator | Everything after is the target process + its args. |
| `myapp.exe --config ...` | Target workload | Unmodified native binary. |
| Host mount `C:/apps` | Binary + config injection | Could be replaced with projected CSI / SMB if desired. |

### Adding a Service (Optional)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: apps
spec:
  selector:
    app: myapp
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080   # assuming binary listens on 8080
      protocol: TCP
```

### Scaling Strategies
| Approach | Description | Trade‑Off |
|----------|-------------|----------|
| One anchor per replica (static) | Pre-create anchors (myapp-anchor-1..N) and pass different label per HostProcess pod | Higher YAML management overhead |
| Controller-generated labels | Custom controller creates anchor + HP pair | Requires controller development |
| StatefulSet with deterministic labels | Use ordinal to form anchor label (e.g. `myapp-anchor-$(ordinal)`) | Needs deterministic anchor provisioning logic |

### Mesh / Sidecar Considerations
If your service mesh supports Windows injection, target the anchor pod for injection so that traffic is already compartment-scoped before being proxied; ensure cplauncher waits until anchor is Ready (optionally implement a readiness/annotation gate).

## Launcher Execution Model
`cplauncher` performs the following high-level sequence:
1. Query Kubernetes for pods matching the provided label in the namespace.
2. Select a suitable anchor (Ready phase, has IP).
3. Obtain compartment identifier (via Windows APIs / ancillary metadata).
4. Invoke `SetCurrentThreadCompartmentId` (and any prerequisite privilege enabling).
5. Spawn the target process (inherit/stream stdout, stderr).
6. Monitor child process; propagate its exit code; optionally emit structured JSON events.

Recommended enhancements (if not already present):
| Enhancement | Rationale |
|-------------|-----------|
| Backoff & jitter | Avoid API thundering herd on restart loops. |
| Structured logging (JSON) | Easier ingestion by log pipelines. |
| Health endpoint wrapper | Allow generic readiness probing even if legacy binary lacks one. |
| Metrics export | Expose start duration, retries, exit code counts. |
| Graceful shutdown relay | Forward CTRL_C / termination signals to child process. |

### Security Notes
Because HostProcess runs with elevated rights, restrict file system exposure (mount only what you need) and sign the launcher & target binaries. Use per‑namespace RBAC limiting list/get permissions strictly to Pods.

## Probes & Health
If the legacy binary lacks health endpoints:
| Option | Method |
|--------|--------|
| Wrapper script | Launch helper that polls a TCP port / file before signaling readiness. |
| Sidecar (Windows) | Lightweight HTTP proxy that returns 200 once child port is open. |
| Launcher built-in | Add `-wait-port 8080 -readiness-timeout 45s` style flags. |

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
1. Introduce dynamic anchor provisioning (controller/operator).
2. Support multi‑anchor failover: launcher tries ordered labels.
3. Integrate with a certificate distributor for mutual TLS inside compartment.
4. Emit OpenTelemetry spans (bootstrap duration, compartment switch latency).
5. Add optional network capture (pcap) per compartment for diagnostics.

## References
- Kubernetes Windows HostProcess Containers: https://kubernetes.io/docs/concepts/windows/intro/#hostprocess-containers
- Windows Network Compartments (Microsoft Docs): https://learn.microsoft.com/windows/win32/api/netioapi/nf-netioapi-setcurrentthreadcompartmentid

---
_Last updated: 2025-09-30_
