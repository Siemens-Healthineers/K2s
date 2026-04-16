<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Policy Enforcement with Kyverno

*K2s* ships [Kyverno](https://kyverno.io/) as a policy enforcement framework inside the `security` addon. This guide covers audit mode, enforce mode, sample policies, and `PolicyException` usage.

## Overview

Kyverno is a Kubernetes-native admission controller. When a resource is created or updated, Kyverno evaluates it against active policies and either allows, blocks (enforce mode), or reports the violation (audit mode) before the resource is persisted.

**Phase 1 ships the framework only.** No default policies are installed. The cluster admission behaviour is identical to a cluster without Kyverno until you add policies yourself.

All Kyverno webhooks are configured with `failurePolicy: Ignore`, meaning Kyverno being unavailable (e.g. during a restart) will never block cluster operations.

## Enabling Kyverno

Kyverno is enabled by default with the security addon:

```console
k2s addons enable security
```

To opt out:

```console
k2s addons enable security --omitPolicyEnf
```

## Audit vs Enforce Mode

Each policy rule has a `validationFailureAction` field:

| Value | Behaviour |
|-------|-----------|
| `Audit` | Violations are recorded in a `PolicyReport` but resources **are not blocked** |
| `Enforce` | Non-compliant resources are **rejected** at admission time with an error message |

**Recommendation:** Always start in `Audit` mode to assess impact. Switch to `Enforce` only after confirming no legitimate workloads are affected.

## Sample Policies

### Disallow privileged containers (audit)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Audit
  rules:
    - name: check-privileged
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

### Require labels on namespaces (enforce)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-ns-labels
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Namespace
      validate:
        message: "Namespace must have a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

### Restrict hostPath volumes (audit)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-host-path
spec:
  validationFailureAction: Audit
  rules:
    - name: check-hostpath
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "HostPath volumes are restricted."
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.volumes[].hostPath | length(@) }}"
                operator: GreaterThan
                value: "0"
```

## Applying Policies

Apply a policy directly with `kubectl`:

```console
kubectl apply -f my-policy.yaml
```

Or place policy files in `addons/security/manifests/kyverno/policies/` and re-enable the addon. They will be applied automatically on each `k2s addons enable security`.

## Checking Policy Reports

After applying a policy in `Audit` mode, view violations with:

```console
kubectl get policyreport -A
kubectl describe policyreport -n <namespace> <report-name>
```

For cluster-wide reports:

```console
kubectl get clusterpolicyreport
```

## PolicyException Usage

Use a `PolicyException` to exempt specific resources from a policy without modifying the policy itself:

```yaml
apiVersion: kyverno.io/v2beta1
kind: PolicyException
metadata:
  name: allow-privileged-monitoring
  namespace: monitoring
spec:
  exceptions:
    - policyName: disallow-privileged-containers
      ruleNames:
        - check-privileged
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - monitoring
          names:
            - node-exporter-*
```

This exempts pods matching `node-exporter-*` in the `monitoring` namespace from the `disallow-privileged-containers` policy.

## Linkerd Compatibility

When running Kyverno alongside Linkerd (enhanced security mode), be aware that Linkerd injects sidecar containers via its own admission webhook. If you write policies that validate container counts or specific container names, add a `PolicyException` for the `linkerd` namespace and any meshed namespaces, or scope your policies to exclude `linkerd.io/inject: enabled` pods until Phase 2 provides pre-built exceptions.

## Further Reading

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno Policy Library](https://kyverno.io/policies/)
- [PolicyReport specification](https://kyverno.io/docs/policy-reports/)
- [Security Features Overview](security-features.md)