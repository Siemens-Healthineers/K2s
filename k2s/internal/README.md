<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# Overview
This folder contains all re-usable *Go* packages that cannot be referenced from outside this repo.

Even though they have interdependencies, the aim is to keep their coupling as low as possible.

As of now, the packages with higher levels of abstraction containing the domain logic are contained in the `core` folder.

The dependencies can be analyzed with *Go* tooling, e.g.:

- Install [*Goda*](https://github.com/loov/goda):
    ```sh
    go install github.com/loov/goda@latest
    ```
- Generate graph:
    ```sh
    goda graph github.com/siemens-healthineers/k2s/internal/... | dot -Tsvg -o graph-internal.svg
    ```
