<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->


[Home](../README.md)

# Offline packages

K2s provides offline support for installation and the addons.

## Creating offline package for installation (only Host Variant)

The K2s CLI provides an option to create an offline installation package (*Prerequisite:* no cluster is installed). You can find the help for package creation options with following command:

```
k2s system package -h
```

When `--for-offline-installation` flag is set the created package contains all artifacts which are needed for offline installation:

```
k2s system package -d C:\tmp -n k2s_offline_package.zip --for-offline-installation
```

Either all artifacts for offline installation are already available and cached on the system because of a previous cluster installation or a `Development Only Variant` is set up automatically in order to download all artifacts and create the base image for the Linux VM. For the latter make sure an internet connection is available.

Without the flag only repository sources are packaged.


## Creating offline package for addons

The K2s CLI provides an option to create an offline package for addons. You can find the help for package creation of addons options with following command:

```
k2s addons export -h
```

It is either possible to export only specific addons e.g.

```
k2s addons export traefik registry -d C:\tmp
```

or export all addons

```
k2s addons export -d C:\tmp
```

With this the addons artifacts are packaged to a zip file. This package can be used to make the addons available in an offline environment. For this the zip package needs to be imported after cluster installation:

```
k2s addons import -z C:\tmp\addons.zip
```

After importing the addons zip file the addons can be enabled.
