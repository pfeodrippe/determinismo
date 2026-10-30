// SPDX-License-Identifier: MIT
//! Typed system descriptions and scenarios for Zig test programs (see determinismo.zig).
//!
//! `System(Nodes)` ties three things to one type, `Nodes` (a struct whose fields are `Node` or
//! `?Node`): the profiles `describe` builds (`profile.node(.redis, ...)`, checked at compile
//! time), the scenarios (functions listing test commands), and what handlers see at run time
//! (`ctx.nodes.redis.address`).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const schema = @import("schema.zig");

const profiles_max = 16;
const system_size_max = 1 << 20;
const nodes_binary = "/opt/determinismo/bin/det-nodes";

/// A command's exit status and what it printed.
pub const Output = struct { status: u8, output: []const u8 };

/// What a host check gets besides its records (System.main's `.checks`): it runs on the host,
/// once the timeline of `scenario` ended.
pub const Check = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    scenario: []const u8,
};

/// A node as tests see it in the guest.
pub const Node = struct {
    name: []const u8,
    address: [4]u8,

    /// Freezes all its processes (until `unpause`).
    pub fn pause(node: *const Node) !void {
        return nodes_command(&.{ "pause", node.name });
    }

    pub fn unpause(node: *const Node) !void {
        return nodes_command(&.{ "resume", node.name });
    }

    /// Kills all its processes; `start` runs it again with its files intact.
    pub fn kill(node: *const Node) !void {
        return nodes_command(&.{ "kill", node.name });
    }

    pub fn start(node: *const Node) !void {
        return nodes_command(&.{ "start", node.name });
    }

    /// A power loss, then it starts again: its disk keeps what was synced and loses the rest
    /// (the node needs crash faults allowed, which give it a disk of its own).
    pub fn crash(node: *const Node) !void {
        return nodes_command(&.{ "crash", node.name });
    }

    /// It starts again fresh from its image: everything it wrote is gone.
    pub fn wipe(node: *const Node) !void {
        return nodes_command(&.{ "wipe", node.name });
    }

    /// Runs `argv` inside the node (like `docker exec`); returns its exit status. Its output goes
    /// to this command's output.
    pub fn exec(node: *const Node, argv: []const []const u8) !u8 {
        assert(argv.len > 0);
        assert(argv.len + 3 <= exec_arguments_max);
        var arguments: [exec_arguments_max][]const u8 = undefined;
        arguments[0] = "exec";
        arguments[1] = node.name;
        for (argv, arguments[2..][0..argv.len]) |argument, *target| target.* = argument;
        return (try nodes_run(arguments[0 .. argv.len + 2], null)).status;
    }

    /// Like `exec`, with the command's standard output captured into `buffer` (what fits; the
    /// rest is read and dropped): for tools whose answer is their output (kubectl get, psql).
    pub fn exec_output(node: *const Node, argv: []const []const u8, buffer: []u8) !Output {
        assert(argv.len > 0);
        assert(argv.len + 3 <= exec_arguments_max);
        var arguments: [exec_arguments_max][]const u8 = undefined;
        arguments[0] = "exec";
        arguments[1] = node.name;
        for (argv, arguments[2..][0..argv.len]) |argument, *target| target.* = argument;
        return nodes_run(arguments[0 .. argv.len + 2], buffer);
    }

    /// Cuts (or restores) the link between this node and `peer` (a node name or "runner").
    pub fn link(node: *const Node, peer: []const u8, state: enum { up, down }) !void {
        return nodes_command(&.{ "link", node.name, peer, @tagName(state) });
    }
};

