// SPDX-License-Identifier: MIT
//! One single-vCPU KVM virtual machine: memfd-backed RAM, legacy devices and the run loop.
//!
//! In deterministic mode (ARCHITECTURE.md §4) guest time is a function of retired guest branches:
//! the patched KVM returns tsc = base + branches * tsc_per_branch for RDTSC and stops the vCPU at
//! exact branch counts. The VMM owns the only timer (the PIT), fires it at the branch count where
//! its deadline falls, and skips idle time when the guest halts.
const std = @import("std");
const guest_memory = @import("guest_memory.zig");
const GuestMemory = guest_memory.GuestMemory;
const assert = std.debug.assert;
const linux = std.os.linux;
const kvm = @import("kvm.zig");
const boot = @import("boot.zig");
const cpuid = @import("cpuid.zig");
const Serial = @import("serial.zig");
const RTC = @import("rtc.zig");
const PIT = @import("pit.zig");
const VirtioBlock = @import("virtio_block.zig");
const Decisions = @import("decisions.zig");
const Events = @import("events.zig");
const query = @import("query.zig");
const Snapshot = @import("snapshot.zig");
const Strategy = @import("strategy.zig");
const tape = @import("tape.zig");
const host_checks = @import("checks.zig");
const schema = @import("determinismo").schema;

kvm_fd: linux.fd_t,
vm_fd: linux.fd_t,
vcpu_fd: linux.fd_t,
memory_fd: linux.fd_t,
/// False for branches: their memory_fd belongs to the snapshot they map copy-on-write.
memory_fd_owned: bool,
memory: []align(std.heap.page_size_min) u8,
run: *kvm.Run,
run_size: u64,
/// Set once a snapshot shares this VM's memory: it must never run again.
frozen: bool,
/// Branches restored from a snapshot count branches from zero; this makes moments absolute.
branches_offset: u64,
/// Stop the run when the guest signals setup_complete (to snapshot there).
stop_at_setup_complete: bool,
/// A timeline's ceiling of virtual time (TSC): past it, at the next timer interrupt (an exact
/// point, the same in a replay), the run ends as hung.
vtime_limit_tsc: ?u64,
/// The timer interrupt past the ceiling fired.
over_limit: bool,
/// Multiverse debugging: the moment (virtual TSC) to stop at, the command to run there, and
/// where that stands. Without a command the run ends at the moment.
moment_tsc: ?u64,
moment_command: ?[]const u8,
moment_reached: bool,
/// Keep running after the command at the moment finished (instead of ending the run there).
moment_continue: bool,
fresh_seed: ?u64,
/// The moment can also be the first event matching a condition (`--until`, as Antithesis's
/// wait_until), the instant the guest emits it.
until: ?*const query.Condition,
until_hit: bool,
/// Whether guest events are printed: from the moment until its command finishes.
moment_printing: bool,
/// What the guest agent receives on its next action request.
action_pending: ?[]const u8,
/// Room for a branch point's action (branch_action_make).
branch_action_buffer: [64]u8 = undefined,
/// The moment's commands after the one running: a moment command can be several, separated by
/// NUL bytes (which no argument can contain), run one after the other (`--exec-script`).
moment_commands_rest: []const u8,
/// A labeled decision (`{"decision": {...}}` from the SDK's `decide`): the label of the next
/// randomness pull of the process that announced it, sent to the strategy with that pull.
decision_label: [decision_label_size_max]u8,
decision_label_size: u32,
decision_source: [source_size_max]u8,
decision_source_size: u32,
/// The event count at the last exec_done handled: later doorbells (with no event) keep exec_done
/// as the last event, and must not finish the next command.
exec_done_handled: u64,
/// The last guest event was a background command's (det-agent's det:background): its start ends
/// its step, its end ends none.
exec_background: bool = false,
/// A step of the moment's script that is the platform's, not the guest's, is under way
/// (`det:wait <ms>`, `det:until <ms> <condition>`: multiverse debugging's branch.wait and
/// wait_until): its end is a moment again (moment_arrive), and the next step follows.
stepping: bool = false,
/// The conditions of `det:until` steps.
step_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
/// What the armed branch-count target is for.
target_kind: Deadline.Kind,
/// An in-run snapshot point (main.zig's holders): virtual time (TSC) where the run pauses for
/// `hold` and goes on. It stops where a replay to that moment stops (an exact branch count,
/// or within an idle skip), and the guest cannot tell: the timeline is the same as without it.
hold_tsc: ?u64,
hold: ?*const Hold,
/// Behaviors the hold's owner was told of (Hold.behaviors).
hold_behaviors: u32,
/// Restored from a hold point inside an idle skip (Options.from_hold): the skip goes on first.
idle_pending: bool,
deterministic: bool,
builtin_properties: bool,
checks: []const schema.Check,
check_program: ?[]const u8,
check_scenario: []const u8,
tsc_per_branch: u32,
/// CPU modulation, in branches only (Options.cpu_modulation).
modulation: ?Modulation,
timer_slack_tsc: u64,
serial: Serial,
rtc: RTC,
pit: PIT,
/// Read-only disks, one virtio-mmio slot each (see virtio_block.zig).
blocks: [disks_max]VirtioBlock,
block_count: u32,
/// Branch count at which KVM stops the vCPU for the PIT deadline (0: none).
target_branches: u64,
/// The clock's state at this exit, read once (DET_GET_STATE, an ioctl, read up to five times
/// an exit before): it changes only as the guest runs or the VMM adds time (DET_ADD_TSC,
/// DET_ENABLE), which clear it.
state_cached: ?kvm.DetState = null,
/// The armed soft stop (a clock reading, timer_arm), 0 for none.
soft_tsc: u64,
decisions: Decisions,
/// A moment at or before the timeline's last randomness pull (the latest event's then: no clock
/// read on the pull's path). Past the last pull its future is fixed: every timeline branched
/// there would be the same one, so the tree explorer branches before it.
last_pull_ns: u64,
events: Events,
stats: Stats,
/// Optional text trace of every point where the VMM changes the guest's course: timer stops,
/// idle skips and guest requests, each with branch count and RIP. Diffing two traces finds the
/// first divergence of two runs.
trace_fd: ?linux.fd_t,
/// The faults the timeline went through (det-faults' fault events), one JSON line each: what
/// causality relates to its futures' failures.
faults_record_fd: ?linux.fd_t,
rdtsc_log_fd: ?linux.fd_t,
rdtsc_log_cap: u32,
itrace_fd: ?linux.fd_t,
itrace_at: u64,
/// Exploration hooks, attached by the caller between init and run (null when not exploring):
/// the plugin that may override decisions, the tape recording what it overrode, and a tape's
/// overrides when replaying one.
strategy: ?*Strategy,
tape_fd: ?linux.fd_t,
overrides: ?*tape.Overrides,

