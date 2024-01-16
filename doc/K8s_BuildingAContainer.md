<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Building a Container 

[ Home ](../README.md)

This page describes how to build a container image using K2s.

K2s internally uses buildah (Linux) and docker (Windows) for building container images.

**Container Runtime and Build Tool**
<br>
> Windows node
>  * containerd - Used as the container runtime for the windows node.
>  * docker - Used only for building container images on the windows.

> Linux node
>  * cri-o - Used as the container runtime for the linux node.
>  * buildah - Used only for building container images on the linux.

Usage:
```
k2s image build [flags]
```

## Docker file

The steps and methods to build a container are numerous. Containers can be build in different languages, 
they can need different compilers with different options and typically, each container needs a specific basic (windows/linux...)
and a specific amount of data to be packed in the container.
This specification is defined in a unified manner in a **Dockerfile** (and this is also the real name of the file).
This ascii-file has a standard content originally defined by the [Docker Platform](https://www.docker.com/) but grown to an implicit standard and therefore reused by other Building infrastructure like the [containerd](https://containerd.io/) one.

To build a container, you must provide such a Dockerfile and store it beside your code. The tooling described below will
use this file to build the container by default. Additionally, you can use also use a dockerfile present in a different location than your code by using **--dockerfile** parameter.

## Building a windows container image.

If you need to build a windows based application, for example a .NET application will have a following project structure:

![.NET Project Folder Structure](/doc/assets/build-windows-dotnet-folder.png)

Example:
```
k2s image build --input-folder C:\s\examples\albums-netcore --windows --image-name local/example.albums-win --image-tag 99 -o
```

In the above example, K2s CLI is used with *build* option to build a .NET application under a particular folder with image name and tag accordingly. It is important to mention *--windows* flag while building windows based container image.

![Build Windows Output Snippet](/doc/assets/build-windows-output.png)

As we are building container image using docker, built image should be available for containerd and this is achieved via import of built image to containerd repository.

After a successful build command, image should be available in the containerd repository and can be queried with k2s CLI.

```
k2s image ls
```

![Build Windows Output Snippet](/doc/assets/built-win-image.png)

For running windows pods in K8s please always specify the node selector for windows, as well as a specific toleration in your yaml file:
```
      nodeSelector:
        kubernetes.io/os: windows
      tolerations:
        - key: "OS"
          operator: "Equal"
          value: "Windows"
          effect: "NoSchedule"
```

## Building a linux container image.

If you need to build a linux based application, for example a Golang application will have following project structure:

![Golang Project Folder Structure](/doc/assets/build-linux-golang-folder.png)

Example:
```
k2s image build --input-folder C:\s\examples\albums-golang --image-name local/example.albums-golang --image-tag 99 -o
```

In the above example, k2s CLI is used with *build* option to build a Golang application under a particular folder with image name and tag accordingly.


## Publishing container image to registry

In order to publish your container image, you need to label it with the appropriate version number and push it to the registry:

**Note:** Make sure the registry you want to push to is configured. Please see [ how to add a registry ](K8s_AddRegistry.md).

```
k2s image build --input-folder C:\s\examples\albums-netcore --windows --image-name local/example.albums-win --image-tag 99 -p -o
```

**--push or -p** option is required for pushing container image to configured registry.

Then, you need to update the Yaml-file with new published version:

```
   spec:
      imagePullSecrets:
        - name: regcred
      containers:
        - name: albums-win
          image: docker.io/local/example.albums-win:99
          args: ["--v", "4"]

```

## Using Dockerfile present in different location
It is possible to specify Dockerfile that is not present in the same location as your source to build the container image. This can be achieved by specifying the path to the dockerfile in **--dockerfile** or **-f** parameter.

Example:
```
k2s image build --input-folder C:\s\examples\albums-golang --dockerfile C:\Dockerfile --image-name local/example.albums-golang --image-tag 99 -o
```
Here, the dockerfile **C:\Dockerfile** is used to build the image. 

If the dockerfile **C:\Dockerfile** does not exist, then the Dockerfile, if present, beside your code is used. 

If this dockerfile does not exist as well, then the command fails.

### Note about relative paths
When specifying the dockerfile, it is possible to use relative paths.

Example:
```
k2s image build --input-folder C:\s\examples\albums-golang --dockerfile ..\..\Dockerfile --image-name local/example.albums-golang --image-tag 99 -o
```

In this case, the path to the dockerfile is resolved to the current working directory.

If the Dockerfile is not found after the path is resolved, the the Dockerfile, if present, beside your code is used. Otherwise, the script fails.


## Specifying Build arguments
Build arguments are a great way to add flexibility to your container image builds. You can pass build argument at build-time and a default value can be specified to be used as a fallback.

Example:

```
ARG BaseImage=alpine:latest

FROM ${BaseImage}
COPY servicelin /bin
RUN ["chmod",  "777", "./bin/servicelin"]
ENTRYPOINT ["/bin/servicelin"]
```

Above is a Dockerfile which has a build argument called **BaseImage**. If the build argument is not supplied during **k2s image build** then the default value **alpine:latest** is used. In this case, the container image will be built using the alpine image.

You can specify the build argument using **--build-arg** parameter. For Dockerfile above, we can supply, as an example, a debian image as shown below:

```
k2s image build -n k2s.io/servicelin -t 1 --build-arg="BaseImage=debian:latest"
```

### Multiple Build arguments
It is also possible to supply multiple build arguments. 

For example, if your Dockerfile has two build arguments **BaseImage** and **CommitId**
```
ARG BaseImage=alpine:latest
ARG CommitId=latest

FROM ${BaseImage}

LABEL "Commit-Id"=${CommitId}

COPY servicelin /bin
RUN ["chmod",  "777", "./bin/servicelin"]
ENTRYPOINT ["/bin/servicelin"]
```

Then, we can supply the values to these build arguments using the following command:

```
k2s image build -n k2s.io/servicelin -t 1 --build-arg="BaseImage=debian:latest" --build-arg="CommitId=a5e04dafb1d235a81d3332a6535b63e7"
```
Here, we use the parameter **--build-arg** twice to supply the values of both the build arguments.

For running Linux pods in K8s please always specify the node selector for Linux:
```
      nodeSelector:
        kubernetes.io/os: linux
```

## k2s build internals

Under the hood of k2s build is a PowerShell script ".\common\BuildImage.ps1" (and its batch-wrapper, both part of the K2s setup) automate the container build. A container image will be created in your local repository.

In general the **BuildImage** support Linux (default) as well as Windows container.
There are also two types of Dockerfile supported:
1. **Dockerfile**: where the entire build chain can be done and also the container image is created
2. **Dockerfile.Precompile**: all content of the current directory is build and then only the container image is created afterwards (this is default if both are available)
