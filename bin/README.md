<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Some small batch files

These are meant to make daily life with the K2s setup easier.
They provide some 1..3 character shortcuts for often used commands in the
Kubernetes world

## Usage

You can either add this directory directly to your user PATH, if you want
to use all the scripts 'as is'

Alternatively, cherry-pick the ones that you need and copy them into another directory,
which is in your PATH.

## Changes

Do not check in any changes that are local for you or your machine, please.
Instead, copy the file to some local directory and change it there.

## Why not Doskey?

The same could be achieved with some DOSKEY macros.
Yet, the approach with the *.cmd files has the advantage that it works
both in cmd.exe as well as in PowerShell. No need to keep two different
alias definition files in sync.