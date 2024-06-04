<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Updating Documentation
The documentation is written in [Markdown](https://www.markdownguide.org/){target="_blank"}, this website is generated using [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/){target="_blank"}.

1. [Install Material for MkDocs](https://squidfunk.github.io/mkdocs-material/getting-started/){target="_blank"}
2. Run inside the local repo/installation folder of *K2s*:
   ```console
   mkdocs serve
   ```
3. Open [http://127.0.0.1:8000/K2s/](http://127.0.0.1:8000/K2s/){target="_blank"} in your web browser to see your local changes being applied on-the-fly
5. [Submit your changes](submitting-changes.md)
6. Wait for the automatically triggered workflow [![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-docs.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-docs.yml){target="_blank"} to finish
7. :rocket: Your changes are now published to [https://siemens-healthineers.github.io/K2s/](https://siemens-healthineers.github.io/K2s/){target="_blank"}