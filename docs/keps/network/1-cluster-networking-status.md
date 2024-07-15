# KEP-1: Cluster Networking Overview

- [Release Signoff Checklist](#release-signoff-checklist)
- [Requirement](#requirement)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Proposal](#proposal)
  - [User Stories](#user-stories)
  - [Notes/Constraints/Caveats](#notesconstraintscaveats)
- [Design Details](#design-details)
  - [Test Plan](#test-plan)
    - [Unit tests](#unit-tests)
    - [Integration tests](#integration-tests)
    - [e2e tests](#e2e-tests)
- [Doneness Criteria](#doneness-criteria)
- [Drawbacks](#drawbacks)
- [Alternatives](#alternatives)

## Release Signoff Checklist

- [ ] KEP reviewed and approved by maintainers.
- [ ] Design details are appropriately documented.
- [ ] Test plan is in place.
  - [ ] e2e Tests.
- [ ] User documentation has been created.

## Requirement

As a `K2s` user, I want an overview of the cluster's networking health, particularly focusing on pod-to-pod and node-to-node communication.

## Motivation

A key step in ensuring a healthy cluster, both during initial deployment and ongoing operation, is to verify pod-to-pod and node-to-node communication. This functionality is a prerequisite for a functioning cluster.

### Goals

- Provide a mechanism for the user through CLI to check the cluster networking status.
- In case of networking errors, provide a possible list of troubleshooting steps.
- Check of networking status is not dependent on any external tools.
- Does not require administrative access to the node. (Administrative access via the Kubernetes API is acceptable.)

### Non-Goals

- Providing networking overview on the node (host machine) level is not in the scope.
- Resolution of networking issues automatically is not targeted here.

## Proposal

`k2s status` supports displaying basic cluster status. We will add a subcommand to display the networking status `k2s status network` that will:

1. Deploy networking pods on each node which help in performing networking health checks.
2. Perform communication with:
    - pod-to-pod
    - pod-to-pod across nodes
    - pod-to-service
    - pod-to-internet (Optional)
    - node-to-node.

### User Stories

- As a `k2s` user I want to view networking status of the cluster.
- As a `k2s` user I want to view the connectivity states across nodes.
- As a `k2s` user I want to get troubleshooting tips for faulty connection states in the network.

### Notes/Constraints/Caveats

t.b.d

## Design Details



### Test Plan

#### Unit tests

#### Integration tests

##### e2e tests

### Doneness Criteria

## Drawbacks

## Alternatives