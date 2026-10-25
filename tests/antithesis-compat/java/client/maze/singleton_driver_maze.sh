#!/bin/sh
# SPDX-License-Identifier: MIT
# One attempt at the maze, with line coverage of class Maze.
exec java -XX:TieredStopAtLevel=1 -javaagent:/app/determinismo-coverage.jar=Maze \
  -cp /app/classes:/app/determinismo-coverage.jar Maze
