// SPDX-License-Identifier: MIT
/*
 * The self-test's maze on the JVM: four digits from platform randomness, each checked before the
 * next is drawn; 1 in 10000 attempts solves it by chance. With line coverage (the agent), a
 * coverage-guided strategy climbs it one digit at a time.
 */
public final class Maze {
  public static void main(String[] arguments) {
    boolean solved = false;
    if (digit() == 7) {
      Determinismo.reachable("maze: first digit", null);
      if (digit() == 3) {
        Determinismo.reachable("maze: second digit", null);
        if (digit() == 9) {
          Determinismo.reachable("maze: third digit", null);
          if (digit() == 1) solved = true;
        }
      }
    }
    Determinismo.always(!solved, "the maze is never solved", null);
  }

  private static long digit() {
    return Determinismo.randomBelow(10);
  }
}
