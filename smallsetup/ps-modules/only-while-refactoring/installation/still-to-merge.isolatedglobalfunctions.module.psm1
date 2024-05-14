# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

# load global settings
&$PSScriptRoot\..\..\..\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\..\..\..\common\GlobalFunctions.ps1

Initialize-Logging -ShowLogs:$true

Export-ModuleMember -Function Install-AndInitKubemaster
