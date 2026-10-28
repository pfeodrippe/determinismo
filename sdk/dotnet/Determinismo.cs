// SPDX-License-Identifier: MIT
// determinismo SDK for .NET (C#, F#, VB): assertions, events and platform randomness, with
// Antithesis's .NET SDK's names (Assert, Lifecycle, Random, AntithesisRandom): code written for
// it ports by changing `using Antithesis.SDK;` to `using Determinismo;`. One file, no
// dependencies beyond the base library: compile it with your code (.NET 8 or later).
//
// Inside determinismo everything goes through /dev/determinismo (events are recorded with their
// moment; random values are platform decisions, steerable and replayable). Outside it,
// randomness comes from the OS and events go to the file DETERMINISMO_SDK_LOCAL_OUTPUT (or
// ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else to stderr.
//
//   Assert.Always(total == 1000, "total balance is conserved", new JsonObject { ["total"] = total });
//   var account = Random.RandomBelow(10);

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;

namespace Determinismo;

/// <summary>The platform: its device inside determinismo, the local output outside.</summary>
internal static class Platform
{
    private const string DevicePath = "/dev/determinismo";
    private const int MessageSizeMax = 4096 - 16; // One event or one pull per call.
    private static readonly object Lock = new();
    // The device through libc's open, read and write: one read is one pull, one write one
    // event (a FileStream may buffer, or read and write at offsets).
    private const int ReadWrite = 2; // O_RDWR; never O_CREAT: nothing is made where it is not.
    private const int CloseOnExec = 0x80000; // O_CLOEXEC
    private static readonly int Device = OpenDevice();
    private static TextWriter? localOutput;

    [DllImport("libc", EntryPoint = "open", SetLastError = true)]
    private static extern int LibcOpen(string path, int flags);

    [DllImport("libc", EntryPoint = "read", SetLastError = true)]
    private static extern nint LibcRead(int fd, byte[] buffer, nint count);

    [DllImport("libc", EntryPoint = "write", SetLastError = true)]
    private static extern nint LibcWrite(int fd, byte[] buffer, nint count);

    public static bool Inside => Device >= 0;

    private static int OpenDevice()
    {
        if (!OperatingSystem.IsLinux()) return -1;
        try
        {
            return LibcOpen(DevicePath, ReadWrite | CloseOnExec);
        }
        catch (Exception unavailable) when (unavailable is DllNotFoundException or EntryPointNotFoundException)
        {
            return -1;
        }
    }

    /// <summary><paramref name="buffer"/> filled with random bytes: a platform decision inside.</summary>
    public static void Bytes(Span<byte> buffer)
    {
        if (Device < 0)
        {
            RandomNumberGenerator.Fill(buffer);
            return;
        }
        lock (Lock)
        {
            var chunk = new byte[256];
            var done = 0;
            while (done < buffer.Length)
            {
                var want = Math.Min(chunk.Length, buffer.Length - done);
                var got = (int)LibcRead(Device, chunk, want);
                if (got <= 0) throw new IOException("determinismo: short read from " + DevicePath);
                chunk.AsSpan(0, got).CopyTo(buffer.Slice(done));
                done += got;
            }
        }
    }

    public static ulong NextUInt64()
    {
        Span<byte> bytes = stackalloc byte[8];
        Bytes(bytes);
        return BitConverter.ToUInt64(bytes);
    }

    /// <summary>One event: one write to the device, or a line of the local output.</summary>
    public static void Emit(string line)
    {
        lock (Lock)
        {
            if (Device < 0)
            {
                LocalOutput().WriteLine(line);
                LocalOutput().Flush();
                return;
            }
            var bytes = Encoding.UTF8.GetBytes(line);
            if (LibcWrite(Device, bytes, bytes.Length) != bytes.Length) Console.Error.WriteLine(line); // One write, one event.
        }
    }

    public static bool Fits(string line) => Encoding.UTF8.GetByteCount(line) <= MessageSizeMax;

    private static TextWriter LocalOutput()
    {
        if (localOutput != null) return localOutput;
        localOutput = Console.Error;
        var path = Environment.GetEnvironmentVariable("DETERMINISMO_SDK_LOCAL_OUTPUT");
        if (string.IsNullOrEmpty(path)) path = Environment.GetEnvironmentVariable("ANTITHESIS_SDK_LOCAL_OUTPUT");
        if (!string.IsNullOrEmpty(path))
        {
            try
            {
                localOutput = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
            }
            catch (Exception unwritable) when (unwritable is IOException or UnauthorizedAccessException)
            {
                localOutput = Console.Error;
            }
        }
        return localOutput;
    }