/// How a node is built and run; mirrors `schema.Node` with typed dependencies.
pub fn NodeSpec(comptime Name: type) type {
    return struct {
        image: ?[]const u8 = null,
        directory: ?[]const u8 = null,
        binary: ?[]const u8 = null,
        build: ?schema.Build = null,
        entrypoint: ?[]const []const u8 = null,
        command: ?[]const []const u8 = null,
        env: []const []const u8 = &.{},
        workdir: ?[]const u8 = null,
        user: ?[]const u8 = null,
        ready: ?schema.Ready = null,
        after: []const Name = &.{},
        faults: schema.Faults = .{},
        memory_max_mib: ?u32 = null,
        privileged: bool = false,
        /// Process limits (Docker's names: .{ .name = "nofile", .soft = 65536, .hard = 65536 }).
        ulimits: ?[]const schema.Ulimit = null,
        /// Processes (by command name) whose crashes the system is known to have: counted, not
        /// failed (schema.Node.crashes_known).
        crashes_known: []const []const u8 = &.{},
        /// A writeback window in seconds: the node's disk synced that often, as a host's flusher
        /// would (schema.Node.writeback_s); null: strict, nothing written back unasked.
        writeback_s: ?u32 = null,
        /// Exits the system is known to make, by what the node wrote last: counted, not failed
        /// (schema.Node.exits_known).
        exits_known: []const []const u8 = &.{},
        /// Not started with the others: a driver starts it (`Node.start`), a member joining
        /// later (schema.Node.spare).
        spare: bool = false,
    };
}

