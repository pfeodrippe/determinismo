#!/bin/sh
# SPDX-License-Identifier: MIT
# The .NET program, a few times.
for run in 1 2 3; do
  dotnet /app/check.dll || exit 1
done
