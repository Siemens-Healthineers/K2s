<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Adding Registry 

[ Home ](../README.md)

This page describes how to add a registry for pulling and pushing images.

# registry options of K2s

K2s provides an option to add a registry. You can find the help for registry options with following command:

```
k2s image registry -h
```

# Add a registry

In the following example you can see how to add a registry:

```
k2s image registry add shsk2s.azurecr.io
```

You will be asked for username and password. Container runtimes on windows and linux node will be automatically configured to get access to the added registry. Credentials are stored so that you can switch easily between configured registries.

# List configured registries

The following command shows how to display all configured registries:

```
k2s image registry ls
```

# Switch between configured registries

Once you have added a registry to k2s the container runtimes are always configured to pull images when deploying a pod with an image from a configured registry in the k2s cluster. 

In order to push images you have to be logged in into the registry you want to push to. Since it is only possible to be logged in into one registry at the same time you have to switch the login to the configured registry you want to push to.

```
k2s image registry switch k2s-registry.local
```