// SPDX-License-Identifier: MIT
/*
 * The assertion catalog for the JVM: a Java agent that declares every assertion in the code the
 * JVM loads, as it loads it, before any of it runs (Antithesis's catalog). An assertion no
 * timeline reaches is then known, and judged: a `sometimes` or `reachable` never hit fails, as
 * does an `always` that never ran.
 *
 *   java -javaagent:determinismo-catalog.jar ...
 *
 * The jar holds this class and Determinismo, with "Premain-Class: DeterminismoCatalog" in its
 * manifest. Every class is seen as it is defined: from jars, generated at run time, or compiled
 * by Clojure as a namespace loads or as the REPL evaluates. Its bytecode is read (no
 * dependencies, any JDK from 8 on), and each call to Determinismo.always, alwaysOrUnreachable,
 * sometimes, reachable or unreachable whose message is a constant is declared, the message found
 * by following the operand stack through the method, branches included. Messages computed at run
 * time cannot be known before they run: as in Antithesis, write them as literals.
 */
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.security.ProtectionDomain;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class DeterminismoCatalog {
  private static final String SDK = "Determinismo";

  private DeterminismoCatalog() {}

  public static void premain(String arguments, Instrumentation instrumentation) {
    instrumentation.addTransformer(new ClassFileTransformer() {
      @Override
      public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
          ProtectionDomain domain, byte[] bytes) {
        if (name != null && skipped(name)) return null;
        try {
          for (String[] found : assertions(bytes)) Determinismo.declare(found[0], found[1]);
        } catch (Throwable unreadable) {
          // The catalog is best effort: the class loads as it is either way.
        }
        return null; // Read, never changed.
      }
    });
  }

  private static boolean skipped(String name) {
    return name.startsWith(SDK) || name.startsWith("java/") || name.startsWith("javax/")
        || name.startsWith("jdk/") || name.startsWith("sun/") || name.startsWith("com/sun/")
        || name.startsWith("clojure/lang/");
  }

  /** The (kind, message) of each assertion with a constant message in a class file. */
  static List<String[]> assertions(byte[] bytes) {
    ClassReader reader = new ClassReader(bytes);
    List<String[]> found = new ArrayList<>();
    for (byte[] code : reader.methodCodes()) {
      new Interpreter(reader, code).run(found);
    }
    return found;
  }

  /** The assertion kind of a call to Determinismo, or null. */
  private static String kind(String method) {
    switch (method) {
      case "always": return "always";
      case "alwaysOrUnreachable": return "always_or_unreachable";
      case "sometimes": return "sometimes";
      case "reachable": return "reachable";
      case "unreachable": return "unreachable";
      default: return null;
    }
  }

  // The class file --------------------------------------------------------------------------

  static final class ClassReader {
    final byte[] bytes;
    final int[] offsets; // Of each constant pool entry (after its tag).
    final byte[] tags;
    private int at;

    ClassReader(byte[] bytes) {
      this.bytes = bytes;
      if (u4(0) != 0xCAFEBABE) throw new IllegalArgumentException("not a class file");
      int count = u2(8);
      offsets = new int[count];
      tags = new byte[count];
      at = 10;
      for (int index = 1; index < count; index++) {
        byte tag = bytes[at];
        tags[index] = tag;
        offsets[index] = at + 1;
        switch (tag) {
          case 1: at += 3 + u2(at + 1); break; // Utf8
          case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18: at += 5; break;
          case 5: case 6: at += 9; index++; break; // Long, Double: two entries.
          case 7: case 8: case 16: case 19: case 20: at += 3; break;
          case 15: at += 4; break; // MethodHandle
          default: throw new IllegalArgumentException("constant tag " + tag);
        }
      }
    }

    /** The bytes of every method's Code attribute: its instructions, then its handlers. */
    List<byte[]> methodCodes() {
      List<byte[]> codes = new ArrayList<>();
      int position = at + 6; // Access flags, this, super.
      position += 2 + 2 * u2(position); // Interfaces.
      position = skipMembers(position); // Fields.
      int methods = u2(position);
      position += 2;
      for (int method = 0; method < methods; method++) {
        int attributes = u2(position + 6);
        position += 8;
        for (int attribute = 0; attribute < attributes; attribute++) {
          String name = utf8(u2(position));
          int length = u4(position + 2);
          if (name.equals("Code")) {
            codes.add(Arrays.copyOfRange(bytes, position + 6, position + 6 + length));
          }
          position += 6 + length;
        }
      }
      return codes;
    }

    private int skipMembers(int position) {
      int members = u2(position);
      position += 2;
      for (int member = 0; member < members; member++) {
        int attributes = u2(position + 6);
        position += 8;
        for (int attribute = 0; attribute < attributes; attribute++) {
          position += 6 + u4(position + 2);
        }
      }
      return position;
    }

    String utf8(int index) {
      int offset = offsets[index];
      // Modified UTF-8 matches UTF-8 for the text that matters here (no NUL, no surrogates).
      return new String(bytes, offset + 2, u2(offset), StandardCharsets.UTF_8);
    }

    /** A String constant's text, or null for any other constant. */
    String string(int index) {
      return tags[index] == 8 ? utf8(u2(offsets[index])) : null;
    }

    /** [class, name, descriptor] of a field, method or invokedynamic reference. */
    String[] member(int index) {
      int offset = offsets[index];
      String owner = tags[index] == 18 ? "" : utf8(u2(offsets[u2(offset)]));
      int nameAndType = offsets[u2(offset + 2)];
      return new String[] {owner, utf8(u2(nameAndType)), utf8(u2(nameAndType + 2))};
    }

    int u2(int offset) {
      return ((bytes[offset] & 0xff) << 8) | (bytes[offset + 1] & 0xff);
    }

    int u4(int offset) {
      return (u2(offset) << 16) | u2(offset + 2);
    }
  }

  // The operand stack -----------------------------------------------------------------------

  /** A stack value: its size in slots (1, or 2 for long and double) and its String constant. */
  static final class Value {
    static final Value ONE = new Value(1, null);
    static final Value TWO = new Value(2, null);
    final int size;
    final String constant;

    Value(int size, String constant) {
      this.size = size;
      this.constant = constant;
    }

    static Value merge(Value a, Value b) {
      if (a == b) return a;
      if (a.size != b.size) return null;
      if (a.constant != null && a.constant.equals(b.constant)) return a;
      return a.size == 1 ? ONE : TWO;
    }
  }

  /**
   * Follows the operand stack through one method (every path, merging at joins) and collects
   * the assertions whose message is a constant where they are called.
   */
  static final class Interpreter {
    private final ClassReader reader;
    private final byte[] code;
    private final int length;
    private final Value[][] states;
    private final ArrayDeque<Integer> pending = new ArrayDeque<>();

    Interpreter(ClassReader reader, byte[] attribute) {
      this.reader = reader;
      this.length = u4(attribute, 4);
      this.code = Arrays.copyOfRange(attribute, 8, 8 + length);
      this.states = new Value[length][];
      flow(0, new Value[0]);
      int handlers = u2(attribute, 8 + length);
      for (int handler = 0; handler < handlers; handler++) {
        flow(u2(attribute, 8 + length + 2 + handler * 8 + 4), new Value[] {Value.ONE});
      }
    }

    void run(List<String[]> found) {
      while (!pending.isEmpty()) {
        int pc = pending.pop();
        if (!step(pc, new ArrayList<>(Arrays.asList(states[pc])), found)) return;
      }
    }

    private void flow(int pc, Value[] stack) {
      if (pc < 0 || pc >= length) return;
      Value[] known = states[pc];
      if (known == null) {
        states[pc] = stack;
        pending.push(pc);
        return;
      }
      if (known.length != stack.length) return; // Not verifiable code: leave it.
      Value[] merged = known.clone();
      boolean changed = false;
      for (int index = 0; index < merged.length; index++) {
        Value value = Value.merge(known[index], stack[index]);
        if (value == null) return;
        changed |= value != known[index];
        merged[index] = value;
      }
      if (!changed) return;
      states[pc] = merged;
      pending.push(pc);
    }

    /** One instruction: its effect on the stack, then its successors. False to give up. */
    private boolean step(int pc, List<Value> stack, List<String[]> found) {
      int op = code[pc] & 0xff;
      int next = pc + 1;
      switch (op) {
        case 0: break; // nop
        case 1: case 2: case 3: case 4: case 5: case 6: case 7: case 8: case 11: case 12:
        case 13: push(stack, Value.ONE); break;
        case 9: case 10: case 14: case 15: push(stack, Value.TWO); break;
        case 16: push(stack, Value.ONE); next = pc + 2; break; // bipush
        case 17: push(stack, Value.ONE); next = pc + 3; break; // sipush
        case 18: ldc(stack, code[pc + 1] & 0xff); next = pc + 2; break;
        case 19: ldc(stack, u2(code, pc + 1)); next = pc + 3; break;
        case 20: push(stack, Value.TWO); next = pc + 3; break; // ldc2_w
        case 21: case 23: case 25: push(stack, Value.ONE); next = pc + 2; break;
        case 22: case 24: push(stack, Value.TWO); next = pc + 2; break;
        default:
          if (op >= 26 && op <= 45) { // xload_n
            int type = (op - 26) / 4; // i, l, f, d, a
            push(stack, type == 1 || type == 3 ? Value.TWO : Value.ONE);
          } else if (op >= 46 && op <= 53) { // xaload
            pop(stack, 2);
            push(stack, op == 47 || op == 49 ? Value.TWO : Value.ONE);
          } else if (op >= 54 && op <= 58) { // xstore
            pop(stack, 1);
            next = pc + 2;
          } else if (op >= 59 && op <= 78) { // xstore_n
            pop(stack, 1);
          } else if (op >= 79 && op <= 86) { // xastore
            pop(stack, 3);
          } else if (op >= 87 && op <= 95) {
            if (!shuffle(op, stack)) return false;
          } else if (op >= 96 && op <= 115) { // add, sub, mul, div, rem
            pop(stack, 2);
            push(stack, (op - 96) % 2 == 1 ? Value.TWO : Value.ONE);
          } else if (op >= 116 && op <= 119) { // neg
            pop(stack, 1);
            push(stack, (op - 116) % 2 == 1 ? Value.TWO : Value.ONE);
          } else if (op >= 120 && op <= 131) { // shifts, and, or, xor
            pop(stack, 2);
            push(stack, (op - 120) % 2 == 1 ? Value.TWO : Value.ONE);
          } else if (op == 132) { // iinc
            next = pc + 3;
          } else if (op >= 133 && op <= 147) { // conversions
            pop(stack, 1);
            boolean wide = op == 133 || op == 135 || op == 138 || op == 140 || op == 141
                || op == 143;
            push(stack, wide ? Value.TWO : Value.ONE);
          } else if (op >= 148 && op <= 152) { // lcmp, fcmp, dcmp
            pop(stack, 2);
            push(stack, Value.ONE);
          } else if (op >= 153 && op <= 166 || op == 198 || op == 199) { // conditional jumps
            pop(stack, op >= 159 && op <= 166 ? 2 : 1);
            flow(pc + (short) u2(code, pc + 1), stack.toArray(new Value[0]));
            next = pc + 3;
          } else if (op == 167 || op == 200) { // goto, goto_w
            int offset = op == 167 ? (short) u2(code, pc + 1) : u4(code, pc + 1);
            flow(pc + offset, stack.toArray(new Value[0]));
            return true;
          } else if (op == 170 || op == 171) {
            pop(stack, 1);
            switchTargets(op, pc, stack.toArray(new Value[0]));
            return true;
          } else if (op >= 172 && op <= 177 || op == 191) { // returns, athrow
            return true;
          } else if (op >= 178 && op <= 181) {
            field(op, u2(code, pc + 1), stack);
            next = pc + 3;
          } else if (op >= 182 && op <= 186) {
            invoke(op, u2(code, pc + 1), stack, found);
            next = pc + (op >= 185 ? 5 : 3);
          } else if (op == 187) { // new
            push(stack, Value.ONE);
            next = pc + 3;
          } else if (op == 188) { // newarray
            pop(stack, 1);
            push(stack, Value.ONE);
            next = pc + 2;
          } else if (op == 189 || op == 192 || op == 193) { // anewarray, checkcast, instanceof
            Value top = pop(stack, 1);
            push(stack, op == 192 ? top : Value.ONE); // A checked String stays a constant.
            next = pc + 3;
          } else if (op == 190) { // arraylength
            pop(stack, 1);
            push(stack, Value.ONE);
          } else if (op == 194 || op == 195) { // monitorenter, monitorexit
            pop(stack, 1);
          } else if (op == 196) { // wide
            int widened = code[pc + 1] & 0xff;
            if (widened == 132) {
              next = pc + 6;
            } else {
              if (widened >= 21 && widened <= 25) {
                push(stack, widened == 22 || widened == 24 ? Value.TWO : Value.ONE);
              } else if (widened >= 54 && widened <= 58) {
                pop(stack, 1);
              } else {
                return false; // wide ret.
              }
              next = pc + 4;
            }
          } else if (op == 197) { // multianewarray
            pop(stack, code[pc + 3] & 0xff);
            push(stack, Value.ONE);
            next = pc + 4;
          } else {
            return false; // jsr, ret (subroutines) or unknown: stop following this method.
          }
      }
      flow(next, stack.toArray(new Value[0]));
      return true;
    }

    private void ldc(List<Value> stack, int index) {
      String text = reader.string(index);
      push(stack, text == null ? Value.ONE : new Value(1, text));
    }

    private void field(int op, int index, List<Value> stack) {
      String descriptor = reader.member(index)[2];
      Value value = descriptor.equals("J") || descriptor.equals("D") ? Value.TWO : Value.ONE;
      switch (op) {
        case 178: push(stack, value); break; // getstatic
        case 179: pop(stack, 1); break; // putstatic
        case 180: pop(stack, 1); push(stack, value); break; // getfield
        default: pop(stack, 2); // putfield
      }
    }

    private void invoke(int op, int index, List<Value> stack, List<String[]> found) {
      String[] member = reader.member(index);
      String descriptor = member[2];
      int arguments = argumentCount(descriptor);
      if (op == 184 && member[0].equals(SDK)) {
        String kind = kind(member[1]);
        // The message is the second to last argument: (..., String message, String details).
        if (kind != null && stack.size() >= 2) {
          String message = stack.get(stack.size() - 2).constant;
          if (message != null) found.add(new String[] {kind, message});
        }
      }
      pop(stack, arguments + (op == 184 || op == 186 ? 0 : 1));
      char result = descriptor.charAt(descriptor.indexOf(')') + 1);
      if (result != 'V') push(stack, result == 'J' || result == 'D' ? Value.TWO : Value.ONE);
    }

    private void switchTargets(int op, int pc, Value[] stack) {
      int position = (pc + 4) & ~3; // Padding to a multiple of four.
      flow(pc + u4(code, position), stack);
      if (op == 170) {
        int low = u4(code, position + 4);
        int high = u4(code, position + 8);
        for (int entry = 0; entry <= high - low; entry++) {
          flow(pc + u4(code, position + 12 + entry * 4), stack);
        }
      } else {
        int pairs = u4(code, position + 4);
        for (int pair = 0; pair < pairs; pair++) {
          flow(pc + u4(code, position + 8 + pair * 8 + 4), stack);
        }
      }
    }

    /** pop, pop2, dup, dup_x1, dup_x2, dup2, dup2_x1, dup2_x2, swap (by slot sizes). */
    private static boolean shuffle(int op, List<Value> stack) {
      int size = stack.size();
      if (size == 0) return false;
      Value v1 = stack.get(size - 1);
      switch (op) {
        case 87: pop(stack, 1); return true;
        case 88: pop(stack, v1.size == 2 ? 1 : 2); return true;
        case 89: push(stack, v1); return true;
        case 90: stack.add(size - 2, v1); return true;
        case 91: stack.add(size - (stack.get(size - 2).size == 2 ? 2 : 3), v1); return true;
        case 92:
          if (v1.size == 2) {
            push(stack, v1);
          } else {
            Value v2 = stack.get(size - 2);
            push(stack, v2);
            push(stack, v1);
          }
          return true;
        case 93:
          if (v1.size == 2) {
            stack.add(size - 2, v1);
          } else {
            stack.add(size - 3, stack.get(size - 2));
            stack.add(size - 2, v1);
          }
          return true;
        case 94: {
          // Form by sizes: the top value or pair goes under the value or pair below it.
          int top = v1.size == 2 ? 1 : 2;
          int slots = 0;
          int below = 0;
          while (slots < 2) {
            slots += stack.get(size - top - below - 1).size;
            below++;
          }
          List<Value> copied = new ArrayList<>(stack.subList(size - top, size));
          stack.addAll(size - top - below, copied);
          return true;
        }
        default: { // swap
          stack.set(size - 1, stack.get(size - 2));
          stack.set(size - 2, v1);
          return true;
        }
      }
    }

    private static int argumentCount(String descriptor) {
      int count = 0;
      int index = 1;
      while (descriptor.charAt(index) != ')') {
        char c = descriptor.charAt(index);
        while (c == '[') c = descriptor.charAt(++index);
        if (c == 'L') index = descriptor.indexOf(';', index);
        index++;
        count++;
      }
      return count;
    }

    private static void push(List<Value> stack, Value value) {
      stack.add(value);
    }

    private static Value pop(List<Value> stack, int count) {
      Value last = null;
      for (int index = 0; index < count && !stack.isEmpty(); index++) {
        last = stack.remove(stack.size() - 1);
      }
      return last;
    }

    private static int u2(byte[] bytes, int offset) {
      return ((bytes[offset] & 0xff) << 8) | (bytes[offset + 1] & 0xff);
    }

    private static int u4(byte[] bytes, int offset) {
      return (u2(bytes, offset) << 16) | u2(bytes, offset + 2);
    }
  }
}
