# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Restore Flux CD state

.DESCRIPTION
Restores Flux resources from backup
#>

Write-Log 'Restoring Flux resources...'

if (Test-Path "$BackupDir\flux-gitrepositories.yaml") {
    kubectl apply -f "$BackupDir\flux-gitrepositories.yaml"
}

if (Test-Path "$BackupDir\flux-kustomizations.yaml") {
    kubectl apply -f "$BackupDir\flux-kustomizations.yaml"
}

if (Test-Path "$BackupDir\flux-helmreleases.yaml") {
    kubectl apply -f "$BackupDir\flux-helmreleases.yaml"
}

Write-Log 'Flux restore completed'
