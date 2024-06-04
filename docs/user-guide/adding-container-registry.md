<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# Adding a Container Registry
This page describes how to add a container registry for pulling and pushing container images.

## Registry Options of the *k2s* CLI
The *k2s* CLI provides an option to add a registry. You can find the help for registry options with following command:

```console
k2s image registry -h
```

## Adding a Registry
In the following example you can see how to add a registry:

```console
k2s image registry add shsk2s.azurecr.io
```

You will be asked for username and password. Container runtimes on *Windows* and *Linux* node will be automatically configured to get access to the added registry. Credentials are stored so that you can switch easily between configured registries.

## Listing Configured Registries
The following command shows how to display all configured registries:

```console
k2s image registry ls
```

## Switching Between Configured Registries
Once you have added a registry to *K2s*, the container runtimes are always configured to pull images when deploying a pod with an image from a configured registry in the *K2s* cluster. 

In order to push images you have to be logged in into the registry you want to push to. Since it is only possible to be logged in into one registry at the same time you have to switch the login to the configured registry you want to push to:

```console
k2s image registry switch k2s-registry.local
```