    public static string Quote(string text) => JsonSerializer.Serialize(text);

    public static string Json(JsonNode? node) => node == null ? "{}" : node.ToJsonString();
}

/// <summary>Properties of the system: each assertion's message is its identity.</summary>
public static class Assert
{
    /// <summary>
    /// Which evaluations become events: every one (false, the default: queries see each), or, as
    /// Antithesis's SDKs do, each assertion's first pass and first failure in this process (true:
    /// for hot paths, the same verdict with far fewer events). Set it once, at the start.
    /// </summary>
    public static bool FirstPassFirstFailure { get; set; }

    private static readonly ConcurrentDictionary<string, bool> Seen = new();
    private static readonly ConcurrentDictionary<string, bool> Located = new();
    private static readonly ConcurrentDictionary<string, double> Best = new();

    public static void Always(bool condition, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("always", condition, message, details, file, line, member);

    public static void AlwaysOrUnreachable(bool condition, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("always_or_unreachable", condition, message, details, file, line, member);

    public static void Sometimes(bool condition, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("sometimes", condition, message, details, file, line, member);

    public static void Reachable(string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("reachable", true, message, details, file, line, member);

    public static void Unreachable(string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("unreachable", true, message, details, file, line, member);

    // Guidance assertions: the compared values in the details, and a guidance event telling
    // strategies how far the timeline is from the interesting outcome (an always violated, a
    // sometimes true): distance, lower is closer, 0 or less is there.

    public static void AlwaysGreaterThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left > right, left - right, left, right, message, details, file, line, member);

    public static void AlwaysGreaterThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left >= right, left - right, left, right, message, details, file, line, member);

    public static void AlwaysLessThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left < right, right - left, left, right, message, details, file, line, member);

    public static void AlwaysLessThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left <= right, right - left, left, right, message, details, file, line, member);

    public static void SometimesGreaterThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left > right, left - right, left, right, message, details, file, line, member);

    public static void SometimesGreaterThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left >= right, left - right, left, right, message, details, file, line, member);

    public static void SometimesLessThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left < right, right - left, left, right, message, details, file, line, member);

    public static void SometimesLessThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left <= right, right - left, left, right, message, details, file, line, member);

    /// <summary>At least one of the named conditions holds, every time.</summary>
    public static void AlwaysSome(IReadOnlyDictionary<string, bool> conditions, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "")
    {
        var held = Held(conditions);
        Assertion("always", held > 0, message, ConditionsDetails(conditions, details), file, line, member);
        Guidance(message, held);
    }

    /// <summary>All the named conditions hold together, at least once.</summary>
    public static void SometimesAll(IReadOnlyDictionary<string, bool> conditions, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "")
    {
        var held = Held(conditions);
        Assertion("sometimes", held == conditions.Count, message, ConditionsDetails(conditions, details), file, line, member);
        Guidance(message, conditions.Count - held);
    }

    private static void Compare(bool always, bool holds, double margin, double left, double right, string message,
        JsonObject? details, string file, int line, string member)
    {
        var merged = new JsonObject { ["left"] = left, ["right"] = right, ["details"] = details?.DeepClone() ?? new JsonObject() };
        Assertion(always ? "always" : "sometimes", holds, message, merged, file, line, member);
        Guidance(message, always ? margin : -margin);
    }

    private static int Held(IReadOnlyDictionary<string, bool> conditions)
    {
        var held = 0;
        foreach (var value in conditions.Values) if (value) held++;
        return held;
    }

    private static JsonObject ConditionsDetails(IReadOnlyDictionary<string, bool> conditions, JsonObject? details)
    {
        var named = new JsonObject();
        foreach (var (name, value) in conditions) named[name] = value;
        return new JsonObject { ["conditions"] = named, ["details"] = details?.DeepClone() ?? new JsonObject() };
    }

    private static void Guidance(string message, double distance)
    {
        // Only improvements: all a strategy needs.
        if (Best.TryGetValue(message, out var known) && distance >= known) return;
        Best[message] = distance;
        Platform.Emit("{\"guidance\":{\"message\":" + Platform.Quote(message) + ",\"distance\":" +
            distance.ToString("R", CultureInfo.InvariantCulture) + "}}");
    }

    private static void Assertion(string kind, bool condition, string message, JsonObject? details,
        string file, int line, string member)
    {
        if (FirstPassFirstFailure && !Seen.TryAdd(condition + "\0" + message, true)) return;
        Catalog.Note(kind, message);
        // The caller's place, the first time an assertion runs.
        var location = Located.TryAdd(message, true)
            ? ",\"location\":{\"file\":" + Platform.Quote(file) + ",\"line\":" + line + ",\"function\":" + Platform.Quote(member) + "}"
            : "";
        var head = "{\"assert\":{\"type\":\"" + kind + "\",\"message\":" + Platform.Quote(message) +
            ",\"condition\":" + (condition ? "true" : "false") + location + ",\"details\":";
        var text = head + Platform.Json(details) + "}}";
        if (!Platform.Fits(text)) text = head + "{}}}";
        Platform.Emit(text);
    }
}

