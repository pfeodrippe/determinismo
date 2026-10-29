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

  /** A double in [0, 1) from 53 random bits: a platform decision. */
  public static double random() {
    return (randomLong() >>> 11) * 0x1.0p-53;
  }

  /** Antithesis's name for {@link #randomLong}. */
  public static long getRandom() {
    return randomLong();
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
    // Outside determinismo, listed (catalogAssertions) but not announced.
    if (device == null) return;
    emit("{\"assert\":{\"type\":" + quote(kind) + ",\"message\":" + quote(message)
        + ",\"hit\":false}}");
  }

  private static final java.util.Set<String> declared =
      java.util.Collections.synchronizedSet(new java.util.LinkedHashSet<>());

  /**
   * The assertions declared so far (the catalog agent's, the Clojure SDK's macros', declare's):
   * each a {kind, message} pair.
   */
  public static java.util.List<String[]> catalogAssertions() {
    java.util.List<String[]> listed = new java.util.ArrayList<>();
    synchronized (declared) {
      for (String entry : declared) listed.add(entry.split("\u0000", 2));
    }
    return listed;
  }

  /** Writes the catalog, one JSON object a line ({"kind","message"}): for review or CI. */
  public static void catalogWrite(java.io.PrintStream out) {
    for (String[] entry : catalogAssertions()) {
      out.println("{\"kind\":" + quote(entry[0]) + ",\"message\":" + quote(entry[1]) + "}");
    }
  }

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

  // Antithesis's names.

  public static void alwaysGreaterThanOrEqualTo(double left, double right, String message,
      String details) {
    alwaysGreaterThanOrEqual(left, right, message, details);
  }

  public static void alwaysLessThanOrEqualTo(double left, double right, String message,
      String details) {
    alwaysLessThanOrEqual(left, right, message, details);
  }

  public static void sometimesGreaterThanOrEqualTo(double left, double right, String message,
      String details) {
    sometimesGreaterThanOrEqual(left, right, message, details);
  }

  public static void sometimesLessThanOrEqualTo(double left, double right, String message,
      String details) {
    sometimesLessThanOrEqual(left, right, message, details);
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
   * One of the items, a platform decision (Antithesis's Random.randomChoice): null for none. To
   * name the decision for strategies, {@link #decide}.
   */
  public static <T> T randomChoice(java.util.List<T> items) {
    if (items.isEmpty()) return null;
    return items.get((int) randomBelow(items.size()));
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

  /** A buggify point's state for a stretch of time: active with its own generator, or not. */
  private static final class BuggifyPoint {
    final java.util.SplittableRandom random;
    final long untilNanos;

    BuggifyPoint(java.util.SplittableRandom random, long untilNanos) {
      this.random = random;
      this.untilNanos = untilNanos;
    }
  }

  private static final java.util.concurrent.ConcurrentHashMap<String, BuggifyPoint> buggified =
      new java.util.concurrent.ConcurrentHashMap<>();
  private static final long BUGGIFY_PERIOD_NANOS = 2_000_000_000L;

  /**
   * A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
   * of two seconds (virtual time) in four, a named decision ("buggify &lt;name&gt;") at the
   * stretch's first evaluation, which the explorer varies and a strategy steers; while active,
   * it is true one evaluation in four, drawn from its own generator, seeded by the platform for
   * the stretch (a hot point costs a decision a stretch, not one a call). Outside determinismo,
   * always false. Where it is true, take a rare path the real system can take too (a pause before
   * a lock, a forced retry), never one it cannot.
   */
  public static boolean buggify(String name) {
    java.util.SplittableRandom random = buggifyGenerator(name);
    if (random == null) return false;
    synchronized (random) {
      return random.nextInt(4) == 0;
    }
  }

  /**
   * At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
   * (rarer than buggify: pause points sit on hot paths, and a few pauses a stretch are enough for
   * the other threads to run in the window).
   */
  public static void buggifyPause(String name) {
    java.util.SplittableRandom random = buggifyGenerator(name);
    if (random == null) return;
    long ms;
    synchronized (random) {
      if (random.nextInt(32) != 0) return;
      ms = random.nextInt(10);
    }
    try {
      Thread.sleep(ms);
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt();
    }
  }

  private static java.util.SplittableRandom buggifyGenerator(String name) {
    if (device == null) return null;
    long now = System.nanoTime(); // Virtual time inside determinismo.
    BuggifyPoint point = buggified.compute(name, (key, current) -> {
      if (current != null && now < current.untilNanos) return current;
      boolean active = randomBelowNamed("buggify " + key, 4) == 0;
      return new BuggifyPoint(active ? new java.util.SplittableRandom(randomLong()) : null,
          now + BUGGIFY_PERIOD_NANOS);
    });
    return point.random;
  }

  /** The system is ready: the platform snapshots here. */
  public static void setupComplete(String details) {
    emit("{\"lifecycle\":\"setup_complete\",\"details\":" + orEmpty(details) + "}");
  }

  public static void event(String name, String details) {
    emit("{\"event\":" + quote(name) + ",\"details\":" + orEmpty(details) + "}");
  }

  /** Antithesis's name for {@link #event}. */
  public static void sendEvent(String name, String details) {
    event(name, details);
  }

  /**
   * A fault now, from the scenario: {@code fault("{\"kind\":\"pause\",\"node\":\"db\"}")}
   * (as det-faults inject takes it). Applied, logged and undone like a drawn one; only while the
   * fault injector runs. Through det-faults: the JVM cannot open a FIFO without blocking.
   */
  public static void fault(String json) {
    faultsCommand("inject", json);
  }

  /**
   * Aims the fault injector at {@code node} from now on, until another call ("" for none): half
   * its faults involve it, each a decision strategies see and replays repeat (a primary, a
   * leader).
   */
  public static void faultAim(String node) {
    faultsCommand("aim", node);
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
        // The SDK's own frames, in the default package or copied into a project's.
        .filter(frame -> !frame.getClassName().equals("Determinismo")
            && !frame.getClassName().endsWith(".Determinismo"))
        .findFirst()
        .map(frame -> ",\"location\":{\"file\":" + quote(String.valueOf(frame.getFileName()))
            + ",\"line\":" + frame.getLineNumber() + ",\"function\":"
            + quote(frame.getClassName() + "." + frame.getMethodName()) + "}")
        .orElse(""));
  }

  private static synchronized void emit(String line) {
    byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
    if (device == null) {
      localOutput().println(line);
      return;
    }
    try {
      device.write(bytes); // One write, one event.
    } catch (IOException e) {
      System.err.println(line);
    }
  }

  private static java.io.PrintStream localOutput;

  /**
   * Outside determinismo: the file DETERMINISMO_SDK_LOCAL_OUTPUT (or Antithesis's
   * ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else stderr.
   */
  private static java.io.PrintStream localOutput() {
    if (localOutput != null) return localOutput;
    localOutput = System.err;
    String path = System.getenv("DETERMINISMO_SDK_LOCAL_OUTPUT");
    if (path == null || path.isEmpty()) path = System.getenv("ANTITHESIS_SDK_LOCAL_OUTPUT");
    if (path != null && !path.isEmpty()) {
      try {
        localOutput = new java.io.PrintStream(new java.io.FileOutputStream(path, true), true,
            StandardCharsets.UTF_8);
      } catch (IOException unwritable) {
        localOutput = System.err;
      }
    }
    return localOutput;
  }

  /** Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md). */
  public static void output(String json) {
    emit(json);
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
