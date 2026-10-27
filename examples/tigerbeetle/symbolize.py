# SPDX-License-Identifier: MIT
"""Names return addresses of a stripped binary from the assembly its exact build emitted (a
reproducible build, checked byte-identical): the instructions before each address, normalized,
are looked up in the assembly, whose labels name the enclosing function.

  python3 symbolize.py <stripped binary> <assembly.s> <return address>...

For TigerBeetle, the assembly comes from its build with
`b.addInstallFile(tigerbeetle.getEmittedAsm(), "tigerbeetle.s")` added, which leaves the binary
unchanged."""
import re
import subprocess
import sys

binary, asm = sys.argv[1], sys.argv[2]
WINDOW = 8


REGISTERS = re.compile(r"^(r[0-9]+[dwb]?|[re]?[abcd]x|[abcd][lh]|[re]?[sd]il?|[re]?[sb]pl?|[re]?ip|[xyz]mm[0-9]+|[cdefgs]s)$")


def operand(op):
    op = op.strip().lower().replace(" ", "")
    if "rip" in op:
        return "R"
    op = re.sub(r"offset[^,\]]*", "A", op)

    def literal(m):
        value = int(m.group(0), 16) if m.group(0).startswith("0x") else int(m.group(0))
        return "A" if value >= 0x1000000 else str(value)

    op = re.sub(r"0x[0-9a-f]+|\b\d+\b", literal, op)

    def symbol(m):
        word = m.group(0)
        if REGISTERS.match(word) or word in ("byte", "word", "dword", "qword", "xmmword", "ymmword", "ptr", "a"):
            return word
        return "A"

    op = re.sub(r"[a-z_.$][a-z0-9_.$@]*", symbol, op)
    return op.replace("a", "A") if op == "a" else op


def split_operands(text):
    parts, depth, current = [], 0, ""
    for ch in text:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current)
    return parts


def norm(mnemonic, operands):
    mnemonic = mnemonic.lower()
    if mnemonic.startswith("j") or mnemonic == "call":
        return mnemonic + " T"
    if mnemonic.startswith("nop") or mnemonic in ("data16", "cs", "int3"):
        return "nop"
    return mnemonic + " " + ",".join(operand(o) for o in split_operands(operands))


seq = []
function = None
for line in open(asm, errors="replace"):
    code = line.split("#")[0].rstrip()
    stripped = code.strip()
    if not stripped:
        continue
    if not line[0].isspace() and stripped.endswith(":") and not stripped.startswith(".L"):
        function = stripped[:-1].strip('"')
        continue
    if stripped.startswith(".") or stripped.endswith(":"):
        continue
    parts = stripped.split(None, 1)
    seq.append((norm(parts[0], parts[1] if len(parts) > 1 else ""), function))
seq = [s for s in seq if s[0] != "nop"]
index = {}
for i in range(len(seq) - WINDOW):
    index.setdefault(tuple(x[0] for x in seq[i:i + WINDOW]), []).append(i)

# Function starts of the stripped binary, from its unwind tables.
starts = []
frames = subprocess.run(["readelf", "--debug-dump=frames", binary], capture_output=True, text=True).stdout
for m in re.finditer(r"pc=([0-9a-f]+)\.\.([0-9a-f]+)", frames):
    starts.append((int(m.group(1), 16), int(m.group(2), 16)))
starts.sort()


def disassemble(lo, hi):
    out = subprocess.run(
        ["objdump", "-d", "-M", "intel", "--no-show-raw-insn", "--start-address=%#x" % lo,
         "--stop-address=%#x" % hi, binary], capture_output=True, text=True).stdout
    instructions = []
    for line in out.splitlines():
        m = re.match(r"\s+[0-9a-f]+:\s+(\S+)\s*(.*)$", line)
        if not m:
            continue
        operands = re.sub(r"\s*<[^>]*>|\s*#.*$", "", m.group(2)).strip()
        normalized = norm(m.group(1), operands)
        if normalized != "nop":
            instructions.append(normalized)
    return instructions


def short(name):
    # A method of a long generic type: the type's head and the method.
    at = name.rfind(").")
    return name if at < 0 else name[:name.find("(")] + "(...)" + name[at + 1:]


for ra in [int(a, 16) for a in sys.argv[3:]]:
    function = next((a for a, b in starts if a <= ra - 1 < b), None)
    if function is None:
        print("%#x: outside the unwind tables" % ra)
        continue
    before = disassemble(function, ra)[-WINDOW:]  # Ending with the call.
    hits = index.get(tuple(before), [])
    names = sorted(set(seq[i][1] for i in hits))
    shown = "; ".join(short(n) for n in names[:3]) if names else "none"
    print("%#x (+%#x in %#x) %d: %s" % (ra, ra - function, function, len(hits), shown))
