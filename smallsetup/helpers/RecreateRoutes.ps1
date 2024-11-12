# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

Write-Host 'Recreate Routes starting'

Write-Host "[$(Get-Date -Format HH:mm:ss)] Remove route to $global:IP_CIDR"
route delete $global:IP_CIDR 
Write-Host "[$(Get-Date -Format HH:mm:ss)] Add route to $global:IP_CIDR"
route -p add $global:IP_CIDR $global:IP_NextHop METRIC 3

# routes for Linux pods
Write-Host "[$(Get-Date -Format HH:mm:ss)] Remove route to $global:ClusterCIDR_Master"
route delete $global:ClusterCIDR_Master   
Write-Host "[$(Get-Date -Format HH:mm:ss)] Add route to $global:ClusterCIDR_Master"
route -p add $global:ClusterCIDR_Master $global:IP_Master METRIC 4

# routes for Windows pods
Write-Host "[$(Get-Date -Format HH:mm:ss)] Remove route to $global:ClusterCIDR_Host"
route delete $global:ClusterCIDR_Host
Write-Host "[$(Get-Date -Format HH:mm:ss)] Add route to $global:ClusterCIDR_Host"
route -p add $global:ClusterCIDR_Host $global:ClusterCIDR_NextHop METRIC 5

# routes for services
Write-Output "[$(Get-Date -Format HH:mm:ss)] Remove obsolete route to $global:ClusterCIDR_Services"
route delete $global:ClusterCIDR_Services
Write-Output "[$(Get-Date -Format HH:mm:ss)] Add route to $global:ClusterCIDR_Services"
route -p add $global:ClusterCIDR_Services $global:IP_Master METRIC 6

Write-Host 'Recreate Routes finished'