/// <summary>The assertion catalog: announced before assertions run, so one never reached is judged too.</summary>
public static class Catalog
{
    private static readonly object Lock = new();
    private static readonly List<(string Kind, string Message)> Declared = new();
    private static readonly HashSet<string> Known = new();

    /// <summary>
    /// Announces an assertion (kind: always, always_or_unreachable, sometimes, reachable,
    /// unreachable). A module initializer can declare a program's (Antithesis's .NET SDK
    /// generates one); each assertion is announced once.
    /// </summary>
    public static void Declare(string kind, string message)
    {
        if (!Note(kind, message)) return;
        // Outside determinismo, listed (Assertions) but not announced.
        if (!Platform.Inside) return;
        Platform.Emit("{\"assert\":{\"type\":" + Platform.Quote(kind) + ",\"message\":" + Platform.Quote(message) + ",\"hit\":false}}");
    }

    internal static bool Note(string kind, string message)
    {
        lock (Lock)
        {
            if (!Known.Add(kind + "\0" + message)) return false;
            Declared.Add((kind, message));
            return true;
        }
    }

    /// <summary>The assertions declared or run so far.</summary>
    public static IReadOnlyList<(string Kind, string Message)> Assertions()
    {
        lock (Lock) return Declared.ToArray();
    }

    /// <summary>Writes the catalog, one JSON object a line ({"kind","message"}): for review or CI.</summary>
    public static void Write(TextWriter output)
    {
        foreach (var (kind, message) in Assertions())
            output.WriteLine("{\"kind\":" + Platform.Quote(kind) + ",\"message\":" + Platform.Quote(message) + "}");
    }
}

/// <summary>The test's lifecycle and events of its own.</summary>
public static class Lifecycle
{
    /// <summary>Whether this runs inside determinismo (Antithesis's IsAntithesis).</summary>
    public static bool IsDeterminismo => Platform.Inside;

    public static bool IsAntithesis => Platform.Inside;

    /// <summary>The system is ready: the platform snapshots here.</summary>
    public static void SetupComplete(JsonObject? details = null) =>
        Platform.Emit("{\"lifecycle\":\"setup_complete\",\"details\":" + Platform.Json(details) + "}");

    public static void SendEvent(string? name, JsonObject? details = null) =>
        Platform.Emit("{\"event\":" + Platform.Quote(name ?? "") + ",\"details\":" + Platform.Json(details) + "}");

    /// <summary>Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md).</summary>
    public static void Output(JsonObject json) => Platform.Emit(json.ToJsonString());

    /// <summary>
    /// A fault now, from the scenario: <c>Fault("{\"kind\":\"pause\",\"node\":\"db\"}")</c> (as
    /// det-faults inject takes it). Applied, logged and undone like a drawn one; only while the
    /// fault injector runs.
    /// </summary>
    public static void Fault(string json) => Run("/opt/determinismo/bin/det-faults", "inject", json);

    /// <summary>A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS) of <paramref name="seconds"/>; 0 ends it.</summary>
    public static void StopFaults(double seconds) =>
        Run(Environment.GetEnvironmentVariable("DETERMINISMO_STOP_FAULTS") ?? "/opt/determinismo/bin/det-stop-faults",
            seconds.ToString(CultureInfo.InvariantCulture));

    private static void Run(string program, params string[] arguments)
    {
        try
        {
            using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(program, arguments));
            process?.WaitForExit();
        }
        catch (Exception unavailable) when (unavailable is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            // Outside determinismo: nothing to ask.
        }
    }
}

/// <summary>Platform randomness: every draw a decision inside determinismo.</summary>
public static class Random
{
    /// <summary>64 random bits (Antithesis's GetRandom).</summary>
    public static ulong GetRandom() => Platform.NextUInt64();

    public static void Bytes(Span<byte> buffer) => Platform.Bytes(buffer);

    /// <summary>A uniformly random integer in [0, count).</summary>
    public static ulong RandomBelow(ulong count)
    {
        if (count == 0) throw new ArgumentOutOfRangeException(nameof(count), "count must be positive");
        return Platform.NextUInt64() % count;
    }

