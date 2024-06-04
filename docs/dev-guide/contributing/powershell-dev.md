<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# PowerShell Development
## Strings
*PowerShell* takes us a lot of thinking off when it comes to strings.

For example just using 
```PowerShell 
$myPath\theFile.yaml
```
will be interpreted as a string in the end.<br/>
When using double quotes like 
```PowerShell 
"$myPath\theFile.yaml"
```
we are then telling *PowerShell* that it is a string (*PowerShell* doesn't have to do its best guess).<br/>
And if our string must contain double quotes, then 
```PowerShell 
"`"$myPath\theFile.yaml`""
```
(in the latter case, *PowerShell* interprets a string out of it) has to be used.

## Paths
Since a path can contain empty spaces extra attention has to be paid, specially when calling an external *Windows* tool with a path as argument.

The rule of thumb is the following:

- If a path value is used as argument in a call to an external tool --> add double quotes to the path value
!!! example
    ```PowerShell
        &$global:BinPath\kubectl.exe delete -f "$myPath\theFile.yaml"
    ```
- else --> nothing to do, *PowerShell* takes care of it

For some tools this is not strictly necessary, but doing so we are on the safe side, it proves that we have reflected on this and also helps the
next developer that is confronted with the code (many times just ourselves...)

## Escaping
Escaping has been changed in *PowerShell Core* (*PS* version > 5) which is required for *multivm* setup. The following example shows how quotes needs to be escaped when executing a *Linux* remote command:

```Powershell
if ($PSVersionTable.PSVersion.Major -gt 5) {
    ExecCmdMaster "echo Acquire::http::Proxy \""$Proxy\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UsePwd
} else {
    ExecCmdMaster "echo Acquire::http::Proxy \\\""$Proxy\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UsePwd
}
```

## Testing
See [Automated Testing with Pester](automated-testing.md#automated-testing-with-pester).