# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$VmProvisioningVmName = 'KUBEMASTER_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubemasterImageName = 'Debian-11-Base-In-Provisioning-For-Kubemaster.vhdx'
$VmProvisioningNatName = 'VmProvisioningNat'
$VmProvisioningSwitchName = 'VmProvisioningSwitch'

$VmProvisioningVmName2 = 'KUBEWORKER_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubeworkerImageName2 = 'Debian-11-Base-In-Provisioning-For-Kubeworker.vhdx'
$VmProvisioningNatName2 = 'KubeworkerVmProvisioningNat'
$VmProvisioningSwitchName2 = 'KubeworkerVmProvisioningSwitch'



