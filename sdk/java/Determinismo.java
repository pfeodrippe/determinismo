// SPDX-License-Identifier: MIT
/*
 * determinismo SDK for the JVM (Java, Clojure, Kotlin, Scala): assertions, events and platform
 * randomness. One file, no dependencies: compile it with your code.
 *
 * Inside determinismo everything goes through /dev/determinismo (events are recorded with their
 * moment; random values are platform decisions, steerable and replayable). Outside it,
 * randomness comes from SecureRandom and events go to stderr. `details` are JSON objects as
 * strings (null for none).
 *
 *   Determinismo.always(total == 1000, "total balance is conserved", "{\"total\":" + total + "}");
 *   long account = Determinismo.randomBelow(10);
 */
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;

public final class Determinismo {
  private static final String DEVICE_PATH = "/dev/determinismo";
  private static final int MESSAGE_SIZE_MAX = 4096 - 16; // One event or one pull per call.
  private static final RandomAccessFile device = open();
  private static final SecureRandom fallback = device == null ? new SecureRandom() : null;

  private Determinismo() {}

  private static RandomAccessFile open() {
    // Only the device: "rw" would create a plain file where /dev is writable (containers).
    Path path = Path.of(DEVICE_PATH);
    if (!Files.exists(path) || Files.isRegularFile(path)) return null;
    try {
      return new RandomAccessFile(DEVICE_PATH, "rw");
    } catch (IOException notInsideDeterminismo) {
      return null;
    }
  }

  /** {@code count} random bytes: a platform decision inside determinismo. */
  public static synchronized byte[] randomBytes(int count) {
    byte[] bytes = new byte[count];
    if (device == null) {
      fallback.nextBytes(bytes);
      return bytes;
    }
    try {
      int done = 0;
      while (done < count) {
        int got = device.read(bytes, done, Math.min(256, count - done));
        if (got <= 0) throw new IOException("short read from " + DEVICE_PATH);
        done += got;
      }
    } catch (IOException e) {
      throw new IllegalStateException("determinismo: randomness unavailable", e);
    }
    return bytes;
  }

  public static long randomLong() {
    byte[] bytes = randomBytes(8);
    long value = 0;
    for (int index = 7; index >= 0; index--) value = (value << 8) | (bytes[index] & 0xff);
    return value;
  }

  /** A uniformly random integer in [0, count). */
  public static long randomBelow(long count) {
    if (count <= 0) throw new IllegalArgumentException("count must be positive");
    return Long.remainderUnsigned(randomLong(), count);
  }

  /**
   * A {@link java.util.Random} whose every draw is a platform decision, for code that takes an
   * RNG: what it draws is steerable by strategies and replays from tapes. Each draw is one
   * request to the platform; for hot loops, {@link #prng()}.
   */
  public static java.util.Random rng() {
    return new java.util.Random() {
      private static final long serialVersionUID = 1L;

      @Override
      protected int next(int bits) {
        return (int) (randomLong() >>> (64 - bits));
      }

      @Override
      public synchronized void setSeed(long seed) {} // The platform decides.
    };
  }

  /**
   * A fast generator seeded from one platform decision: deterministic and different in every
   * branch, steered only through its seed.
   */
  public static java.util.SplittableRandom prng() {
    return new java.util.SplittableRandom(randomLong());
  }

  public static void always(boolean condition, String message, String details) {
    assertion("always", condition, message, details);
  }

  public static void alwaysOrUnreachable(boolean condition, String message, String details) {
    assertion("always_or_unreachable", condition, message, details);
  }

  public static void sometimes(boolean condition, String message, String details) {
    assertion("sometimes", condition, message, details);
  }

  public static void reachable(String message, String details) {
    assertion("reachable", true, message, details);
  }

  public static void unreachable(String message, String details) {
    assertion("unreachable", true, message, details);
  }

  /**
   * Announces an assertion before it runs (the catalog): one never reached is then judged too.
   * DeterminismoCatalog (a Java agent) and the Clojure SDK's macros call it as code loads; each
   * assertion is announced once.
   */
  public static void declare(String kind, String message) {
    if (!declared.add(kind + '\u0000' + message)) return;
    emit("{\"assert\":{\"type\":" + quote(kind) + ",\"message\":" + quote(message)
        + ",\"hit\":false}}");
  }

  private static final java.util.Set<String> declared =
      java.util.concurrent.ConcurrentHashMap.newKeySet();