pub const Options = struct {
    memory_size: u64,
    kernel: []const u8,
    initrd: ?[]const u8,
    cmdline: []const u8,
    /// Unix seconds the guest's real-time clock reads at virtual time zero.
    epoch_seconds: u64 = 1767225600, // 2026-01-01T00:00:00Z
    deterministic: bool,
    /// Raw PMU event counting retired conditional branches (Skylake: BR_INST_RETIRED.CONDITIONAL).
    branch_event: u64 = 0x01c4,
    /// 8 TSC ticks per branch at 4 GHz: one branch is 2 ns of virtual time.
    tsc_per_branch: u32 = 8,
    /// Branches before a stop target where KVM starts single-stepping (must exceed PMI skid:
    /// up to 65 branches on srv3's W-2295 under YugabyteDB; at 64, one stop overshot, and its
    /// timeline was another).
    margin_branches: u32 = 128,
    /// How late a timer interrupt may be: it is delivered at the first RDTSC at or past its
    /// deadline (free), or exactly this much later (single-stepping) if the guest reads no
    /// clock meanwhile. Part of a timeline's inputs. A millisecond, as a loaded host delays
    /// timers: a busy YugabyteDB guest ran at 0.99x virtual time with it, 0.62x with 100 us
    /// (fewer interrupts, timers due together firing at once, fewer exact stops; srv3).
    timer_slack_ns: u64 = std.time.ns_per_ms,
    /// Root of all guest randomness: seeds the guest kernel's RNG at boot and answers every
    /// randomness pull from /dev/determinismo.
    seed: u64,
    /// Where to append the guest's events as JSON lines.
    events_fd: ?linux.fd_t,
    /// Where to append its fault events only (causality's futures: `--faults-record`).
    faults_record_fd: ?linux.fd_t = null,
    /// Scratch memory for parsing guest events, reserved once by the caller (see events.zig).
    events_parse_buffer: []u8,
    trace_fd: ?linux.fd_t = null,
    /// Debugging: where the (branch count, RIP) at each RDTSC exit goes when the VM ends.
    rdtsc_log_fd: ?linux.fd_t = null,
    rdtsc_log_cap: u32 = rdtsc_log_cap_default,
    /// Debugging: every instruction's (branch count, RIP) from the RDTSC exit numbered
    /// `itrace_at` to the next, single-stepped (where two runs part, which branch went another
    /// way), written here when the VM ends.
    itrace_fd: ?linux.fd_t = null,
    itrace_at: u64 = 0,
    stop_at_setup_complete: bool = false,
    /// Stop at this virtual time, and optionally run a command in the guest there.
    moment_vtime_ns: ?u64 = null,
    moment_command: ?[]const u8 = null,
    /// After the command at the moment, run on to the end of the timeline.
    moment_continue: bool = false,
    /// From the moment on, decisions from this seed and no tape: the branch's own future (the
    /// guest's agent reseeds the kernel's generator first: det:reseed).
    fresh_seed: ?u64 = null,
    /// The run begins at a branch point (init_from_snapshot of a node: a moment of another
    /// timeline): the guest agent hears of it before the guest runs again (det:branch), and the
    /// fault injector perturbs the branch at once (guest/runtime/faults.zig). Every run from a
    /// node has it, timelines and the replays that make nodes alike: the same machine either way.
    branch_signal: bool = false,
    /// Or the moment is the first event matching this condition.
    until: ?*const query.Condition = null,
    disks: []const Disk = &.{},
    /// The guest runs determinismo's runtime: check the built-in properties when a timeline ends.
    builtin_properties: bool = false,
    /// The test program's host checks (checks.zig), run on what each timeline recorded, by the
    /// program itself in the scenario's name; and room for their inputs, reserved once.
    checks: []const schema.Check = &.{},
    check_program: ?[]const u8 = null,
    check_scenario: []const u8 = "",
    check_buffer: []u8 = &.{},
    /// Antithesis's CPU modulation: branches run slower for stretches of virtual time, each
    /// stretch's speed a decision, so preemption lands at other points of the code.
    cpu_modulation: bool = false,
    /// Retroactive logging: output lines with one of these texts are not written to the events
    /// file (they still count: hash, behaviors, the logging limit); a replay writes them.
    retroactive: []const []const u8 = &.{},
    /// A timeline's ceiling of virtual time: a guest that never finishes (processes wedged, a
    /// command waiting forever) ends there as hung.
    vtime_limit_ns: ?u64 = null,
    /// The snapshot is a hold point (a holder's, holders.zig) of the timeline this run replays
    /// on: it goes on as the timeline did there. Inside an idle skip the guest stays halted and
    /// the skip goes on (resuming the guest would run its idle loop once more), and the CPU
    /// modulation keeps its speed and owed time. Nodes and branches start over instead.
    from_hold: ?Hold.Point = null,
};

/// The machine runs `slowdown_permille` thousandths slower than its base rate (each branch
/// takes that much more virtual time) until `change_tsc`, when the next speed is drawn. The extra
/// time is added at exits the guest's execution decides (I/O, stops, halts), never at a host
/// interrupt, so that the guest reads the same clock on every replay.
pub const Modulation = struct {
    slowdown_permille: u32 = 0,
    /// Branches whose extra time is added.
    branches: u64 = 0,
    /// Extra time not yet added, in thousandths of a tick.
    remainder: u64 = 0,
    change_tsc: u64 = 0,

    /// The extra time owed for the branches since the last exit, in thousandths of a tick.
    fn owed_milli(modulation: Modulation, branches: u64, tsc_per_branch: u32) u64 {
        assert(branches >= modulation.branches);
        return (branches - modulation.branches) * tsc_per_branch *
            modulation.slowdown_permille + modulation.remainder;
    }

    /// The same modulation, for a machine whose branch count starts over (a snapshot's).
    pub fn rebased(modulation: Modulation, branches: u64, tsc_per_branch: u32) Modulation {
        var moved = modulation;
        moved.remainder = modulation.owed_milli(branches, tsc_per_branch);
        moved.branches = 0;
        return moved;
    }
};

/// Bumped whenever virtual time under CPU modulation changes (a modulated timeline's inputs
/// hash it; determinism_abi covers every timeline). 2: owed time counts in timer targets, and
/// moments and hold points do not step the modulation.
pub const modulation_version: u32 = 2;
const modulation_permille_max = 1000; // Twice as slow at most.
const modulation_stretch_ns_min = 10 * std.time.ns_per_ms;
const modulation_stretch_ns_max = 200 * std.time.ns_per_ms;

/// A read-only disk image, open for the whole process (branches share it).
pub const Disk = struct { fd: linux.fd_t, size: u64 };
pub const disks_max = 16;

pub const Outcome = union(enum) {
    shutdown, // A triple fault: how the guest reboots with reboot=t.
    setup_complete, // Only with Options.stop_at_setup_complete.
    moment_reached, // Only with Options.moment_vtime_ns and no command.
    hung, // Past Options.vtime_limit_ns without finishing.
    command_done, // Only with Options.moment_command: the command at the moment finished.
    debug_exit: u8,
    hlt,
    failed: []const u8,
};

pub const Stats = struct {
    exits: std.EnumArray(Kind, u64) = .initFill(0),
    io_ports: [65536]u32 = @splat(0),
    timer_fires: u64 = 0,
    /// Timer interrupts delivered at a port or MMIO exit (see timer_due).
    exit_timer_fires: u64 = 0,
    idle_skips: u64 = 0,
    idle_tsc: u64 = 0,

    pub const Kind = enum { io_serial, io_other, mmio, hlt, intr, det_target, other };
};

const VM = @This();

/// The determinism ABI: bumped whenever the virtual-time function or the semantics of exits
/// and stops change, so that timelines recorded under one are never replayed under another.
pub const determinism_abi: u32 = 1;

/// Kernel parameters the deterministic machine needs: the PIT is the only clock-event device, the
/// TSC (virtualized by KVM) the only clocksource, and the boot seed the RNG's only entropy. No
/// I/O delay: the dummy write to port 0x80 after each slow port access (the PIT's, the PIC's,
/// on every timer tick) only waits on real hardware, and here each was an exit to the VMM: a
/// quarter of a busy YugabyteDB guest's (75,000 in 6 s, srv3 2026-10-27). And a PIT count in
/// one 16-bit write, not two (the guest kernel's det_pit_word, guest/kernel/patches): one exit
/// per timer reprogram.
pub const cmdline_deterministic = "nolapic_timer hpet=disable clocksource=tsc tsc=reliable " ++
    "random.trust_bootloader=on random.trust_cpu=off io_delay=none det_pit_word=1";

/// QEMU's isa-debug-exit convention: a guest write of v to this port ends the run with status v.
pub const port_debug_exit: u16 = 0x501;
/// The guest module writes the physical address of a request page here.
pub const port_doorbell: u16 = 0x510;
const request_operation_emit: u32 = 1;
const request_operation_random: u32 = 2;
const request_operation_action: u32 = 3;
/// The guest module wakes its agent on this ISA interrupt when an action is pending.
const irq_action: u32 = 5;
const request_header_size = 16;
const page_size = 4096;
/// Guest RAM, reserved lazily (a branch costs what it touches).
pub const memory_size_max: u64 = 32 << 30;
const cpuid_entries_max = 256;

/// A fresh machine that boots the kernel in `options`.
pub fn init(vm: *VM, options: *const Options) !void {
    try vm.init_machine(options);
    try vm.init_memory_fresh(options.memory_size);
    try vm.init_vcpu();
    try vm.init_boot(options);
    if (options.deterministic) try vm.det_enable(options, .{ .tsc_base = 0 });
    assert(!vm.frozen);
}

