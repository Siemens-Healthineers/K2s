<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

### Build the cphook.dll with mingw
## choco install -y mingw (install if not available)
g++ -shared -o ..\..\..\bin\cni\cphook.dll .\cphook\cphook.c -liphlpapi -Wl,--out-implib,libcphook.a

## build compartment launcher
c:\ws\k2s\bin\bgo.cmd -ProjectDir "c:\ws\k2s\k2s\cmd\cplauncher" -ExeOutDir "c:\ws\k2s\bin\cni"
# or for testing
go build -o cplauncher.exe .

## How to test manually
# setup buildonly setup (without K8s)
k2s install buildonly
# build a windows container somehwer to initialize also the docker daemon
k2s image build -w ...
# run a windows container in order to create a separate compartment
docker run --rm -it --name nano --network nat mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd
# start an external executable with cplaucher in the compartment of the container
c:\ws\k2s\bin\cni\cplauncher.exe -compartment 2 -- c:\ws\s\examples\albums-golang-win\albumswin.exe



