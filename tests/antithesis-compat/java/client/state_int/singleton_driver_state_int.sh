#!/bin/sh
# SPDX-License-Identifier: MIT
# One attempt at the state maze, its progress only an int (the control: no states reported).
exec java -XX:TieredStopAtLevel=1 -javaagent:/app/determinismo-coverage.jar=StateMaze \
  -cp /app/classes:/app/determinismo-coverage.jar StateMaze int
