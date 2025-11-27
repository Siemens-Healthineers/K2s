# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Backup Flux CD state

.DESCRIPTION
Exports Flux resources (GitRepositories, Kustomizations, HelmReleases) for backup
#>

Write-Log 'Backing up Flux resources...'

# Export Flux GitRepository resources
kubectl get gitrepositories -n rollout -o yaml > "$BackupDir\flux-gitrepositories.yaml"

# Export Flux Kustomization resources
kubectl get kustomizations -n rollout -o yaml > "$BackupDir\flux-kustomizations.yaml"

# Export Flux HelmRelease resources
kubectl get helmreleases -n rollout -o yaml > "$BackupDir\flux-helmreleases.yaml"

Write-Log 'Flux backup completed'