pub fn System(comptime Nodes: type) type {
    const field_names = std.meta.fieldNames(Nodes);
    const field_types = std.meta.fieldTypes(Nodes);
    comptime {
        assert(field_names.len > 0);
        assert(field_names.len <= schema.nodes_max);
        for (field_names, field_types) |name, Field| {
            assert(Field == Node or Field == ?Node);
            assert(schema.name_valid(name));
        }
    }
    return struct {
        pub const Name = std.meta.FieldEnum(Nodes);
        pub const Spec = NodeSpec(Name);

        /// What a handler gets: the nodes of the running system and the process's resources.
        pub const Context = struct {
            nodes: Nodes,
            scenario: []const u8,
            /// The profile the system runs ("default" outside the guest): a scenario whose
            /// profiles run different releases speaks to each as it is.
            profile: []const u8 = "default",
            init: std.process.Init,
        };

        pub const Handler = *const fn (context: *Context) anyerror!void;

        /// A scenario: the test commands of one family of timelines (Antithesis's test
        /// template). Built by an ordinary function, so commands can be shared and parametrized.
        pub const Scenario = struct {
            name: []const u8,
            commands: [schema.commands_max]Entry = undefined,
            count: u32 = 0,
            faults: bool = true,
            clock_skip: bool = false,
            pacing: schema.Pacing = .{},

            const Entry = struct { command: schema.Command, handler: Handler };

            pub fn setup(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.setup, name, handler);
            }
            pub fn first(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.first, name, handler);
            }
            pub fn parallel_driver(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.parallel_driver, name, handler);
            }
            pub fn serial_driver(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.serial_driver, name, handler);
            }
            pub fn singleton_driver(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.singleton_driver, name, handler);
            }
            pub fn anytime(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.anytime, name, handler);
            }
            pub fn eventually(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.eventually, name, handler);
            }
            pub fn finally(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.finally, name, handler);
            }

            fn add(s: *Scenario, kind: schema.Kind, name: []const u8, handler: Handler) void {
                assert(name.len > 0);
                assert(s.count < schema.commands_max);
                for (s.commands[0..s.count]) |entry| {
                    assert(!std.mem.eql(u8, entry.command.name, name)); // Names are unique.
                }
                s.commands[s.count] = .{
                    .command = .{ .kind = kind, .name = name },
                    .handler = handler,
                };
                s.count += 1;
            }

            fn find(s: *const Scenario, name: []const u8) ?Handler {
                for (s.commands[0..s.count]) |entry| {
                    if (std.mem.eql(u8, entry.command.name, name)) return entry.handler;
                }
                return null;
            }
        };

        pub const Describe = struct {
            profiles: [profiles_max]Profile = undefined,
            count: u32 = 0,

            pub fn profile(d: *Describe, name: []const u8) !*Profile {
                if (d.count == profiles_max) return error.TooManyProfiles;
                d.profiles[d.count] = .{ .name = name };
                d.count += 1;
                return &d.profiles[d.count - 1];
            }
        };

        pub const Profile = struct {
            name: []const u8,
            specs: [field_names.len]?Spec = @splat(null),
            /// A command that turns the system's logs up, in the guest at a moment (`det-nodes
            /// exec <node> ...`): what causality's explanation runs inside a jump.
            explain: ?[]const u8 = null,

            pub fn node(p: *Profile, comptime name: Name, spec: Spec) void {
                assert(p.specs[@backingInt(name)] == null); // Each node once per profile.
                p.specs[@backingInt(name)] = spec;
            }
        };

        const Self = @This();

        /// `--describe` and `check <name> <scenario>` on the host, `run <scenario> <command>` in
        /// the guest. `definition` is `.{ .describe = fn (*Describe) !void, .scenarios = .{ .name
        /// = fn (*Scenario) void } }`, and optionally `.checks = .{ .name = fn (*Check, []const
        /// Record) !void }`: host checks, run when each timeline ends on the records its commands
        /// made (`sdk.record("name", record)`), decoded as the function's Record type (or, for
        /// `[]const u8`, the raw JSON lines). A check asserts as anything else does
        /// (`sdk.always`, ...): its assertions are properties of the timeline, at its end.
        pub fn main(init: std.process.Init, comptime definition: anytype) !void {
            const arena = init.arena.allocator();
            const arguments = try init.minimal.args.toSlice(arena);
            if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--describe")) {
                return Self.describe_print(arena, init.io, definition);
            }
            if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "run")) {
                return Self.run(init, definition, arguments[2], arguments[3]);
            }
            if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "check")) {
                var check: Check = .{ .arena = arena, .io = init.io, .scenario = arguments[3] };
                return Self.check_run(&check, definition, arguments[2]);
            }
            std.debug.print("usage: {s} --describe | run <scenario> <command> | " ++
                "check <name> <scenario>\n", .{arguments[0]});
            std.process.exit(2);
        }

        /// A host check: its records from standard input (one JSON line each), decoded as the
        /// function's Record type (raw for `[]const u8`), then the function.
        fn check_run(check: *Check, comptime definition: anytype, name: []const u8) !void {
            if (!@hasField(@TypeOf(definition), "checks")) return error.UnknownCheck;
            const arena = check.arena;
            var input: std.ArrayList(u8) = .empty;
            while (true) {
                try input.ensureUnusedCapacity(arena, 1 << 16);
                const free = input.unusedCapacitySlice();
                const result = linux.read(0, free.ptr, free.len);
                if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
                if (result == 0) break;
                input.items.len += result;
            }
            inline for (comptime std.meta.fieldNames(@TypeOf(definition.checks))) |field| {
                if (std.mem.eql(u8, field, name)) {
                    const function = @field(definition.checks, field);
                    const Records = @typeInfo(@TypeOf(function)).@"fn".param_types[1].?;
                    if (Records == []const u8) return function(check, input.items);
                    const Record = std.meta.Child(Records);
                    var records: std.ArrayList(Record) = .empty;
                    var lines = std.mem.tokenizeScalar(u8, input.items, '\n');
                    while (lines.next()) |line| {
                        try records.append(arena, try std.json.parseFromSliceLeaky(Record, arena, line, .{
                            .ignore_unknown_fields = true,
                        }));
                    }
                    return function(check, records.items);
                }
            }
            return error.UnknownCheck;
        }

        fn run(
            init: std.process.Init,
            comptime definition: anytype,
            scenario_name: []const u8,
            command_name: []const u8,
        ) !void {
            var scenario: Scenario = undefined;
            if (!Self.scenario_build(definition, scenario_name, &scenario)) {
                return error.UnknownScenario;
            }
            const handler = scenario.find(command_name) orelse return error.UnknownCommand;
            const resolved = system_read(init.arena.allocator()) catch null;
            var context = Context{
                .nodes = try Self.nodes_load(init.arena.allocator()),
                .scenario = scenario_name,
                .profile = if (resolved) |system| system.profile else "default",
                .init = init,
            };
            return handler(&context);
        }

        fn scenario_build(
            comptime definition: anytype,
            name: []const u8,
            scenario: *Scenario,
        ) bool {
            inline for (comptime std.meta.fieldNames(@TypeOf(definition.scenarios))) |field| {
                if (std.mem.eql(u8, field, name)) {
                    scenario.* = .{ .name = field };
                    @field(definition.scenarios, field)(scenario);
                    return true;
                }
            }
            return false;
        }

        /// The nodes of the running system, from /det/system.json; outside determinismo every
        /// node is on localhost.
        fn nodes_load(arena: std.mem.Allocator) !Nodes {
            const resolved = system_read(arena) catch null;
            var nodes: Nodes = undefined;
            inline for (field_names, field_types) |name, Field| {
                const found: ?Node = if (resolved) |s| blk: {
                    const entry = s.node(name) orelse break :blk null;
                    break :blk .{ .name = name, .address = try address_parse(entry.address) };
                } else .{ .name = name, .address = .{ 127, 0, 0, 1 } };
                if (Field == Node) {
                    @field(nodes, name) = found orelse return error.NodeMissing;
                } else {
                    @field(nodes, name) = found;
                }
            }
            return nodes;
        }

        fn describe_print(
            arena: std.mem.Allocator,
            io: std.Io,
            comptime definition: anytype,
        ) !void {
            var d: Describe = .{};
            try definition.describe(&d);
            const profiles = try arena.alloc(schema.Profile, d.count);
            for (d.profiles[0..d.count], profiles) |*source, *target| {
                target.* = try Self.profile_convert(arena, source);
            }
            const scenario_names = comptime std.meta.fieldNames(@TypeOf(definition.scenarios));
            comptime for (scenario_names) |name| {
                // `--scenario all` explores every scenario: one named so would never run alone.
                if (std.mem.eql(u8, name, "all")) @compileError("a scenario cannot be named " ++
                    "\"all\": --scenario all explores every scenario");
            };
            var scenarios: [scenario_names.len]schema.Scenario = undefined;
            inline for (scenario_names, 0..) |name, index| {
                const scenario = try arena.create(Scenario);
                assert(Self.scenario_build(definition, name, scenario));
                const commands = try arena.alloc(schema.Command, scenario.count);
                for (scenario.commands[0..scenario.count], commands) |entry, *command| {
                    command.* = entry.command;
                }
                scenarios[index] = .{
                    .name = name,
                    .commands = commands,
                    .faults = scenario.faults,
                    .clock_skip = scenario.clock_skip,
                    .pacing = scenario.pacing,
                };
            }
            // The program's host checks, each with where its records are.
            const check_names = if (@hasField(@TypeOf(definition), "checks"))
                comptime std.meta.fieldNames(@TypeOf(definition.checks))
            else
                &[_][]const u8{};
            comptime assert(check_names.len <= schema.checks_max);
            var checks: [check_names.len]schema.Check = undefined;
            inline for (check_names, &checks) |name, *check| {
                check.* = .{ .name = name, .file = schema.record_path(name) };
            }
            const description = schema.Description{
                .profiles = profiles,
                .scenarios = &scenarios,
                .checks = &checks,
            };
            var buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
            const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
            try std.json.Stringify.value(description, options, &stdout.interface);
            try stdout.interface.writeAll("\n");
            try stdout.interface.flush();
        }

        fn profile_convert(arena: std.mem.Allocator, profile: *const Profile) !schema.Profile {
            var nodes: std.ArrayList(schema.Node) = .empty;
            inline for (field_names, field_types, 0..) |name, Field, index| {
                if (profile.specs[index]) |spec| {
                    const after = try arena.alloc([]const u8, spec.after.len);
                    for (spec.after, after) |dependency, *target| target.* = @tagName(dependency);
                    try nodes.append(arena, .{
                        .name = name,
                        .source = .{
                            .image = spec.image,
                            .directory = spec.directory,
                            .binary = spec.binary,
                            .build = spec.build,
                        },
                        .entrypoint = spec.entrypoint,
                        .command = spec.command,
                        .env = spec.env,
                        .workdir = spec.workdir,
                        .user = spec.user,
                        .ready = spec.ready,
                        .after = after,
                        .faults = spec.faults,
                        .memory_max_mib = spec.memory_max_mib,
                        .privileged = spec.privileged,
                        .ulimits = spec.ulimits,
                        .crashes_known = spec.crashes_known,
                        .writeback_s = spec.writeback_s,
                        .exits_known = spec.exits_known,
                        .spare = spec.spare,
                    });
                } else if (Field == Node) {
                    const message = "profile {s}: node {s} is not optional\n";
                    std.debug.print(message, .{ profile.name, name });
                    return error.NodeMissing;
                }
            }
            return .{ .name = profile.name, .nodes = nodes.items, .explain = profile.explain };
        }
    };
}

