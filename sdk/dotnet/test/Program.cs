// SPDX-License-Identifier: MIT
// The .NET SDK's self-test, outside determinismo: what it writes to its local output file, and
// its catalog (DeterminismoCatalog.g.cs, from sdk/dotnet/catalog). Exit status 0: all held.
using System.Text.Json.Nodes;
using Determinismo;
using Random = Determinismo.Random;

var output = Path.Combine(Path.GetTempPath(), $"determinismo-dotnet-{Environment.ProcessId}.jsonl");
Environment.SetEnvironmentVariable("DETERMINISMO_SDK_LOCAL_OUTPUT", output);
var failures = new List<string>();
void Check(bool holds, string what)
{
    if (!holds) failures.Add(what);
}

Assert.Always(true, "the total is conserved", new JsonObject { ["total"] = 1000 });
Assert.Always(false, "the total is conserved");
Assert.Sometimes(true, "a transfer happened");
Assert.Reachable("a read was answered");
Assert.AlwaysGreaterThanOrEqualTo(3, 5, "the balance stays positive");
Assert.AlwaysSome(new Dictionary<string, bool> { ["a"] = false, ["b"] = true }, "a replica answers");
if (Environment.ProcessId < 0) Assert.Unreachable("never reached in this test");
Lifecycle.SetupComplete(new JsonObject { ["nodes"] = 3 });
Lifecycle.SendEvent("transfer", new JsonObject { ["amount"] = 10 });

var below = Random.RandomBelow(7);
Check(below < 7, "RandomBelow(7) < 7");
Check(Random.RandomChoice(new[] { "x", "y" }) is "x" or "y", "RandomChoice picks an item");
var rng = new AntithesisRandom();
for (var index = 0; index < 100; index++)
{
    var value = rng.Next(10, 20);
    Check(value >= 10 && value < 20, $"AntithesisRandom.Next(10, 20) in range ({value})");
    var unit = rng.NextDouble();
    Check(unit >= 0 && unit < 1, "AntithesisRandom.NextDouble in [0, 1)");
}
Check(!Random.Buggify("a point"), "buggify is false outside determinismo");

var lines = File.ReadAllLines(output).Select(line => JsonNode.Parse(line)!.AsObject()).ToList();
JsonObject? Assertion(string message, bool condition) => lines.FirstOrDefault(line =>
    line["assert"] is JsonObject a && (string?)a["message"] == message && (bool?)a["condition"] == condition)?["assert"]?.AsObject();
var conserved = Assertion("the total is conserved", true);
Check(conserved != null, "an always true is an event");
Check((int?)conserved?["details"]?["total"] == 1000, "with its details");
Check(conserved?["location"]?["file"]?.ToString().EndsWith("Program.cs") == true, "its place: the file");
Check((int?)conserved?["location"]?["line"] > 0, "its place: the line");
Check(Assertion("the total is conserved", false) != null, "an always false is an event");
Check(Assertion("the balance stays positive", false)?["details"]?["left"]?.GetValue<double>() == 3, "a comparison's values");
Check(lines.Any(line => line["guidance"]?["message"]?.ToString() == "the balance stays positive"), "a comparison's guidance");
Check(Assertion("a replica answers", true)?["details"]?["conditions"]?["b"]?.GetValue<bool>() == true, "AlwaysSome's conditions");
Check(lines.Any(line => line["lifecycle"]?.ToString() == "setup_complete" && (int?)line["details"]?["nodes"] == 3), "setup_complete");
Check(lines.Any(line => line["event"]?.ToString() == "transfer" && (int?)line["details"]?["amount"] == 10), "an event");
var catalog = Catalog.Assertions();
Check(catalog.Contains(("unreachable", "never reached in this test")), "the generated catalog has an assertion never run");
Check(catalog.Contains(("always", "the balance stays positive")), "the catalog has a comparison as an always");
var generated = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "DeterminismoCatalog.g.cs"));
Check(generated.Contains("\"a replica answers\""), "the generator reads past a generic argument (AlwaysSome's)");
Check(!Lifecycle.IsDeterminismo, "outside determinismo");

File.Delete(output);
foreach (var failure in failures) Console.Error.WriteLine("FAIL " + failure);
Console.WriteLine(failures.Count == 0 ? "dotnet SDK: all checks hold" : $"dotnet SDK: {failures.Count} failed");
return failures.Count == 0 ? 0 : 1;
