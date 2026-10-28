// SPDX-License-Identifier: MIT
// The .NET SDK inside determinismo: platform randomness, named decisions, assertions with their
// places, and an assertion never run that the generated catalog announces.
using System.Text.Json.Nodes;
using Determinismo;
using Random = Determinismo.Random;

Assert.Always(Lifecycle.IsDeterminismo, "dotnet: inside determinismo");
var account = Random.Decide("dotnet.account", new[] { "alice", "bob", "carol" });
var amount = Random.RandomBelowNamed("dotnet.amount", 100);
var rng = new AntithesisRandom();
var spread = rng.Next(0, 10);
Assert.Sometimes(amount >= 50, "dotnet: a large transfer", new JsonObject { ["amount"] = amount });
Assert.AlwaysLessThan(amount, 100, "dotnet: the amount is below 100");
Assert.Reachable("dotnet: a transfer was drawn", new JsonObject { ["account"] = account, ["spread"] = spread });
Lifecycle.SendEvent("dotnet_transfer", new JsonObject { ["account"] = account, ["amount"] = amount });
if (amount > 1000) Assert.Unreachable("dotnet: never reached");