  // Guidance assertions: the compared values in the details, and a guidance event telling
  // strategies how far the timeline is from the interesting outcome (an always violated, a
  // sometimes true): distance, lower is closer, 0 or less is there.

  public static void alwaysGreaterThan(double left, double right, String message, String details) {
    compare(true, left > right, left - right, left, right, message, details);
  }

  public static void alwaysGreaterThanOrEqual(double left, double right, String message,
      String details) {
    compare(true, left >= right, left - right, left, right, message, details);
  }

  public static void alwaysLessThan(double left, double right, String message, String details) {
    compare(true, left < right, right - left, left, right, message, details);
  }

  public static void alwaysLessThanOrEqual(double left, double right, String message,
      String details) {
    compare(true, left <= right, right - left, left, right, message, details);
  }

  public static void sometimesGreaterThan(double left, double right, String message,
      String details) {
    compare(false, left > right, left - right, left, right, message, details);
  }

  public static void sometimesGreaterThanOrEqual(double left, double right, String message,
      String details) {
    compare(false, left >= right, left - right, left, right, message, details);
  }

  public static void sometimesLessThan(double left, double right, String message,
      String details) {
    compare(false, left < right, right - left, left, right, message, details);
  }

  public static void sometimesLessThanOrEqual(double left, double right, String message,
      String details) {
    compare(false, left <= right, right - left, left, right, message, details);
  }

  /** At least one of the named conditions holds, every time (all evaluated by the caller). */
  public static void alwaysSome(java.util.Map<String, Boolean> conditions, String message,
      String details) {
    int held = held(conditions);
    assertion("always", held > 0, message, conditionsDetails(conditions, details));
    guidance(message, held);
  }

  /** All the named conditions hold together, at least once. */
  public static void sometimesAll(java.util.Map<String, Boolean> conditions, String message,
      String details) {
    int held = held(conditions);
    assertion("sometimes", held == conditions.size(), message,
        conditionsDetails(conditions, details));
    guidance(message, conditions.size() - held);
  }

  private static void compare(boolean always, boolean holds, double margin, double left,
      double right, String message, String details) {
    String merged = "{\"left\":" + left + ",\"right\":" + right + ",\"details\":"
        + orEmpty(details) + "}";
    assertion(always ? "always" : "sometimes", holds, message, merged);
    guidance(message, always ? margin : -margin);
  }

  private static int held(java.util.Map<String, Boolean> conditions) {
    int held = 0;
    for (Boolean value : conditions.values()) if (Boolean.TRUE.equals(value)) held++;
    return held;
  }

  private static String conditionsDetails(java.util.Map<String, Boolean> conditions,
      String details) {
    StringBuilder out = new StringBuilder("{\"conditions\":{");
    boolean first = true;
    for (java.util.Map.Entry<String, Boolean> entry : conditions.entrySet()) {
      if (!first) out.append(',');
      first = false;
      out.append(quote(entry.getKey())).append(':').append(Boolean.TRUE.equals(entry.getValue()));
    }
    return out.append("},\"details\":").append(orEmpty(details)).append('}').toString();
  }

  private static void guidance(String message, double distance) {
    // Only improvements: all a strategy needs.
    Double known = best.get(message);
    if (known != null && distance >= known) return;
    best.put(message, distance);
    emit("{\"guidance\":{\"message\":" + quote(message) + ",\"distance\":" + distance + "}}");
  }

  /**
   * A named decision among options (which fault, which account, which node): the index chosen,
   * a platform decision announced with the options' names, for strategies.
   */
  public static int decide(String name, java.util.List<String> options) {
    if (options.isEmpty()) throw new IllegalArgumentException("no options");
    if (device != null) {
      StringBuilder list = new StringBuilder("[");
      for (int index = 0; index < options.size(); index++) {
        if (index > 0) list.append(',');
        list.append(quote(options.get(index)));
      }
      emit("{\"decision\":{\"name\":" + quote(name) + ",\"options\":" + list + "]}}");
    }
    return (int) randomBelow(options.size());
  }

  /** randomBelow, named for strategies ("retry.jitterMs"). */
  public static long randomBelowNamed(String name, long count) {
    if (device != null) {
      emit("{\"decision\":{\"name\":" + quote(name) + ",\"range\":" + count + "}}");
    }
    return randomBelow(count);
  }

  /**
   * A buggify point (FoundationDB's BUGGIFY): inside determinismo, true for one decision in four
   * (named, so the explorer varies it and a strategy steers it); outside, always false. Where it
   * is true, code takes the rare path on purpose: a pause before a lock, a forced retry.
   */
  public static boolean buggify(String name) {
    return device != null && randomBelowNamed(name, 4) == 0;
  }