    /// <summary>A double in [0, 1) from 53 random bits.</summary>
    public static double RandomFloat() => (Platform.NextUInt64() >> 11) * (1.0 / (1UL << 53));

    /// <summary>One of the items, a platform decision; default for none (Antithesis's RandomChoice).</summary>
    public static T? RandomChoice<T>(IReadOnlyList<T> items) =>
        items.Count == 0 ? default : items[(int)RandomBelow((ulong)items.Count)];

    /// <summary>A named decision among options: the index chosen, announced with the options for strategies.</summary>
    public static int Decide(string name, IReadOnlyList<string> options)
    {
        if (options.Count == 0) throw new ArgumentException("no options", nameof(options));
        if (Platform.Inside)
        {
            var list = new JsonArray();
            foreach (var option in options) list.Add(option);
            Platform.Emit("{\"decision\":{\"name\":" + Platform.Quote(name) + ",\"options\":" + list.ToJsonString() + "}}");
        }
        return (int)RandomBelow((ulong)options.Count);
    }

    /// <summary>RandomBelow, named for strategies ("retry.jitterMs").</summary>
    public static ulong RandomBelowNamed(string name, ulong count)
    {
        if (Platform.Inside) Platform.Emit("{\"decision\":{\"name\":" + Platform.Quote(name) + ",\"range\":" + count + "}}");
        return RandomBelow(count);
    }

    /// <summary>A System.Random whose every draw is a platform decision (Antithesis's AntithesisRandom).</summary>
    public static System.Random Rng() => new AntithesisRandom();

    /// <summary>A fast generator seeded from one platform decision: different in every branch.</summary>
    public static System.Random Prng() => new System.Random((int)(Platform.NextUInt64() & 0x7fffffff));

    private sealed class Point
    {
        public System.Random? Generator;
        public long UntilTicks;
    }

    private static readonly ConcurrentDictionary<string, Point> Buggified = new();
    private static readonly long BuggifyPeriodTicks = 2 * TimeSpan.TicksPerSecond;

    /// <summary>
    /// A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
    /// of two seconds (virtual time) in four, a named decision ("buggify &lt;name&gt;"); while
    /// active, true one evaluation in four. Outside determinismo, always false.
    /// </summary>
    public static bool Buggify(string name)
    {
        var generator = BuggifyGenerator(name);
        if (generator == null) return false;
        lock (generator) return generator.Next(4) == 0;
    }

    /// <summary>At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active.</summary>
    public static void BuggifyPause(string name)
    {
        var generator = BuggifyGenerator(name);
        if (generator == null) return;
        int ms;
        lock (generator)
        {
            if (generator.Next(32) != 0) return;
            ms = generator.Next(10);
        }
        Thread.Sleep(ms);
    }

    private static System.Random? BuggifyGenerator(string name)
    {
        if (!Platform.Inside) return null;
        var now = DateTime.UtcNow.Ticks; // Virtual time inside determinismo.
        var point = Buggified.AddOrUpdate(name,
            key => Fresh(key, now),
            (key, current) => now < current.UntilTicks ? current : Fresh(key, now));
        return point.Generator;
    }

    private static Point Fresh(string name, long now)
    {
        var active = RandomBelowNamed("buggify " + name, 4) == 0;
        return new Point
        {
            Generator = active ? new System.Random((int)(Platform.NextUInt64() & 0x7fffffff)) : null,
            UntilTicks = now + BuggifyPeriodTicks,
        };
    }
}

/// <summary>A System.Random whose every draw is a platform decision (Antithesis's name).</summary>
public class AntithesisRandom : System.Random
{
    public override int Next() => (int)(Platform.NextUInt64() >> 33);

    public override int Next(int maxValue)
    {
        if (maxValue < 0) throw new ArgumentOutOfRangeException(nameof(maxValue));
        return maxValue == 0 ? 0 : (int)Random.RandomBelow((ulong)maxValue);
    }

    public override int Next(int minValue, int maxValue)
    {
        if (minValue > maxValue) throw new ArgumentOutOfRangeException(nameof(minValue));
        return maxValue == minValue ? minValue : minValue + (int)Random.RandomBelow((ulong)((long)maxValue - minValue));
    }

    public override long NextInt64() => (long)(Platform.NextUInt64() >> 1);

    public override double NextDouble() => Random.RandomFloat();

    protected override double Sample() => Random.RandomFloat();

    public override void NextBytes(byte[] buffer) => Platform.Bytes(buffer);

    public override void NextBytes(Span<byte> buffer) => Platform.Bytes(buffer);
}
