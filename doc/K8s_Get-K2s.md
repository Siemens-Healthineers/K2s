<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

[Home](../README.md)

# Installation folder
You can perform the installation on a folder of your choice (*). The allowed characters are the following: 
- letters of the english alphabet (uppercase and lowercase)
- digits of the decimal system
- spaces 
- the following special characters: + - _ .

(*) Only normal folders are supported. That means, if your chosen folder is for example a symbolic link the installation will be aborted.

# Recommended: Offline Install Package
The **recommended** way of installing K2s is using our latest, officially cleared and released **offline install package**. This is also recommended for environments without internet connectivity (e.g. test networks, scanner hosts, etc.).

## 1. Download
You can download the latest version from the following location: 
- [k2s Downloads](https://github.com/Siemens-Healthineers/K2s) 

**NOTE:** Please make sure you ckeck *Unblock* in file properties before extracting zip file in case this option is available: 

![Unblock Zip Package](/doc/assets/UnblockZipPackage.png)

## 2. Extract
- **K2s** works from any drive, but it is recommended to use **C:** drive
- **Create** the folder **c:\myFolder**, e.g. via `mkdir c:\myFolder`
- **Extract** the contents of the downloaded package **to** that directory **c:\myFolder**

# Alternative: Clone Git Repository
To **perform an online installation** (i.e. all 3rd-party binaries get downloaded from the internet during installation) **or** to **contribute to K2s development**, clone the Git repository:

```shell
> mkdir c:\myFolder; cd c:\myFolder
C:\myFolder> git clone https://github.com/Siemens-Healthineers/K2s .
```

> Contact [dieter.krotz@siemens-healthineers.com](mailto:dieter.krotz@siemens-healthineers.com) if access to the repository is needed.

By default, the main branch with all cutting-edge changes is checked out. If you want to checkout a specific version, e.g. v0.5:

```shell
C:\myFolder> git checkout v1.0.0
```

# *K2s* CLI Tool
The *K2s* CLI tool provides an extensive help for all available commands and parameters/flags. After acquiring the K2s setup using one of the aforementioned options, run:
```
C:\myFolder>.\k2s -h
```

&larr;&nbsp;[Home](../README.md)&nbsp;&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;&nbsp;[Install K2s](./k2scli/install-uninstall_cmd.md#installing-small-k8s-setup-natively)&nbsp;&rarr;