  /** At a buggify point, a pause of up to 9 ms: the other threads run in that window. */
  public static void buggifyPause(String name) {
    if (!buggify(name)) return;
    try {
      Thread.sleep(randomBelowNamed(name + " (ms)", 10));
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt();
    }
  }

  /** The system is ready: the platform snapshots here. */
  public static void setupComplete(String details) {
    emit("{\"lifecycle\":\"setup_complete\",\"details\":" + orEmpty(details) + "}");
  }

  public static void event(String name, String details) {
    emit("{\"event\":" + quote(name) + ",\"details\":" + orEmpty(details) + "}");
  }

  /**
   * A fault now, from the scenario: {@code fault("{\"kind\":\"pause\",\"node\":\"db\"}")}
   * (as det-faults inject takes it). Applied, logged and undone like a drawn one; only while the
   * fault injector runs. Through det-faults: the JVM cannot open a FIFO without blocking.
   */
  public static void fault(String json) {
    faultsCommand("inject", json);
  }

  /** A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS) of {@code seconds}; 0 ends it. */
  public static void stopFaults(double seconds) {
    String command = System.getenv("DETERMINISMO_STOP_FAULTS");
    run(new String[] {command == null ? "/opt/determinismo/bin/det-stop-faults" : command,
        Double.toString(seconds)});
  }

  private static void faultsCommand(String verb, String argument) {
    run(new String[] {"/opt/determinismo/bin/det-faults", verb, argument});
  }

  private static void run(String[] command) {
    try {
      new ProcessBuilder(command).inheritIO().start().waitFor();
    } catch (java.io.IOException | InterruptedException unavailable) {
      // Outside determinismo: nothing to ask.
    }
  }

  /**
   * Which evaluations become events: every one (false, the default: queries see each), or, as
   * Antithesis's SDKs do, each assertion's first pass and first failure in this process (true:
   * for hot paths, the same verdict with far fewer events). Set it once, at the start.
   */
  public static volatile boolean firstPassFirstFailure = false;

  private static final java.util.Set<String> seen =
      java.util.concurrent.ConcurrentHashMap.newKeySet();
  private static final java.util.Map<String, Double> best =
      new java.util.concurrent.ConcurrentHashMap<>();

  private static void assertion(String kind, boolean condition, String message, String details) {
    if (firstPassFirstFailure && !seen.add(condition + "\u0000" + message)) return;
    String head = "{\"assert\":{\"type\":\"" + kind + "\",\"message\":" + quote(message)
        + ",\"condition\":" + condition + location(message) + ",\"details\":";
    String line = head + orEmpty(details) + "}}";
    if (line.getBytes(StandardCharsets.UTF_8).length > MESSAGE_SIZE_MAX) line = head + "{}}}";
    emit(line);
  }

  private static final java.util.Set<String> located =
      java.util.concurrent.ConcurrentHashMap.newKeySet();

  /** The caller's place (the first frame outside this SDK), the first time an assertion runs. */
  private static String location(String message) {
    if (!located.add(message)) return "";
    return StackWalker.getInstance().walk(frames -> frames
        .filter(frame -> !frame.getClassName().equals("Determinismo"))
        .findFirst()
        .map(frame -> ",\"location\":{\"file\":" + quote(String.valueOf(frame.getFileName()))
            + ",\"line\":" + frame.getLineNumber() + ",\"function\":"
            + quote(frame.getClassName() + "." + frame.getMethodName()) + "}")
        .orElse(""));
  }

  private static synchronized void emit(String line) {
    byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
    if (device == null) {
      System.err.println(line);
      return;
    }
    try {
      device.write(bytes); // One write, one event.
    } catch (IOException e) {
      System.err.println(line);
    }
  }

  private static String orEmpty(String details) {
    return details == null ? "{}" : details;
  }

  private static String quote(String text) {
    StringBuilder out = new StringBuilder("\"");
    for (char c : text.toCharArray()) {
      switch (c) {
        case '"': out.append("\\\""); break;
        case '\\': out.append("\\\\"); break;
        case '\n': out.append("\\n"); break;
        case '\r': out.append("\\r"); break;
        case '\t': out.append("\\t"); break;
        default:
          if (c < 0x20) out.append(String.format("\\u%04x", (int) c));
          else out.append(c);
      }
    }
    return out.append('"').toString();
  }
}