/// A branch: a machine that continues from `snapshot`, with its own decisions from now on.
pub fn init_from_snapshot(vm: *VM, options: *const Options, snapshot: *const Snapshot) !void {
    assert(options.deterministic);
    assert(options.memory_size == snapshot.memory_size);
    try vm.init_machine(options);
    try vm.init_memory_private(snapshot.memory_fd, snapshot.memory_size);
    try vm.init_vcpu();
    try snapshot.restore(vm);
    try vm.det_enable(options, .{ .tsc_base = snapshot.tsc });
    var xinuse = snapshot.xinuse;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_SET_XINUSE, @intFromPtr(&xinuse));
    if (options.cpu_modulation) {
        vm.modulation = if (options.from_hold != null) snapshot.modulation.? else .{};
    }
    vm.events.log_fd = options.events_fd;
    vm.faults_record_fd = options.faults_record_fd;
    vm.events.retroactive = options.retroactive;
    vm.decisions = .{ .seed = options.seed, .pulls = snapshot.decisions.pulls };
    vm.last_pull_ns = 0;
    vm.idle_pending = if (options.from_hold) |point| point.idle else false;
    assert(vm.branches_offset == snapshot.branches);
    if (options.branch_signal) {
        assert(options.from_hold == null); // A holder continues its own timeline.
        vm.action_pending = vm.branch_action_make(snapshot);
        try vm.irq_pulse(irq_action);
    }
}

/// The agent's action at a branch point (guest/runtime/agent.zig): `det:branch`, and the node of
/// the newest behavior the snapshot reached (the one the tree returned for, just before its
/// moment), where the fault injector aims its first fault. From the snapshot's own state: a
/// replay that makes the node says the same.
const branch_action = "det:branch";

fn branch_action_make(vm: *VM, snapshot: *const Snapshot) []const u8 {
    const behaviors = snapshot.events.behaviors[0..snapshot.events.behavior_count];
    var newest: ?*const Events.Behavior = null;
    for (behaviors) |*behavior| {
        if (behavior.node_size == 0) continue;
        if (newest == null or behavior.vtime_ns >= newest.?.vtime_ns) newest = behavior;
    }
    const node = if (newest) |behavior| behavior.node() else return branch_action;
    return std.fmt.bufPrint(&vm.branch_action_buffer, branch_action ++ " {s}", .{node}) catch branch_action;
}

pub fn deinit(vm: *VM) void {
    vm.serial.flush();
    vm.rdtsc_log_write();
    _ = linux.munmap(@ptrCast(vm.run), vm.run_size);
    _ = linux.close(vm.vcpu_fd);
    _ = linux.munmap(vm.memory.ptr, vm.memory.len);
    // A snapshot keeps the memfd of the VM it froze, and branches never own theirs.
    if (vm.memory_fd_owned and !vm.frozen) _ = linux.close(vm.memory_fd);
    _ = linux.close(vm.vm_fd);
    _ = linux.close(vm.kvm_fd);
    vm.* = undefined;
}

fn init_machine(vm: *VM, options: *const Options) !void {
    assert(options.memory_size % page_size == 0);
    assert(options.tsc_per_branch > 0);
    vm.* = .{
        .kvm_fd = try open_kvm(),
        .vm_fd = undefined,
        .vcpu_fd = undefined,
        .memory_fd = undefined,
        .memory_fd_owned = undefined,
        .memory = undefined,
        .run = undefined,
        .run_size = undefined,
        .frozen = false,
        .branches_offset = 0,
        .stop_at_setup_complete = options.stop_at_setup_complete,
        .vtime_limit_tsc = if (options.vtime_limit_ns) |ns| ns * tsc_per_ns else null,
        .over_limit = false,
        .moment_tsc = if (options.moment_vtime_ns) |ns| ns * tsc_per_ns else null,
        .moment_command = options.moment_command,
        .moment_reached = false,
        .moment_continue = options.moment_continue,
        .fresh_seed = options.fresh_seed,
        .until = options.until,
        .until_hit = false,
        .moment_printing = false,
        .action_pending = null,
        .moment_commands_rest = "",
        .decision_label = undefined,
        .decision_label_size = 0,
        .decision_source = undefined,
        .decision_source_size = 0,
        .exec_done_handled = 0,
        .target_kind = .timer,
        .hold_tsc = null,
        .hold = null,
        .hold_behaviors = 0,
        .idle_pending = false,
        .deterministic = options.deterministic,
        .builtin_properties = options.builtin_properties,
        .checks = options.checks,
        .check_program = options.check_program,
        .check_scenario = options.check_scenario,
        .tsc_per_branch = options.tsc_per_branch,
        .modulation = null,
        .timer_slack_tsc = options.timer_slack_ns * tsc_per_ns,
        .serial = .{},
        .rtc = .{ .epoch_seconds = options.epoch_seconds },
        .pit = .{ .tsc_hz = cpuid.tsc_hz },
        .blocks = undefined,
        .block_count = @intCast(options.disks.len),
        .target_branches = 0,
        .soft_tsc = 0,
        .decisions = .{ .seed = options.seed },
        .last_pull_ns = 0,
        .events = undefined,
        .stats = .{},
        .trace_fd = options.trace_fd,
        .faults_record_fd = options.faults_record_fd,
        .rdtsc_log_fd = options.rdtsc_log_fd,
        .rdtsc_log_cap = options.rdtsc_log_cap,
        .itrace_fd = options.itrace_fd,
        .itrace_at = options.itrace_at,
        .strategy = null,
        .tape_fd = null,
        .overrides = null,
    };
    vm.events.init(options.events_parse_buffer, .{
        .log_fd = options.events_fd,
        .check_buffer = options.check_buffer,
    });
    vm.events.retroactive = options.retroactive;
    if (options.disks.len > disks_max) return error.TooManyDisks;
    for (options.disks, vm.blocks[0..options.disks.len]) |disk, *block| {
        block.init(disk.fd, disk.size);
    }
    const version = try kvm.ioctl(vm.kvm_fd, kvm.GET_API_VERSION, 0);
    if (version != kvm.api_version) return error.KVMVersion;
    vm.vm_fd = try kvm.ioctl_fd(vm.kvm_fd, kvm.CREATE_VM, 0);
    try vm.init_chipset();
}

fn init_vcpu(vm: *VM) !void {
    vm.vcpu_fd = try kvm.ioctl_fd(vm.vm_fd, kvm.CREATE_VCPU, 0);
    vm.run_size = try kvm.ioctl(vm.kvm_fd, kvm.GET_VCPU_MMAP_SIZE, 0);
    assert(vm.run_size >= @sizeOf(kvm.Run));
    const protection: linux.PROT = .{ .READ = true, .WRITE = true };
    const run_address = try syscall(linux.mmap(null, vm.run_size, protection, .{
        .TYPE = .SHARED,
    }, vm.vcpu_fd, 0));
    vm.run = @ptrFromInt(run_address);
    // Not in forked children (holders.zig): the mapping keeps the vCPU, so its VM and its pinned
    // branch counter, alive after this process ends the machine. The counter is bound to this
    // process: once the hardware's counters are all taken by machines gone, a new machine's does
    // not count, and its timeline is no longer deterministic.
    _ = try syscall(linux.madvise(@ptrCast(vm.run), vm.run_size, linux.MADV.DONTFORK));
    try vm.init_cpuid();
}

fn det_enable(vm: *VM, options: *const Options, start: struct { tsc_base: u64 }) !void {
    assert(vm.deterministic);
    var config = kvm.DetConfig{
        .event = options.branch_event,
        .tsc_base = start.tsc_base,
        .tsc_per_branch = options.tsc_per_branch,
        .margin_branches = options.margin_branches,
    };
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ENABLE, @intFromPtr(&config));
    vm.state_cached = null;
    assert((try vm.det_state()).tsc == start.tsc_base);
    try vm.rdtsc_log_enable();
}

fn init_chipset(vm: *VM) !void {
    assert(vm.vm_fd >= 0);
    _ = try kvm.ioctl(vm.vm_fd, kvm.SET_TSS_ADDR, 0xfffbd000);
    var identity_map_address: u64 = 0xfffbc000;
    _ = try kvm.ioctl(vm.vm_fd, kvm.SET_IDENTITY_MAP_ADDR, @intFromPtr(&identity_map_address));
    _ = try kvm.ioctl(vm.vm_fd, kvm.CREATE_IRQCHIP, 0);
    if (vm.deterministic) {
        // The VMM's PIT is the only timer: KVM's would run on host time.
    } else {
        var pit_config = kvm.PitConfig{ .flags = kvm.pit_speaker_dummy };
        _ = try kvm.ioctl(vm.vm_fd, kvm.CREATE_PIT2, @intFromPtr(&pit_config));
    }
}

