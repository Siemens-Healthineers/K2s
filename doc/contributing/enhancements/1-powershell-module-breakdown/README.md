<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Enhancement Proposal for Refactoring K2s PowerShell Codebase


## Motivation

The motivation of this enhancement proposal is to refactor the K2s PowerShell codebase for better maintainability, modularity, and extensibility. The proposed structure organizes the code into distinct modules, each focused on specific functionalities, making it easier to understand, test, and enhance.


## Proposed Module Structure

1. **Core Module (k2s.core.module):**
    - Get-InstalledKubernetesVersion
    - Set-ConfigValue
    - Get-ConfigValue
    - Get-Installedk2sSetupType
    - Get-HostGwFromConfig
    - Get-WSLFromConfig

2. **Infrastructure Module (k2s.infra.module):**
    - log.module
    - DownloadFile
    - Send-ToCli

3. **Node Module (k2s.node.module):**
    - ExecCmdMaster
    - Start
    - Stop
    - Copy-FromToMaster
    - Wait-ForSshPossible
    - Open-RemoteSession
    - ssh
    - linuxnode
    - winnode
    - baseimage

4. **Network Module (k2s.network.module):**
    - HNS
    - Loopback
    - New-KubeSwitch
    - Add-DnsServer
    - CreateExternalSwitch
    - Set-IPAdressAndDnsClientServerAddress

5. **Windows Module (k2s.win.module):**
    - Start-ServiceAndSetToAutoStart
    - NSSM
    - Restart-WinService
    - Enable-MissingWindowsFeatures

6. **Cluster Module (k2s.cluster.module):**
    - Wait-ForAPIServer
    - Wait-ForPodsReady
    - Status
    - Image
    - docker

7. **Upgrade Module (k2s.upgrade.module):**
    - upgrade.module

### Base Modules

- **Characteristics:**
  - Can contain sub-modules or functions
  - Contains only basic k2s functionalities
  - Does not contain global variables
  - Use fully qualified names for external cmdlets or functions
  - For Linux Distros (Debian, Ubuntu), use shell scripting for remote command execution.

- **Examples** k2s.core.module, k2s.infra.module, k2s.node.module, k2s.network.module, k2s.win.module, k2s.cluster.module


## Addons Module

1. **k2s.addons.module**


## Multivm Modules

1. **k2s.multivm.core.module**
2. **k2s.multivm.node.module**
3. **k2s.multivm.network.module**
4. **k2s.multivm.addons.module**


## Build-Only Module

1. **k2s.buildsetup.module**


## WSL Module

1. **k2s.wsl.module**

## Open Topics

1. **Analyzer PS Dependency:**
    - Further discussion needed to analyze PowerShell dependencies and ensure compatibility.
