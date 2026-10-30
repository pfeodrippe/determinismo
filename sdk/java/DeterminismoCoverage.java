// SPDX-License-Identifier: MIT
/*
 * Code coverage for strategies on the JVM (JDK 24+, through the java.lang.classfile API): a Java
 * agent that makes each source line of the classes it is told about emit a "coverage" event the
 * first time it runs ({"name":"line <class>:<line>"}), as the C, Zig and Python SDKs do.
 * Strategies such as det-strategy-mutate keep the timelines that reach new code.
 *
 *   java -javaagent:determinismo-coverage.jar=<class name prefixes, comma-separated> ...
 *
 * The jar holds this class and Determinismo, with "Premain-Class: DeterminismoCoverage" in its
 * manifest. Classes defined at run time (Clojure's, for instance) are instrumented too. A probe
 * costs an array read once its line has been reported.
 *
 * States too, as SGFuzz finds them (USENIX Security 2022: enum-typed variables are a program's
 * state): each store to a field outside initializers whose value is an enum constant of the
 * program's own (not the JDK's) reports the transition, old constant to new, the first time it
 * happens ({"name":"state <class>.<field>: OLD -> NEW"}, a "state" event), so the tree returns
 * to the timelines that reach a new one (a transaction's ONGOING -> PREPARE_ABORT) even where
 * no new line runs.
 */
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassModel;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.MethodModel;
import java.lang.classfile.MethodTransform;
import java.lang.classfile.Opcode;
import java.lang.classfile.instruction.FieldInstruction;
import java.lang.classfile.instruction.LineNumber;
import java.lang.classfile.instruction.LocalVariable;
import java.lang.classfile.instruction.LocalVariableType;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public final class DeterminismoCoverage {
  private static final ClassDesc SELF = ClassDesc.of("DeterminismoCoverage");
  private static final MethodTypeDesc PROBE = MethodTypeDesc.of(ConstantDescs.CD_void,
      ConstantDescs.CD_int);
  private static final List<String> lines = new ArrayList<>();
  private static final Map<String, Integer> ids = new HashMap<>();
  private static volatile boolean[] reported = new boolean[1024];
  private static final MethodTypeDesc STATE = MethodTypeDesc.of(ConstantDescs.CD_void,
      ConstantDescs.CD_Object, ConstantDescs.CD_Object, ConstantDescs.CD_int);
  private static final List<String> fields = new ArrayList<>();
  private static final Map<String, Integer> fieldIds = new HashMap<>();
  /** Transitions reported: field id, old ordinal + 1 (0 for null), new ordinal + 1. */
  private static final Set<Long> transitions = ConcurrentHashMap.newKeySet();

  private DeterminismoCoverage() {}

  public static void premain(String arguments, Instrumentation instrumentation) {
    String[] prefixes = arguments == null || arguments.isEmpty()
        ? new String[0] : arguments.replace('.', '/').split(",");
    instrumentation.addTransformer(new ClassFileTransformer() {
      @Override
      public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
          ProtectionDomain domain, byte[] bytes) {
        if (name == null || name.startsWith("Determinismo") || !matches(name, prefixes)) {
          return null;
        }
        try {
          return instrument(name.replace('/', '.'), bytes);
        } catch (Throwable unsupported) {
          return null; // Left as it is: coverage is best effort, the program must still run.
        }
      }
    });
  }

  /** Called by instrumented code at the start of each line. */
  public static void line(int id) {
    boolean[] seen = reported;
    if (id < seen.length && seen[id]) return;
    report(id);
  }

  private static synchronized void report(int id) {
    if (id >= reported.length) reported = Arrays.copyOf(reported, Math.max(id + 1, 2 * id));
    boolean[] seen = reported;
    if (seen[id]) return;
    seen[id] = true;
    reported = seen; // Publishes the write to other threads (a volatile store).
    Determinismo.event("coverage", "{\"name\":\"line " + lines.get(id) + "\"}");
  }

  /** Called by instrumented code before a store to a field that may hold a state. */
  public static void state(Object value, Object old, int id) {
    if (!(value instanceof Enum<?> next) || value == old) return;
    Enum<?> before = old instanceof Enum<?> known ? known : null;
    long key = ((long) id << 32) | ((long) (before == null ? 0 : before.ordinal() + 1) << 16)
        | (next.ordinal() + 1);
    if (!transitions.add(key)) return;
    String name;
    synchronized (DeterminismoCoverage.class) {
      name = fields.get(id);
    }
    Determinismo.event("state", "{\"name\":\"state " + name + ": "
        + (before == null ? "null" : before.name()) + " -> " + next.name() + "\"}");
  }

  private static boolean matches(String name, String[] prefixes) {
    for (String prefix : prefixes) {
      if (name.startsWith(prefix)) return true;
    }
    return false;
  }

  private static byte[] instrument(String className, byte[] bytes) {
    ClassFile files = ClassFile.of();
    ClassModel model = files.parse(bytes);
    return files.transformClass(model, (classes, element) -> {
      if (!(element instanceof MethodModel method)) {
        classes.with(element);
        return;
      }
      // Initializers' stores set first states (an enum's its constants), and a constructor's
      // fields may not be readable yet (before super()): only their lines.
      boolean initializer = method.methodName().equalsString("<init>")
          || method.methodName().equalsString("<clinit>");
      classes.transformMethod(method, MethodTransform.transformingCode(probes(className, !initializer)));
    });
  }

  private static CodeTransform probes(String className, boolean states) {
    return (code, element) -> {
      // Local variable tables are debugging information only, and dropped: the API sizes the
      // locals from the code, so a variable only the table names (one Clojure never loads or
      // stores) would point past them, and the JVM refuses the class (ClassFormatError).
      if (element instanceof LocalVariable || element instanceof LocalVariableType) return;
      if (states && element instanceof FieldInstruction field && mayHoldState(field)) {
        // The value about to be stored and the field's value now, both left as they were.
        int id = registerField(field.owner().asInternalName().replace('/', '.') + "."
            + field.name().stringValue());
        if (field.opcode() == Opcode.PUTFIELD) {
          code.dup2(); // object, value, object, value
          code.swap(); // object, value, value, object
          code.getfield(field.field()); // object, value, value, old
        } else {
          code.dup(); // value, value
          code.getstatic(field.field()); // value, value, old
        }
        code.loadConstant(id);
        code.invokestatic(SELF, "state", STATE);
      }
      code.with(element);
      if (element instanceof LineNumber number) {
        code.loadConstant(register(className + ":" + number.line()));
        code.invokestatic(SELF, "line", PROBE);
      }
    };
  }

  /** A store to a field typed by a class of the program's own: an enum constant, maybe. */
  private static boolean mayHoldState(FieldInstruction field) {
    if (field.opcode() != Opcode.PUTFIELD && field.opcode() != Opcode.PUTSTATIC) return false;
    String type = field.typeSymbol().descriptorString();
    if (!type.startsWith("L")) return false; // Primitives and arrays.
    for (String library : new String[] {"Ljava/", "Ljavax/", "Ljdk/", "Lsun/", "Lscala/", "Lkotlin/", "Lclojure/"}) {
      if (type.startsWith(library)) return false;
    }
    return true;
  }

  private static synchronized int registerField(String field) {
    Integer id = fieldIds.get(field);
    if (id != null) return id;
    fieldIds.put(field, fields.size());
    fields.add(field);
    return fields.size() - 1;
  }

  private static synchronized int register(String line) {
    Integer id = ids.get(line);
    if (id != null) return id;
    ids.put(line, lines.size());
    lines.add(line);
    return lines.size() - 1;
  }
}