/// Guest RAM lives in a memfd so that snapshots can map it copy-on-write.
fn init_memory_fresh(vm: *VM, memory_size: u64) !void {
    assert(memory_size >= 64 << 20);
    assert(memory_size <= memory_size_max);
    vm.memory_fd = @intCast(try syscall(linux.memfd_create("guest-ram", 0)));
    vm.memory_fd_owned = true;
    _ = try syscall(linux.ftruncate(vm.memory_fd, @intCast(memory_size)));
    try vm.init_memory_map(.SHARED, memory_size);
}

/// A branch writes to private copies of the snapshot's pages, which stays untouched.
fn init_memory_private(vm: *VM, snapshot_memory_fd: linux.fd_t, memory_size: u64) !void {
    assert(snapshot_memory_fd >= 0);
    vm.memory_fd = snapshot_memory_fd;
    vm.memory_fd_owned = false;
    try vm.init_memory_map(.PRIVATE, memory_size);
}

fn init_memory_map(vm: *VM, sharing: linux.MAP_TYPE, memory_size: u64) !void {
    assert(memory_size % page_size == 0);
    const protection: linux.PROT = .{ .READ = true, .WRITE = true };
    const address = try syscall(linux.mmap(null, memory_size, protection, .{
        .TYPE = sharing,
        .NORESERVE = true,
    }, vm.memory_fd, 0));
    vm.memory = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(address))[0..memory_size];
    // One mapping, two guest ranges: below the 32-bit hole, and from 4 GiB (GuestMemory).
    const guest = GuestMemory{ .bytes = vm.memory };
    var regions = [_]kvm.UserspaceMemoryRegion{
        .{
            .slot = 0,
            .flags = 0,
            .guest_phys_addr = 0,
            .memory_size = guest.low_size(),
            .userspace_addr = address,
        },
        .{
            .slot = 1,
            .flags = 0,
            .guest_phys_addr = guest_memory.high_start,
            .memory_size = guest.high_size(),
            .userspace_addr = address + guest.low_size(),
        },
    };
    for (&regions) |*region| {
        if (region.memory_size == 0) continue;
        _ = try kvm.ioctl(vm.vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(region));
    }
}

fn init_cpuid(vm: *VM) !void {
    var cpuid_table: kvm.Cpuid2(cpuid_entries_max) = .{
        .count = cpuid_entries_max - 2, // Room for the leaves make_deterministic appends.
        .entries = undefined,
    };
    _ = try kvm.ioctl(vm.kvm_fd, kvm.GET_SUPPORTED_CPUID, @intFromPtr(&cpuid_table));
    assert(cpuid_table.count <= cpuid_entries_max - 2);
    if (vm.deterministic) cpuid.make_deterministic(&cpuid_table.entries, &cpuid_table.count);
    assert(cpuid_table.count <= cpuid_entries_max);
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_CPUID2, @intFromPtr(&cpuid_table));
}

fn init_boot(vm: *VM, options: *const Options) !void {
    var boot_options = boot.Options{
        .kernel = options.kernel,
        .initrd = options.initrd,
        .cmdline = options.cmdline,
        .rng_seed = undefined,
    };
    var prng: std.Random.DefaultPrng = .init(options.seed);
    prng.random().bytes(&boot_options.rng_seed);
    const entry = try boot.load(.{ .bytes = vm.memory }, &boot_options);
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_SREGS, @intFromPtr(&sregs));
    boot.long_mode_sregs(&sregs);
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_SREGS, @intFromPtr(&sregs));
    var regs = kvm.Regs{
        .rflags = 0x2,
        .rip = entry.rip,
        .rsi = entry.rsi,
        .rsp = boot.stack_top_address,
        .rbp = boot.stack_top_address,
    };
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_REGS, @intFromPtr(&regs));
}

/// Runs the VM until it powers off, reboots, fails or reaches a requested stop; then checks the
/// built-in properties of a timeline that ended (not of one stopped at setup or at a moment).
pub fn run_until_exit(vm: *VM) !Outcome {
    const outcome = try vm.run_loop();
    if (vm.builtin_properties and outcome != .setup_complete) {
        const cut_short = outcome == .moment_reached or outcome == .command_done;
        const end = try vm.moment();
        if (!cut_short) if (vm.check_program) |program| {
            try host_checks.run(&vm.events, end, vm.checks, .{
                .program = program,
                .scenario = vm.check_scenario,
            });
        };
        try vm.events.finish(end, if (cut_short) .cut_short else .ended);
    }
    return outcome;
}

/// The VM's event loop: it ends only when the guest powers off, reboots or fails.
fn run_loop(vm: *VM) !Outcome {
    assert(!vm.frozen);
    defer vm.serial.flush();
    while (true) {
        if (vm.over_limit) return .hung;
        if (vm.idle_pending) {
            vm.idle_pending = false;
            if (try vm.idle()) |outcome| return outcome;
            continue;
        }
        if (vm.deterministic) try vm.timer_arm();
        vm.state_cached = null; // The guest runs.
        _ = kvm.ioctl(vm.vcpu_fd, kvm.RUN, 0) catch |err| switch (err) {
            error.Interrupted => {
                vm.stats.exits.getPtr(.intr).* += 1;
                continue;
            },
            else => return err,
        };
        // At the guest's own exits: a moment's or a hold point's stop is not one (a timeline
        // without that stop has no exit there).
        switch (vm.run.exit_reason) {
            .io, .mmio, .hlt => try vm.modulate(),
            .det_target => if (vm.target_kind == .timer or try vm.soft_stopped()) try vm.modulate(),
            else => {},
        }
        switch (vm.run.exit_reason) {
            .io => {
                if (try vm.handle_io()) |outcome| return outcome;
                try vm.timer_due();
                try vm.hold_notice();
            },
            .mmio => {
                try vm.handle_mmio();
                try vm.timer_due();
            },
            .det_target => {
                assert(vm.deterministic);
                vm.stats.exits.getPtr(.det_target).* += 1;
                // The timer's soft stop while a hold point or a moment is the target.
                if (vm.target_kind != .timer and try vm.soft_stopped()) {
                    try vm.target_set(0); // Re-armed next loop.
                    if (vm.pit.armed) try vm.timer_fire();
                    continue;
                }
                switch (vm.target_kind) {
                    .moment => {
                        vm.target_branches = 0;
                        if (try vm.moment_arrive()) |outcome| return outcome;
                    },
                    .hold => {
                        vm.target_branches = 0;
                        try vm.hold_reach(.{ .idle = false });
                    },
                    .timer => {
                        try vm.target_set(0); // A soft stop leaves the hard one armed.
                        if (vm.pit.armed) try vm.timer_fire();
                    },
                }
            },
            .hlt => {
                vm.stats.exits.getPtr(.hlt).* += 1;
                if (!vm.deterministic) return .hlt;
                if (try vm.idle()) |outcome| return outcome;
            },
            .shutdown => return .shutdown,
            .intr => vm.stats.exits.getPtr(.intr).* += 1,
            .fail_entry => return .{ .failed = "VM entry failed" },
            .internal_error => return .{ .failed = "KVM internal error" },
            else => {
                vm.stats.exits.getPtr(.other).* += 1;
                std.log.warn("unhandled exit {d}", .{@backingInt(vm.run.exit_reason)});
                return .{ .failed = "unhandled exit" };
            },
        }
    }
    comptime unreachable;
}

pub fn det_state(vm: *VM) !kvm.DetState {
    assert(vm.deterministic);
    if (vm.state_cached) |state| return state;
    var state: kvm.DetState = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_GET_STATE, @intFromPtr(&state));
    assert(state.tsc >= state.branches * vm.tsc_per_branch);
    vm.state_cached = state;
    return state;
}

const Deadline = struct {
    tsc: u64,
    kind: Kind,

    const Kind = enum {
        timer,
        moment,
        hold,

        /// Moments and hold points stop at their exact branch count; timers have slack.
        fn exact(kind: Kind) bool {
            return kind != .timer;
        }
    };
};
const tsc_per_ns = cpuid.tsc_hz / std.time.ns_per_s;

/// The next thing the VMM must do at a precise moment: fire the PIT, reach the moment, or pause
/// at a hold point. The earliest; at the same time the moment, then the timer: a timer may fire
/// at a clock read past its deadline, and a hold point stopping first would move it.
fn deadline_next(vm: *const VM) ?Deadline {
    const timer: ?Deadline = if (vm.pit.deadline_tsc()) |tsc| .{
        .tsc = tsc,
        .kind = .timer,
    } else null;
    const stop: ?Deadline = if (vm.moment_reached) null else if (vm.moment_tsc) |tsc| .{
        .tsc = tsc,
        .kind = .moment,
    } else null;
    const hold: ?Deadline = if (vm.hold_tsc) |tsc| .{
        .tsc = tsc,
        .kind = .hold,
    } else null;
    var next: ?Deadline = null;
    for ([_]?Deadline{ stop, timer, hold }) |candidate| {
        const deadline = candidate orelse continue;
        if (next == null or deadline.tsc < next.?.tsc) next = deadline;
    }
    return next;
}

