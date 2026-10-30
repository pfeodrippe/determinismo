// SPDX-License-Identifier: MIT
/*
 * A maze whose progress is a state, not code: four digits from platform randomness, drawn in one
 * loop, each right one advancing the stage; 1 in 10000 attempts solves it by chance. Every
 * attempt past the first digit runs the same lines, so line coverage cannot tell them apart; the
 * agent's states can (an enum field's transitions, SGFuzz's state variables). `int` keeps the
 * same progress in an int field, which the agent does not report: the control.
 */
public final class StateMaze {
  enum Stage { START, FIRST, SECOND, THIRD, SOLVED }

  private static final long[] CODE = {7, 3, 9, 1};
  private Stage stage = Stage.START;
  private int reached;

  public static void main(String[] arguments) {
    boolean states = arguments.length == 0 || !arguments[0].equals("int");
    StateMaze maze = new StateMaze();
    for (int index = 0; index < CODE.length; index++) {
      if (Determinismo.randomBelow(10) != CODE[index]) break;
      maze.advance(states);
    }
    Determinismo.always(maze.reached < CODE.length, "the state maze is never solved", null);
  }

  private void advance(boolean states) {
    reached++;
    if (states) stage = Stage.values()[reached];
  }
}
