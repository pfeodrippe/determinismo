#!/bin/sh
# SPDX-License-Identifier: MIT
# One attempt at the state maze, its stage an enum field the agent reports.
exec java -XX:TieredStopAtLevel=1 -javaagent:/app/determinismo-coverage.jar=StateMaze \
  -cp /app/classes:/app/determinismo-coverage.jar StateMaze