/// Asks KVM to stop the vCPU at the next deadline. A moment stops at its exact branch count, and
/// so does a hold point. A timer stops at the first RDTSC at or past its deadline (a soft stop,
/// free), or at most `timer_slack` later at an exact branch count (a hard stop, which costs
/// single-stepping): both are exact points of the guest's execution, so replays deliver it at
/// the same place. A hold point or a moment within a timer's slack is the target, and the timer
/// keeps its soft stop and then its hard one: the timer fires where a timeline without the hold
/// point fires it (passing it, the hold point was dropped: a causality replay with a 1 ms slack
/// saved 3 of 5 moments).
fn timer_arm(vm: *VM) !void {
    assert(vm.deterministic);
    if (vm.target_branches != 0) return;
    const state = try vm.det_state();
    // Virtual time in thousandths of a tick: the guest's clock and what the CPU modulation owes
    // it (added at the next exit). It grows by per_branch a branch, so a stop computed from it
    // is the same wherever it is computed: at a hold point as at the exit before it.
    const owed_milli = if (vm.modulation) |m|
        m.owed_milli(state.branches, vm.tsc_per_branch)
    else
        0;
    const now_milli = state.tsc * 1000 + owed_milli;
    // The next exact deadline, past ones dealt with.
    const exact: ?Deadline = while (vm.exact_next()) |next| {
        if (next.tsc * 1000 > now_milli) break next;
        switch (next.kind) {
            .moment => {
                vm.moment_tsc = state.tsc; // Already past: the moment is now.
                vm.target_kind = .moment;
                return vm.target_set(state.branches + 1); // Stop right after the next branch.
            },
            .hold => vm.hold_tsc = null, // Past (not where a replay would stop): none, a replay makes the node.
            .timer => unreachable,
        }
    } else null;
    const timer_tsc = vm.pit.deadline_tsc();
    var stop = exact;
    if (timer_tsc) |deadline| {
        const hard_tsc = deadline + vm.timer_slack_tsc;
        if (hard_tsc * 1000 <= now_milli) {
            // Its hard stop is now: fired, and the next deadline armed (a hold point next must
            // not wait for the guest's next exit).
            try vm.timer_fire();
            return vm.timer_arm();
        }
        if (stop == null or hard_tsc < stop.?.tsc) stop = .{ .tsc = hard_tsc, .kind = .timer };
    }
    const target = stop orelse return;
    // With CPU modulation a branch takes more virtual time than the guest's clock shows until
    // the next exit adds it: count branches at the modulated rate, and place the soft stop at
    // the first clock read that, its owed time added, reads the deadline.
    const permille: u64 = 1000 + if (vm.modulation) |m| m.slowdown_permille else 0;
    const per_branch = @as(u64, vm.tsc_per_branch) * permille;
    const branches_left = @divCeil(target.tsc * 1000 - now_milli, per_branch);
    assert(branches_left > 0);
    vm.target_kind = target.kind;
    try vm.target_set(state.branches + branches_left);
    if (timer_tsc) |deadline| if (vm.timer_slack_tsc > 0) {
        // Due already (a hold point within its slack stopped first): the next clock read.
        const soft_tsc = if (deadline * 1000 <= now_milli)
            state.tsc
        else
            state.tsc + @divCeil(deadline * 1000 - now_milli, permille);
        try vm.soft_set(soft_tsc);
    };
}

/// The next moment or hold point, whichever comes first (at the same time the moment).
fn exact_next(vm: *const VM) ?Deadline {
    const stop: ?Deadline = if (vm.moment_reached) null else if (vm.moment_tsc) |tsc| .{
        .tsc = tsc,
        .kind = .moment,
    } else null;
    const hold: ?Deadline = if (vm.hold_tsc) |tsc| .{ .tsc = tsc, .kind = .hold } else null;
    const first = stop orelse return hold;
    const other = hold orelse return first;
    return if (other.tsc < first.tsc) other else first;
}

/// Whether this target exit is a soft stop (a clock read at or past the timer's deadline, before
/// the exact target): the timer's, whatever the target is.
fn soft_stopped(vm: *VM) !bool {
    if (vm.target_branches == 0) return false;
    return (try vm.det_state()).branches < vm.target_branches;
}

/// Adds the extra virtual time of the branches run since the last exit, and at the end of a
/// stretch draws the next speed (a stop armed at the old speed is re-armed).
fn modulate(vm: *VM) !void {
    const modulation = if (vm.modulation) |*m| m else return;
    const state = try vm.det_state();
    const owed = modulation.owed_milli(state.branches, vm.tsc_per_branch);
    modulation.branches = state.branches;
    modulation.remainder = owed % 1000;
    var extra_tsc = owed / 1000;
    if (extra_tsc > 0) {
        _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ADD_TSC, @intFromPtr(&extra_tsc));
        vm.state_cached = null;
        // A soft stop is a clock reading: it moves with the clock, to where timer_arm would put
        // it now (and does, after a hold point re-arms it: the timeline is the same either way).
        if (vm.soft_tsc != 0) try vm.soft_set(vm.soft_tsc + extra_tsc);
    }
    const tsc = state.tsc + extra_tsc;
    if (tsc < modulation.change_tsc) return;
    var draw: [8]u8 = undefined;
    try vm.decide_random(&draw, "cpu-modulation");
    const value = std.mem.readInt(u64, &draw, .little);
    // A quarter of the stretches at full speed.
    modulation.slowdown_permille = if (value % 4 == 0)
        0
    else
        @intCast((value >> 2) % (modulation_permille_max + 1));
    const stretch_ns = modulation_stretch_ns_min +
        (value >> 16) % (modulation_stretch_ns_max - modulation_stretch_ns_min);
    modulation.change_tsc = tsc + stretch_ns * tsc_per_ns;
    if (vm.target_branches != 0) try vm.target_set(0);
}

/// The moment arrived: end the run there, or push the command to the guest agent and keep
/// running until it reports completion.
fn moment_arrive(vm: *VM) !?Outcome {
    assert(!vm.moment_reached);
    vm.moment_reached = true;
    vm.target_kind = .timer;
    const moment_now = try vm.moment();
    if (vm.until != null and !vm.until_hit) {
        std.debug.print("[determinismo] until: timed out, the condition did not hold\n", .{});
    }
    std.debug.print("[determinismo] at moment vtime={d}ns branches={d}\n", .{
        moment_now.vtime_ns, moment_now.branches,
    });
    if (vm.stepping) {
        vm.stepping = false;
        return vm.steps_next();
    }
    const given = vm.moment_command orelse return .moment_reached;
    // A fresh future: the timeline's randomness and tape end here, the guest's kernel generator
    // reseeded from the new seed, and the fault injector told, as at a tree's branch point.
    const commands = if (vm.fresh_seed) |seed| blk: {
        vm.decisions.seed = seed;
        vm.overrides = null;
        std.debug.print("[determinismo] a fresh future from here (seed {d})\n", .{seed});
        // A no-op in the shell of a guest older than det:reseed (runs replay with their own).
        break :blk try std.mem.concat(vm.step_arena.allocator(), u8, &.{ ": det:reseed\x00", given });
    } else given;
    vm.moment_printing = true;
    // Steps of the platform's: the guest's agent holds the timeline from its end meanwhile.
    const stepped = std.mem.indexOf(u8, commands, step_wait) != null or
        std.mem.indexOf(u8, commands, step_until) != null or
        std.mem.indexOf(u8, commands, "det:background ") != null;
    vm.moment_commands_rest = if (stepped)
        try std.mem.concat(vm.step_arena.allocator(), u8, &.{ "det:hold\x00", commands, "\x00det:release" })
    else
        commands;
    try vm.moment_command_next();
    return null;
}

