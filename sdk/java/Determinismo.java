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

  /** The system is ready: the platform snapshots here. */
  public static void setupComplete(String details) {
    emit("{\"lifecycle\":\"setup_complete\",\"details\":" + orEmpty(details) + "}");
  }

  public static void event(String name, String details) {
    emit("{\"event\":" + quote(name) + ",\"details\":" + orEmpty(details) + "}");
  }

  private static void assertion(String kind, boolean condition, String message, String details) {
    String head = "{\"assert\":{\"type\":\"" + kind + "\",\"message\":" + quote(message)
        + ",\"condition\":" + condition + ",\"details\":";
    String line = head + orEmpty(details) + "}}";
    if (line.getBytes(StandardCharsets.UTF_8).length > MESSAGE_SIZE_MAX) line = head + "{}}}";
    emit(line);
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
