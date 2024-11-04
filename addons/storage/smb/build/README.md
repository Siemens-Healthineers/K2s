<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Build Windows-based Images
See [Windows-based Images](../../../../smallsetup/ps-modules/windows-support/README.md#windows-based-images) for rationale why this addon requires custom Windows-based images containing 3rd-party tooling.

## Local Registry
To create the Windows-based images required for *storage* addon and push them to the local test registry (enabled via `k2s addons enable registry` with user=*test* and password=*test*):
```PowerShell
PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/sig-storage/livenessprobe" -Tag "v2.10.0" -Registry "k2s.registry.local" -Dockerfile "C:\k\addons\storage\build\Dockerfile.livenessprobe" -WorkDir "C:\k\addons\storage\build" -RegUser test -RegPw test -AllowInsecureRegistries

PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/sig-storage/csi-node-driver-registrar" -Tag "v2.8.0" -Registry "k2s.registry.local" -Dockerfile "C:\k\addons\storage\build\Dockerfile.csi-node-driver-registrar" -WorkDir "C:\k\addons\storage\build" -RegUser test -RegPw test -AllowInsecureRegistries

PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/sig-storage/smbplugin" -Tag "v1.12.0" -Registry "k2s.registry.local" -Dockerfile "C:\k\addons\storage\build\Dockerfile.smbplugin" -WorkDir "C:\k\addons\storage\build" -RegUser test -RegPw test -AllowInsecureRegistries

PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/kubernetes-sigs/sig-windows/csi-proxy" -Tag "v1.1.2" -Registry "k2s.registry.local" -Dockerfile "C:\k\addons\storage\build\Dockerfile.csi-proxy" -WorkDir "C:\k\addons\storage\build" -RegUser test -RegPw test -AllowInsecureRegistries
```

## PreDev Registry
To create the Windows-based images required for *storage* addon and push them to the PreDev registry:
```PowerShell
PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/sig-storage/livenessprobe" -Tag "v2.10.0" -Registry "shsk2s.azurecr.io" -Dockerfile "C:\k\addons\storage\build\Dockerfile.livenessprobe" -WorkDir "C:\k\addons\storage\build" -RegUser <user> -RegPw <pw>

PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/sig-storage/csi-node-driver-registrar" -Tag "v2.8.0" -Registry "shsk2s.azurecr.io" -Dockerfile "C:\k\addons\storage\build\Dockerfile.csi-node-driver-registrar" -WorkDir "C:\k\addons\storage\build" -RegUser <user> -RegPw <pw>

PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/sig-storage/smbplugin" -Tag "v1.12.0" -Registry "shsk2s.azurecr.io" -Dockerfile "C:\k\addons\storage\build\Dockerfile.smbplugin" -WorkDir "C:\k\addons\storage\build" -RegUser <user> -RegPw <pw>

PS> C:\k\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "/kubernetes-sigs/sig-windows/csi-proxy" -Tag "v1.1.2" -Registry "shsk2s.azurecr.io" -Dockerfile "C:\k\addons\storage\build\Dockerfile.csi-proxy" -WorkDir "C:\k\addons\storage\build" -RegUser <user> -RegPw <pw>
```