/// Pushes the next of the moment's commands to the guest agent.
fn moment_command_next(vm: *VM) !void {
    assert(vm.moment_commands_rest.len > 0);
    const rest = vm.moment_commands_rest;
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    const step = rest[0..end];
    vm.moment_commands_rest = if (end == rest.len) "" else rest[end + 1 ..];
    if (std.mem.startsWith(u8, step, step_wait)) {
        const ms = std.fmt.parseInt(u64, std.mem.trim(u8, step[step_wait.len..], " "), 10) catch
            return error.BadStep;
        return vm.step_arm(ms, null);
    }
    if (std.mem.startsWith(u8, step, step_until)) {
        // "<timeout ms> <condition>": 0 for no timeout.
        const text = std.mem.trimStart(u8, step[step_until.len..], " ");
        const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadStep;
        const ms = std.fmt.parseInt(u64, text[0..space], 10) catch return error.BadStep;
        const condition = try vm.step_arena.allocator().create(query.Condition);
        condition.* = try query.parse(vm.step_arena.allocator(), text[space + 1 ..]);
        return vm.step_arm(ms, condition);
    }
    vm.action_pending = step;
    try vm.irq_pulse(irq_action);
}

const step_wait = "det:wait ";
const step_until = "det:until ";

/// Runs on from now: for `ms` of virtual time, or until an event matches `condition` (within
/// `ms`, unless 0); the moment that ends it continues the script (moment_arrive).
fn step_arm(vm: *VM, ms: u64, condition: ?*const query.Condition) !void {
    assert(vm.moment_reached);
    const now = try vm.moment();
    const limited = condition == null or ms > 0;
    vm.moment_tsc = if (limited) (now.vtime_ns + ms * std.time.ns_per_ms) * tsc_per_ns else null;
    vm.until = condition;
    vm.until_hit = false;
    vm.moment_reached = false;
    vm.stepping = true;
    if (vm.target_branches != 0) try vm.target_set(0); // Re-armed at the next loop.
}

/// After a step: the next one, or the script's end (the run's end, unless it continues).
fn steps_next(vm: *VM) !?Outcome {
    if (vm.moment_commands_rest.len > 0) {
        try vm.moment_command_next();
        return null;
    }
    vm.moment_printing = false;
    if (!vm.moment_continue) return .command_done;
    return null;
}

/// Arms (or with 0 cancels, together with any soft deadline) the exact branch-count stop.
pub fn target_set(vm: *VM, target_branches: u64) !void {
    assert(vm.deterministic);
    var target = target_branches;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_SET_TARGET, @intFromPtr(&target));
    if (target_branches == 0) try vm.soft_set(0);
    vm.target_branches = target_branches;
}

fn soft_set(vm: *VM, soft_tsc: u64) !void {
    var soft = soft_tsc;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_SET_SOFT_TSC, @intFromPtr(&soft));
    vm.soft_tsc = soft_tsc;
}

/// At an exit the VMM handles anyway (an exact point, like a soft stop): fire a timer whose
/// deadline has passed instead of waiting for its soft or hard stop.
fn timer_due(vm: *VM) !void {
    if (!vm.deterministic or vm.timer_slack_tsc == 0) return; // No slack: stops are exact.
    const deadline = vm.pit.deadline_tsc() orelse return;
    const state = try vm.det_state();
    if (state.tsc < deadline) return;
    // Whatever the target: a hold point or a moment armed before the timer's hard stop does not
    // move where it fires.
    try vm.target_set(0);
    try vm.timer_fire();
    vm.stats.exit_timer_fires += 1;
}

fn timer_fire(vm: *VM) !void {
    assert(vm.pit.armed);
    if (vm.vtime_limit_tsc) |limit| if (vm.pit.deadline_tsc()) |tsc| {
        if (tsc >= limit) vm.over_limit = true;
    };
    try vm.trace("timer", vm.pit.fired);
    vm.pit.fire();
    vm.stats.timer_fires += 1;
    try vm.irq_pulse(PIT.irq);
}

const Idle = enum { timer, moment, none };

/// The guest halted with nothing to do: skip to what wakes it, or to the moment.
fn idle(vm: *VM) !?Outcome {
    assert(vm.deterministic);
    return switch (try vm.idle_skip()) {
        .timer => null,
        .moment => try vm.moment_arrive(),
        .none => .hlt, // Halted with no timer: never wakes.
    };
}

/// The guest halted with nothing to do: jump virtual time to the next deadline. A hold point on
/// the way pauses there and the skip goes on: the guest does not wake (resuming it would run its
/// idle loop once more, which a timeline without the hold point does not).
fn idle_skip(vm: *VM) !Idle {
    assert(vm.deterministic);
    while (true) {
        const deadline = vm.deadline_next() orelse return .none;
        const state = try vm.det_state();
        if (deadline.tsc > state.tsc) {
            var skipped_tsc = deadline.tsc - state.tsc;
            _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ADD_TSC, @intFromPtr(&skipped_tsc));
            vm.state_cached = null;
            vm.stats.idle_tsc += skipped_tsc;
        }
        if (vm.target_branches != 0) try vm.target_set(0);
        assert(vm.target_branches == 0);
        try vm.trace("idle", deadline.tsc);
        vm.stats.idle_skips += 1;
        switch (deadline.kind) {
            .moment => return .moment,
            .hold => try vm.hold_reach(.{ .idle = true }),
            .timer => {
                try vm.timer_fire();
                return .timer;
            },
        }
    }
}

/// Owner of a timeline's hold points (main.zig's holders): told when the timeline reached new
/// behaviors (it may arm a hold point then, `hold_arm`), and called at the hold point.
pub const Hold = struct {
    context: *anyopaque,
    behaviors: *const fn (context: *anyopaque, vm: *VM, first_new: u32) anyerror!void,
    reached: *const fn (context: *anyopaque, vm: *VM, point: Point) anyerror!void,

    pub const Point = struct {
        /// Inside an idle skip: the guest is halted, and a replay from here goes on skipping
        /// (Options.from_hold). Else the guest stopped at an exact branch count.
        idle: bool,
    };
};

/// Pauses the run at `vtime_ns` (later than now) for the hold's owner, in place of a hold point
/// armed already (one at a time).
pub fn hold_arm(vm: *VM, vtime_ns: u64) !void {
    assert(vm.deterministic);
    assert(vm.hold != null);
    vm.hold_tsc = vtime_ns * tsc_per_ns;
    // An armed stop is re-armed with the new hold point in view (a timer's at the same branch
    // count: timer_arm counts from the deadline, not from now).
    if (vm.target_branches != 0 and vm.target_kind != .moment) try vm.target_set(0);
}

/// After an exit that may have brought events: new behaviors are the hold point owner's news.
fn hold_notice(vm: *VM) !void {
    const hold = vm.hold orelse return;
    const count = vm.events.behavior_count;
    if (count == vm.hold_behaviors) return;
    const first_new = vm.hold_behaviors;
    vm.hold_behaviors = count;
    try hold.behaviors(hold.context, vm, first_new);
}

fn hold_reach(vm: *VM, point: Hold.Point) !void {
    vm.hold_tsc = null;
    vm.target_kind = .timer;
    const hold = vm.hold orelse return;
    try hold.reached(hold.context, vm, point);
}

fn now_tsc(vm: *VM) !u64 {
    if (vm.deterministic) return (try vm.det_state()).tsc;
    return 0; // KVM's own PIT handles the ports; the RTC reads the epoch.
}

fn handle_mmio(vm: *VM) !void {
    assert(vm.run.exit_reason == .mmio);
    vm.stats.exits.getPtr(.mmio).* += 1;
    const mmio = &vm.run.exit.mmio;
    assert(mmio.len >= 1 and mmio.len <= 8);
    const data = mmio.data[0..mmio.len];
    const index = vm.disk_index(mmio.phys_addr) orelse {
        if (mmio.is_write == 0) @memset(data, 0xff); // Nothing else is memory-mapped.
        return;
    };
    const block = &vm.blocks[index];
    const offset = mmio.phys_addr - VirtioBlock.address_base - index * VirtioBlock.address_size;
    if (mmio.is_write == 0) return block.read(offset, data);
    if (block.write(offset, data, .{ .bytes = vm.memory })) {
        try vm.trace("disk", index);
        try vm.irq_pulse(VirtioBlock.irq);
    }
}

fn disk_index(vm: *const VM, address: u64) ?u32 {
    const base = VirtioBlock.address_base;
    if (address < base) return null;
    const index = (address - base) / VirtioBlock.address_size;
    if (index >= vm.block_count) return null;
    return @intCast(index);
}

