#!/bin/sh
# SPDX-License-Identifier: MIT
# sum.sh <a> <b>: their sum.
difference() {
  echo $(($1 - $2))
}
echo $(($1 + $2))
