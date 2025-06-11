<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# storage

## Introduction

The `storage smb` addon provides a Samba share in order to share files between the k2s nodes:

- smb share between k2s nodes can be either hosted by Windows or by Linux (Samba)
- smb share can be accessed by the node's OSs
- StorageClass "smb" based on this smb share for automatic storage volume provisioning

## Getting started

The storage smb addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable storage smb
```

## Shared folder

The SMB share folder mappings can be configured in the SmbStorage.json file located at: @(../../../K2s/addons/storage/smb/config/SmbStorage.json)
This configuration allows the definition of multiple shared folder pairs between Windows and Linux environments.

By default, the configuration contains a single shared folder mapping as shown below:

                [
                    {
                        "winMountPath": "C:\\k8s-smb-share",
                        "linuxMountPath": "/mnt/k8s-smb-share",
                        "storageClassName": "smb"
                    }
                ]

To enable multiple shared folders, the configuration can be extended as follows. You may customize the folder names and paths based on your requirements.
Ensure each shared folder mapping includes a unique storageClassName to avoid conflicts in your k2s environment.
  
                  [
                      {
                          "winMountPath": "C:\\k8s-smb-share1",
                          "linuxMountPath": "/mnt/k8s-smb-share1",
                          "storageClassName": "smb1"
                      }
                      {
                          "winMountPath": "C:\\k8s-smb-share2",
                          "linuxMountPath": "/mnt/k8s-smb-share2",
                          "storageClassName": "smb2"
                      }
                  ]


 
## Examples
- [Example Workloads](../../../k2s/test/e2e/addons/storage/workloads/)
