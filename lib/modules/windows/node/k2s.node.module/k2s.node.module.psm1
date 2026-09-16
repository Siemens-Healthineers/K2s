# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# USAGE NOTES
# Root module of k2s.node.module which contains all the sub-modules and functions needed for node functionalities.
# Import-Module k2s.node.module

Get-ChildItem -Path "$PSScriptRoot" -Filter '*.psm1' -Recurse | Where-Object { $_.FullName -ne "$PSCommandPath" } | Foreach-Object { Import-Module $_.FullName }
# DO NOT USE -FORCE, INSTEAD MODIFY THE FUNCTION WITH APPROVED VERBS https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands?view=powershell-5.1

# For debugging
#Export-ModuleMember -Function '*' -Variable '*'