fn system_read(arena: std.mem.Allocator) !schema.System {
    const fd = linux.open("/det/system.json", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoSystem;
    defer _ = linux.close(@intCast(fd));
    const buffer = try arena.alloc(u8, system_size_max);
    var size: u64 = 0;
    while (size < buffer.len) {
        const result = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) break;
        size += result;
    }
    return schema.parse(schema.System, arena, buffer[0..size]);
}

fn address_parse(text: []const u8) ![4]u8 {
    var address: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&address) |*byte| {
        byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10);
    }
    if (parts.next() != null) return error.BadAddress;
    return address;
}

const exec_arguments_max = 32;
const argument_size_max = 1024;

fn nodes_command(arguments: []const []const u8) !void {
    if ((try nodes_run(arguments, null)).status != 0) return error.NodeCommandFailed;
}

/// Runs det-nodes with `arguments`; returns its exit status, and its standard output when
/// `capture` is given.
fn nodes_run(arguments: []const []const u8, capture: ?[]u8) !Output {
    assert(arguments.len + 1 <= exec_arguments_max);
    var storage: [exec_arguments_max][argument_size_max]u8 = undefined;
    var argv: [exec_arguments_max:null]?[*:0]const u8 = @splat(null);
    argv[0] = nodes_binary;
    for (arguments, 1..) |argument, index| {
        argv[index] = try std.fmt.bufPrintSentinel(&storage[index], "{s}", .{argument}, 0);
    }
    const environment = [_:null]?[*:0]const u8{"PATH=/opt/determinismo/bin:/usr/bin:/bin"};
    var pipe: [2]linux.fd_t = .{ -1, -1 };
    if (capture != null) {
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        if (capture != null) _ = linux.dup2(pipe[1], 1);
        _ = linux.execve(nodes_binary, &argv, &environment);
        linux.exit_group(127);
    }
    var size: usize = 0;
    if (capture) |buffer| {
        _ = linux.close(pipe[1]);
        defer _ = linux.close(pipe[0]);
        var drain: [4096]u8 = undefined;
        while (true) {
            const target = if (size < buffer.len) buffer[size..] else drain[0..];
            const result = linux.read(pipe[0], target.ptr, target.len);
            if (linux.errno(result) != .SUCCESS or result == 0) break;
            if (size < buffer.len) size += result;
        }
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    const bits: u32 = @bitCast(status);
    const code: u8 = if (bits & 0x7f == 0)
        @intCast((bits >> 8) & 0xff)
    else
        @intCast(128 + (bits & 0x7f));
    return .{ .status = code, .output = if (capture) |buffer| buffer[0..size] else "" };
}

test "scenarios and profiles are typed" {
    const Nodes = struct { redis: Node, cache: ?Node };
    const S = System(Nodes);
    const handlers = struct {
        fn noop(_: *S.Context) !void {}
        fn bank(s: *S.Scenario) void {
            s.setup("accounts", noop);
            s.parallel_driver("transfer", noop);
        }
    };
    var scenario: S.Scenario = undefined;
    const definition = .{ .describe = undefined, .scenarios = .{ .bank = handlers.bank } };
    try std.testing.expect(S.scenario_build(definition, "bank", &scenario));
    try std.testing.expectEqual(@as(u32, 2), scenario.count);
    try std.testing.expect(scenario.find("transfer") != null);
    var describe: S.Describe = .{};
    const profile = try describe.profile("default");
    profile.node(.redis, .{ .image = "redis:7", .after = &.{.cache} });
    try std.testing.expect(profile.specs[1] == null);
}
