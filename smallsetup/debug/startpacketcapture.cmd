@echo off
REM SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
REM SPDX-License-Identifier: MIT
@echo on
Cmd /c """netsh trace start globallevel=6 provider={0c885e0d-6eb6-476c-a048-2457eed3a5c1}  provider=Microsoft-Windows-TCPIP level=5 provider={80CE50DE-D264-4581-950D-ABADEEE0D340} provider={D0E4BC17-34C7-43fc-9A72-D89A59D6979A} provider={93f693dc-9163-4dee-af64-d855218af242} provider={564368D6-577B-4af5-AD84-1C54464848E6} scenario=Virtualization provider=Microsoft-Windows-Hyper-V-VfpExt capture=yes captureMultilayer=yes capturetype=both provider=microsoft-windows-winnat provider={AE3F6C6D-BF2A-4291-9D07-59E661274EE3} keywords=0xffffffff level=6 provider={9B322459-4AD9-4F81-8EEA-DC77CDD18CA6} keywords=0xffffffff level=6 provider={0c885e0d-6eb6-476c-a048-2457eed3a5c1} level=6 provider=Microsoft-Windows-Hyper-V-VmSwitch level=5 report=disabled tracefile=c:\server.etl overwrite=yes persistent=yes"""