/// Kernel parameters announcing `count` disks to the guest's virtio_mmio driver.
pub fn disks_cmdline(arena: std.mem.Allocator, count: u32) ![]const u8 {
    assert(count <= disks_max);
    var parts: [disks_max][]const u8 = undefined;
    for (parts[0..count], 0..) |*part, index| {
        const address = VirtioBlock.address_base + index * VirtioBlock.address_size;
        part.* = try std.fmt.allocPrint(arena, "virtio_mmio.device=4K@0x{x}:{d}", .{
            address, VirtioBlock.irq,
        });
    }
    return std.mem.join(arena, " ", parts[0..count]);
}

fn handle_io(vm: *VM) !?Outcome {
    const io = vm.run.exit.io;
    assert(io.size == 1 or io.size == 2 or io.size == 4);
    assert(io.count >= 1 and io.count <= page_size);
    const data: [*]u8 = @ptrFromInt(@intFromPtr(vm.run) + io.data_offset);
    vm.stats.exits.getPtr(if (Serial.contains(io.port)) .io_serial else .io_other).* += 1;
    vm.stats.io_ports[io.port] +|= 1;
    for (0..io.count) |index| {
        const bytes = data[index * io.size ..][0..io.size];
        if (io.direction == kvm.Run.io_out) {
            if (try vm.io_out(io.port, bytes)) |outcome| return outcome;
        } else {
            try vm.io_in(io.port, bytes);
        }
    }
    return null;
}

fn io_out(vm: *VM, port: u16, bytes: []const u8) !?Outcome {
    assert(bytes.len >= 1 and bytes.len <= 4);
    if (Serial.contains(port)) {
        if (vm.serial.write(port, bytes[0])) try vm.irq_pulse(Serial.irq);
        return null;
    }
    switch (port) {
        RTC.port_index, RTC.port_data => vm.rtc.write(port, bytes[0]),
        PIT.port_mode => vm.pit.write_mode(bytes[0], try vm.now_tsc()),
        // A 16-bit write is a count's low byte then its high byte (det_pit_word).
        PIT.port_channel_0 => for (bytes) |byte| {
            const loaded = vm.pit.write_count(byte, try vm.now_tsc());
            if (loaded and vm.target_branches != 0) try vm.target_set(0); // Re-armed next loop.
        },
        port_doorbell => {
            if (bytes.len != 4) return error.BadGuestRequest;
            const setup_was_complete = vm.events.setup_complete != null;
            try vm.handle_request(std.mem.readInt(u32, bytes[0..4], .little));
            if (vm.until_hit and !vm.moment_reached) {
                if (try vm.moment_arrive()) |outcome| return outcome;
            }
            // A step ends: a command's end, or a background command's start (its end ends none).
            const step_ended = if (vm.exec_background)
                vm.events.last_event_is("exec_start")
            else
                vm.events.last_event_is("exec_done");
            const command_finished = step_ended and vm.events.count != vm.exec_done_handled and
                vm.moment_reached and !vm.stepping;
            if (command_finished) vm.exec_done_handled = vm.events.count;
            if (command_finished and vm.moment_commands_rest.len > 0) {
                try vm.moment_command_next();
            } else if (command_finished) {
                if (vm.moment_command != null) {
                    vm.moment_printing = false;
                    if (!vm.moment_continue) return .command_done;
                }
            }
            if (vm.stop_at_setup_complete) {
                const setup_is_complete = vm.events.setup_complete != null;
                if (!setup_was_complete and setup_is_complete) return .setup_complete;
            }
        },
        port_debug_exit => return .{ .debug_exit = bytes[0] },
        else => {}, // Writes to absent devices are dropped, as on an ISA bus.
    }
    return null;
}

fn io_in(vm: *VM, port: u16, bytes: []u8) !void {
    assert(bytes.len >= 1 and bytes.len <= 4);
    if (Serial.contains(port)) {
        bytes[0] = vm.serial.read(port);
        return;
    }
    switch (port) {
        RTC.port_index, RTC.port_data => {
            bytes[0] = vm.rtc.read(port, try vm.now_tsc() / cpuid.tsc_hz);
        },
        PIT.port_channel_0 => bytes[0] = vm.pit.read_count(try vm.now_tsc()),
        0x61 => bytes[0] = 0, // Speaker and PIT channel 2 gate: unused.
        else => @memset(bytes, 0xff), // Absent devices float high, as on an ISA bus.
    }
}

pub fn moment(vm: *VM) !Events.Moment {
    if (!vm.deterministic) return .{ .vtime_ns = 0, .branches = 0 };
    const state = try vm.det_state();
    // With CPU modulation, the time the next exit adds to the guest's clock for the branches
    // run since the last one (modulate): none at the guest's own exits, which add it first; at a
    // moment's stop, between them, the moment is that much later than the clock reads (a rewind
    // read 180 us early, a deadline 1.7 us).
    const owed_tsc = if (vm.modulation) |m| m.owed_milli(state.branches, vm.tsc_per_branch) / 1000 else 0;
    return .{
        .vtime_ns = @divFloor(state.tsc + owed_tsc, tsc_per_ns),
        .branches = vm.branches_offset + state.branches,
    };
}

/// Whether an event matches `--until` (the events' parse buffer is free again after emit).
fn until_matches(vm: *VM, moment_now: Events.Moment, line: []const u8) bool {
    const condition = vm.until orelse return false;
    if (!condition.may_match(line)) return false;
    var fba = std.heap.FixedBufferAllocator.init(vm.events.parse_buffer);
    const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), line, .{}) catch
        return false;
    const event: query.Event = .{
        .value = value,
        .vtime_ns = moment_now.vtime_ns,
        .seq = vm.events.count,
    };
    if (!condition.matches(event)) return false;
    std.debug.print("[determinismo] until: {s}\n", .{line});
    return true;
}

/// One request from the guest module: a page holding { op: u32, len: u32, result: u64, data }.
fn handle_request(vm: *VM, address: u32) !void {
    if (address % page_size != 0) return error.BadGuestRequest;
    // The guest module's page is below 4 GiB (its doorbell carries 32 bits): low RAM.
    const guest = GuestMemory{ .bytes = vm.memory };
    if (address + page_size > guest.low_size()) return error.BadGuestRequest;
    const page = vm.memory[address..][0..page_size];
    const operation = std.mem.readInt(u32, page[0..4], .little);
    const size = std.mem.readInt(u32, page[4..8], .little);
    if (size > page_size - request_header_size) return error.BadGuestRequest;
    const data = page[request_header_size..][0..size];
    try vm.trace("request", @as(u64, operation) << 32 | size);
    switch (operation) {
        request_operation_emit => {
            // The writing process's name follows the data when the guest module had room.
            const has_source = std.mem.readInt(u64, page[8..16], .little) == 1 and
                size + source_size_max <= page_size - request_header_size;
            const source = if (has_source)
                source_trim(page[request_header_size + size ..][0..source_size_max])
            else
                "";
            // One event per line: SDKs that buffer may write several lines at once.
            const moment_now = try vm.moment();
            var lines = std.mem.tokenizeScalar(u8, data, '\n');
            while (lines.next()) |line| {
                vm.decision_note(line, source);
                try vm.events.emit(moment_now, line);
                vm.exec_background = std.mem.startsWith(u8, line, "{\"event\":\"exec_") and
                    std.mem.indexOf(u8, line, "\"background\":true") != null;
                if (vm.faults_record_fd) |fd| if (std.mem.startsWith(u8, line, "{\"event\":\"fault\",")) {
                    _ = linux.write(fd, line.ptr, line.len);
                    _ = linux.write(fd, "\n", 1);
                };
                try vm.checkpoint(moment_now);
                if (vm.until != null and !vm.until_hit and !vm.moment_reached) {
                    vm.until_hit = vm.until_matches(moment_now, line);
                }
                if (vm.strategy) |strategy| if (strategy.decides) {
                    try strategy.event(moment_now, source, line);
                };
                if (vm.moment_printing) {
                    std.debug.print("[guest @ {d}ns] {s}\n", .{ moment_now.vtime_ns, line });
                }
            }
        },
        request_operation_action => {
            const action = vm.action_pending orelse "";
            vm.action_pending = null;
            const action_size: u32 = @intCast(@min(action.len, page_size - request_header_size));
            @memcpy(page[request_header_size..][0..action_size], action[0..action_size]);
            std.mem.writeInt(u32, page[4..8], action_size, .little);
        },
        request_operation_random => {
            if (size == 0) return error.BadGuestRequest;
            // The guest module puts the asking process's name first; the answer replaces it.
            var source_buffer: [source_size_max]u8 = undefined;
            const source = source_trim(page[request_header_size..][0..source_size_max]);
            @memcpy(source_buffer[0..source.len], source);
            try vm.decide_random(data, source_buffer[0..source.len]);
        },
        else => return error.BadGuestRequest,
    }
}

