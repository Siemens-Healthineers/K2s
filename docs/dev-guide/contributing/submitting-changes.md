<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Submitting Changes
The following guidelines apply to submitting changes to *K2s*:

- Only commit changes when a corresponding issue exists and the maintainers have agreed that this issue is going to be realized (see [K2s Issues](https://github.com/Siemens-Healthineers/K2s/issues){target="_blank"})
- Reference the issue in commit messages, e.g. for a refactoring issue with ID 42, create a message like `#42 refactor(addons): obsolete code path removed`. 
!!! info
    This example also uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/){target="_blank"}, which is not mandatory, but recommended.
- Since *K2s* is open source, we utilize the *GitHub's* [Pull Requests](https://docs.github.com/en/pull-requests){target="_blank"} workflow:
    - Fork this repository (applies to all non-maintainers)
    - Create a separate branch, commit to that branch and push your changes
    - Create a PR in *GitHub* to this repository. This will trigger at least short-running automated tests.
    - The PR will be reviewed by the maintainers. If re-work is needed, the preceding steps will be iterated. If the changes are acceptable, the PR will be merged to main.
- Sign your commits (see [Commit Signing](#commit-signing))
- Run as many automated tests as possible, but at least the unit tests: `<repo>\test\execute_all_tests.ps1 -Tags unit` (see also [Main Script: execute_all_tests.ps1](automated-testing.md#main-script-execute_all_testsps1)). Depending on the area of changes, consider running the appropriate e2e tests as well.

## Commit Signing
Signing commits increases trust in your contributions. Verified commit signatures will be display in GitHub like this:

<figure markdown="span">
  ![Verified Commit](assets/verified-commit.png)
  <figcaption>Verified Commit</figcaption>
</figure>
  
Further readings: [Displaying verification statuses for all of your commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/displaying-verification-statuses-for-all-of-your-commits){target="_blank"}

!!! tip
    If you use [Visual Studio Code](https://code.visualstudio.com/){target="_blank"} in conjunction with the [GitHub Pull Requests Extension](https://marketplace.visualstudio.com/items?itemName=GitHub.vscode-pull-request-github){target="_blank"} and you are logged in into *GitHub* with that extension, your commits might get signed automatically already.

To setup code signing manually, follow these steps:

- If you do not have a GPG key yet, see [Generating a new GPG key](https://docs.github.com/en/authentication/managing-commit-signature-verification/generating-a-new-gpg-key){target="_blank"}.
!!! info
    Since you are most likely running on *Windows*, you can use the *Git bash* for `gpg` commands
- If you have a GPG key in place, sign your commits. According to [Signing commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits){target="_blank"}, the following options exist:
    - sign every commit with `git commit -S -m "YOUR_COMMIT_MESSAGE"`
    - enable GPG signature for the whole local repo with `git config commit.gpgsign true`
    - enable GPG signature for all local repos with `git config --global commit.gpgsign true`
    
    !!! tip
        To avoid entering the passphrase for the GPG key too often, you can increase the expiration time, e.g. on *Windows* using [Gpg4win](https://gpg4win.org/download.html){target="_blank"} (see [How do I install and use gpg-agent on Windows?](https://stackoverflow.com/a/66821816){target="_blank"}). Alternatively, these settings can also be modified in this file: `C:\Users\<user>\AppData\Roaming\gnupg\gpg-agent.conf`

See [Managing commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification){target="_blank"} for more information.