/// Every `checkpoint_interval` events: recorded in the tape being written, or compared with
/// the tape being replayed (a mismatch ends the replay where it diverged).
fn checkpoint(vm: *VM, moment_now: Events.Moment) !void {
    if (vm.events.count % tape.checkpoint_interval != 0) return;
    const now = tape.Checkpoint{
        .events = vm.events.count,
        .branches = moment_now.branches,
        .events_hash = vm.events.hash.final(),
    };
    if (vm.tape_fd) |fd| tape.write_checkpoint(fd, now);
    // A command run at the moment makes a new timeline from there: the tape describes the one
    // without it (a replay to look inside a timeline, --exec, must not stop at its own change).
    if (vm.moment_reached and vm.moment_command != null) return;
    if (vm.overrides) |overrides| overrides.check(now) catch |err| {
        const message = "[determinismo] replay diverged from its tape at event {d}\n";
        std.debug.print(message, .{now.events});
        // What could have perturbed the guest's clock on the way (the KVM patch's counts).
        if (vm.det_state()) |state| {
            std.debug.print("[determinismo] its clock's hazards: {d} counter throttles restarted, " ++
                "{d} reached at another exit, {d} overshoots (largest skid {d}), {d} drifts, " ++
                "XINUSE restored {d} times ({d} not)\n", .{
                state.throttles, state.late_steps,   state.overshoots,     state.skid_max,
                state.drifts,    state.xinuse_fixes, state.xinuse_unfixed,
            });
        } else |_| {}
        return err;
    };
}

/// The name of the process behind a request (Linux's TASK_COMM_LEN, without its NUL).
const source_size_max = 16;

fn source_trim(comm: *const [source_size_max]u8) []const u8 {
    return comm[0 .. std.mem.indexOfScalar(u8, comm, 0) orelse source_size_max];
}

/// One randomness pull: the seeded default, unless a replayed tape or the strategy overrides it.
const decision_label_size_max = 2048;

/// Keeps a decision's label for the next pull of the process that announced it.
fn decision_note(vm: *VM, line: []const u8, source: []const u8) void {
    const prefix = "{\"decision\":";
    if (!std.mem.startsWith(u8, line, prefix) or line[line.len - 1] != '}') return;
    const label = line[prefix.len .. line.len - 1];
    if (label.len > decision_label_size_max or source.len > source_size_max) return;
    @memcpy(vm.decision_label[0..label.len], label);
    vm.decision_label_size = @intCast(label.len);
    @memcpy(vm.decision_source[0..source.len], source);
    vm.decision_source_size = @intCast(source.len);
}

/// The label of this pull, if its process announced one (used once).
fn decision_take(vm: *VM, source: []const u8) ?[]const u8 {
    if (vm.decision_label_size == 0) return null;
    const announced = vm.decision_source[0..vm.decision_source_size];
    if (!std.mem.eql(u8, announced, source)) return null;
    const label = vm.decision_label[0..vm.decision_label_size];
    vm.decision_label_size = 0;
    return label;
}

fn decide_random(vm: *VM, value: []u8, source: []const u8) !void {
    assert(value.len > 0);
    const label = vm.decision_take(source);
    const pull = vm.decisions.pulls;
    vm.decisions.random(value);
    assert(vm.decisions.pulls == pull + 1);
    vm.last_pull_ns = vm.events.last_vtime_ns;
    if (vm.overrides) |overrides| {
        assert(vm.strategy == null); // A replay never consults the strategy.
        if (try overrides.apply(pull, value)) {
            if (overrides.reason(pull)) |reason| try vm.decision_event(pull, source, label, reason);
        }
    } else if (vm.strategy) |strategy| {
        if (!strategy.decides) return; // It only chooses where the tree returns.
        if (value.len > Strategy.override_size_max) return; // Too large to override.
        if (try strategy.random(pull, try vm.moment(), source, label, value)) {
            const reason = strategy.reason[0..strategy.reason_size];
            if (vm.tape_fd) |fd| tape.write_override(fd, pull, value, reason);
            if (reason.len > 0) try vm.decision_event(pull, source, label, reason);
        }
    }
}

/// A strategy's decision and why, in the timeline (its replay from the tape has it too).
fn decision_event(
    vm: *VM,
    pull: u64,
    source: []const u8,
    label: ?[]const u8,
    reason: []const u8,
) !void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"event\":\"decision\",\"details\":{{\"pull\":{d},\"source\":{f}," ++
        "\"by\":\"strategy\",\"reason\":{f}", .{
        pull, std.json.fmt(source, .{}), std.json.fmt(reason, .{}),
    }) catch return;
    if (label) |decision| writer.print(",\"decision\":{s}", .{decision}) catch return;
    writer.writeAll("}}") catch return;
    try vm.events.emit(try vm.moment(), writer.buffered());
}

fn trace(vm: *VM, comptime kind: []const u8, value: u64) !void {
    const fd = vm.trace_fd orelse return;
    assert(vm.deterministic);
    const state = try vm.det_state();
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_REGS, @intFromPtr(&regs));
    var line_buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, kind ++ " {d} branches={d} rip={x} rdtsc={d} " ++
        "steps={d} overflows={d} soft={d} drifts={d} drift={d}\n", .{
        value,            state.branches,  regs.rip,         state.rdtsc_exits,
        state.mtf_steps,  state.overflows, state.soft_exits, state.drifts,
        state.drift_last,
    }) catch unreachable;
    _ = linux.write(fd, line.ptr, line.len); // Best effort: a debugging aid.
}

/// Debugging: the log of RDTSC exits, (branch count, RIP) pairs, appended to rdtsc_log_fd: the
/// first `rdtsc_log_cap` of them.
pub const rdtsc_log_cap_default = 1 << 22;

fn rdtsc_log_enable(vm: *VM) !void {
    if (vm.itrace_fd != null and vm.itrace_at > 0) {
        var window: kvm.DetItrace = .{ .at = vm.itrace_at, .cap = itrace_cap };
        _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ITRACE_ENABLE, @intFromPtr(&window));
    }
    if (vm.rdtsc_log_fd == null) return;
    var cap: u64 = vm.rdtsc_log_cap;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_LOG_ENABLE, @intFromPtr(&cap));
}

const itrace_cap = 1 << 22;

fn rdtsc_log_write(vm: *VM) void {
    const fd = vm.rdtsc_log_fd orelse return;
    const pairs = std.heap.page_allocator.alloc(u64, 2 * @max(vm.rdtsc_log_cap, itrace_cap)) catch return;
    defer std.heap.page_allocator.free(pairs);
    var request: kvm.DetLog = .{ .buf = @intFromPtr(pairs.ptr), .cap = vm.rdtsc_log_cap, .len = 0 };
    _ = kvm.ioctl(vm.vcpu_fd, kvm.DET_LOG_READ, @intFromPtr(&request)) catch return;
    const bytes = std.mem.sliceAsBytes(pairs[0 .. 2 * request.len]);
    _ = linux.write(fd, bytes.ptr, bytes.len);
    const itrace = vm.itrace_fd orelse return;
    var traced: kvm.DetLog = .{ .buf = @intFromPtr(pairs.ptr), .cap = itrace_cap, .len = 0 };
    _ = kvm.ioctl(vm.vcpu_fd, kvm.DET_ITRACE_READ, @intFromPtr(&traced)) catch return;
    const traced_bytes = std.mem.sliceAsBytes(pairs[0 .. 2 * traced.len]);
    _ = linux.write(itrace, traced_bytes.ptr, traced_bytes.len);
}

fn irq_pulse(vm: *VM, irq: u32) !void {
    assert(irq < 16);
    var level = kvm.IrqLevel{ .irq = irq, .level = 1 };
    _ = try kvm.ioctl(vm.vm_fd, kvm.IRQ_LINE, @intFromPtr(&level));
    level.level = 0;
    _ = try kvm.ioctl(vm.vm_fd, kvm.IRQ_LINE, @intFromPtr(&level));
}

fn open_kvm() !linux.fd_t {
    const fd = try syscall(linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    assert(fd <= std.math.maxInt(i32));
    return @intCast(fd);
}

fn syscall(result: usize) !usize {
    switch (linux.errno(result)) {
        .SUCCESS => return result,
        else => |errno| {
            std.log.err("syscall failed: {s}", .{@tagName(errno)});
            return error.SyscallFailed;
        },
    }
}
