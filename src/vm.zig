// SPDX-License-Identifier: MIT
//! One single-vCPU KVM virtual machine: memfd-backed RAM, legacy devices and the run loop.
//!
//! In deterministic mode (ARCHITECTURE.md §4) guest time is a function of retired guest branches:
//! the patched KVM returns tsc = base + branches * tsc_per_branch for RDTSC and stops the vCPU at
//! exact branch counts. The VMM owns the only timer (the PIT), fires it at the branch count where
//! its deadline falls, and skips idle time when the guest halts.
const std = @import("std");
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
const Snapshot = @import("snapshot.zig");
const Strategy = @import("strategy.zig");
const tape = @import("tape.zig");

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
/// Multiverse debugging: the moment (virtual TSC) to stop at, the command to run there, and
/// where that stands. Without a command the run ends at the moment.
moment_tsc: ?u64,
moment_command: ?[]const u8,
moment_reached: bool,
/// What the guest agent receives on its next action request.
action_pending: ?[]const u8,
/// Whether the armed branch-count target is the moment (true) or the PIT deadline (false).
target_is_moment: bool,
deterministic: bool,
builtin_properties: bool,
tsc_per_branch: u32,
timer_slack_tsc: u64,
serial: Serial,
rtc: RTC,
pit: PIT,
/// Read-only disks, one virtio-mmio slot each (see virtio_block.zig).
blocks: [disks_max]VirtioBlock,
block_count: u32,
/// Branch count at which KVM stops the vCPU for the PIT deadline (0: none).
target_branches: u64,
decisions: Decisions,
events: Events,
stats: Stats,
/// Optional text trace of every point where the VMM changes the guest's course: timer stops,
/// idle skips and guest requests, each with branch count and RIP. Diffing two traces finds the
/// first divergence of two runs.
trace_fd: ?linux.fd_t,
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
    /// Branches before a stop target where KVM starts single-stepping (must exceed PMI skid).
    margin_branches: u32 = 128,
    /// How late a timer interrupt may be: it is delivered at the first RDTSC at or past its
    /// deadline (free), or exactly this much later (single-stepping) if the guest reads no
    /// clock meanwhile. Part of a timeline's inputs.
    timer_slack_ns: u64 = 100 * std.time.ns_per_us,
    /// Root of all guest randomness: seeds the guest kernel's RNG at boot and answers every
    /// randomness pull from /dev/determinismo.
    seed: u64,
    /// Where to append the guest's events as JSON lines.
    events_fd: ?linux.fd_t,
    /// Scratch memory for parsing guest events, reserved once by the caller (see events.zig).
    events_parse_buffer: []u8,
    trace_fd: ?linux.fd_t = null,
    stop_at_setup_complete: bool = false,
    /// Stop at this virtual time, and optionally run a command in the guest there.
    moment_vtime_ns: ?u64 = null,
    moment_command: ?[]const u8 = null,
    disks: []const Disk = &.{},
    /// The guest runs determinismo's runtime: check the built-in properties when a timeline ends.
    builtin_properties: bool = false,
};

/// A read-only disk image, open for the whole process (branches share it).
pub const Disk = struct { fd: linux.fd_t, size: u64 };
pub const disks_max = 16;

pub const Outcome = union(enum) {
    shutdown, // A triple fault: how the guest reboots with reboot=t.
    setup_complete, // Only with Options.stop_at_setup_complete.
    moment_reached, // Only with Options.moment_vtime_ns and no command.
    command_done, // Only with Options.moment_command: the command at the moment finished.
    debug_exit: u8,
    hlt,
    failed: []const u8,
};

pub const Stats = struct {
    exits: std.EnumArray(Kind, u64) = .initFill(0),
    io_ports: [65536]u32 = @splat(0),
    timer_fires: u64 = 0,
    idle_skips: u64 = 0,
    idle_tsc: u64 = 0,

    pub const Kind = enum { io_serial, io_other, mmio, hlt, intr, det_target, other };
};

const VM = @This();

/// Kernel parameters the deterministic machine needs: the PIT is the only clock-event device, the
/// TSC (virtualized by KVM) the only clocksource, and the boot seed the RNG's only entropy.
pub const cmdline_deterministic = "nolapic_timer hpet=disable clocksource=tsc tsc=reliable " ++
    "random.trust_bootloader=on random.trust_cpu=off";

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
    vm.events.log_fd = options.events_fd;
    vm.decisions = .{ .seed = options.seed, .pulls = snapshot.decisions.pulls };
    assert(vm.branches_offset == snapshot.branches);
}

pub fn deinit(vm: *VM) void {
    vm.serial.flush();
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
        .moment_tsc = if (options.moment_vtime_ns) |ns| ns * tsc_per_ns else null,
        .moment_command = options.moment_command,
        .moment_reached = false,
        .action_pending = null,
        .target_is_moment = false,
        .deterministic = options.deterministic,
        .builtin_properties = options.builtin_properties,
        .tsc_per_branch = options.tsc_per_branch,
        .timer_slack_tsc = options.timer_slack_ns * tsc_per_ns,
        .serial = .{},
        .rtc = .{ .epoch_seconds = options.epoch_seconds },
        .pit = .{ .tsc_hz = cpuid.tsc_hz },
        .blocks = undefined,
        .block_count = @intCast(options.disks.len),
        .target_branches = 0,
        .decisions = .{ .seed = options.seed },
        .events = undefined,
        .stats = .{},
        .trace_fd = options.trace_fd,
        .strategy = null,
        .tape_fd = null,
        .overrides = null,
    };
    vm.events.init(options.events_parse_buffer, .{ .log_fd = options.events_fd });
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
    assert((try vm.det_state()).tsc == start.tsc_base);
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
    assert(memory_size <= 3 << 30); // Below the 32-bit PCI hole: one flat region.
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
    var region = kvm.UserspaceMemoryRegion{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = 0,
        .memory_size = memory_size,
        .userspace_addr = address,
    };
    _ = try kvm.ioctl(vm.vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(&region));
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
    const entry = try boot.load(vm.memory, &boot_options);
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
        try vm.events.finish(try vm.moment(), if (cut_short) .cut_short else .ended);
    }
    return outcome;
}

/// The VM's event loop: it ends only when the guest powers off, reboots or fails.
fn run_loop(vm: *VM) !Outcome {
    assert(!vm.frozen);
    defer vm.serial.flush();
    while (true) {
        if (vm.deterministic) try vm.timer_arm();
        _ = kvm.ioctl(vm.vcpu_fd, kvm.RUN, 0) catch |err| switch (err) {
            error.Interrupted => {
                vm.stats.exits.getPtr(.intr).* += 1;
                continue;
            },
            else => return err,
        };
        switch (vm.run.exit_reason) {
            .io => if (try vm.handle_io()) |outcome| return outcome,
            .mmio => try vm.handle_mmio(),
            .det_target => {
                assert(vm.deterministic);
                vm.stats.exits.getPtr(.det_target).* += 1;
                if (vm.target_is_moment) {
                    vm.target_branches = 0;
                    if (try vm.moment_arrive()) |outcome| return outcome;
                } else {
                    try vm.target_set(0); // A soft stop leaves the hard one armed.
                    try vm.timer_fire();
                }
            },
            .hlt => {
                vm.stats.exits.getPtr(.hlt).* += 1;
                if (!vm.deterministic) return .hlt;
                switch (try vm.idle_skip()) {
                    .timer => {},
                    .moment => if (try vm.moment_arrive()) |outcome| return outcome,
                    .none => return .hlt, // Halted with no timer: never wakes.
                }
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
    var state: kvm.DetState = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_GET_STATE, @intFromPtr(&state));
    assert(state.tsc >= state.branches * vm.tsc_per_branch);
    return state;
}

const Deadline = struct { tsc: u64, is_moment: bool };
const tsc_per_ns = cpuid.tsc_hz / std.time.ns_per_s;

/// The next thing the VMM must do at a precise moment: fire the PIT, or reach the moment.
fn deadline_next(vm: *const VM) ?Deadline {
    const timer: ?Deadline = if (vm.pit.deadline_tsc()) |tsc| .{
        .tsc = tsc,
        .is_moment = false,
    } else null;
    const stop: ?Deadline = if (vm.moment_reached) null else if (vm.moment_tsc) |tsc| .{
        .tsc = tsc,
        .is_moment = true,
    } else null;
    if (timer == null) return stop;
    if (stop == null) return timer;
    return if (stop.?.tsc <= timer.?.tsc) stop else timer;
}

/// Asks KVM to stop the vCPU at the next deadline. A moment stops at its exact branch count. A
/// timer stops at the first RDTSC at or past its deadline (a soft stop, free), or at most
/// `timer_slack` later at an exact branch count (a hard stop, which costs single-stepping):
/// both are exact points of the guest's execution, so replays deliver it at the same place.
fn timer_arm(vm: *VM) !void {
    assert(vm.deterministic);
    if (vm.target_branches != 0) return;
    const deadline = vm.deadline_next() orelse return;
    const state = try vm.det_state();
    if (deadline.tsc <= state.tsc) {
        if (deadline.is_moment) {
            vm.moment_tsc = state.tsc; // Already past: the moment is now.
            vm.target_is_moment = true;
            return vm.target_set(state.branches + 1); // Stop right after the next branch.
        }
        return vm.timer_fire();
    }
    const slack_tsc = if (deadline.is_moment) 0 else vm.timer_slack_tsc;
    const hard_tsc = deadline.tsc + slack_tsc;
    const branches_left = std.math.divCeil(u64, hard_tsc - state.tsc, vm.tsc_per_branch) catch
        unreachable;
    assert(branches_left > 0);
    vm.target_is_moment = deadline.is_moment;
    try vm.target_set(state.branches + branches_left);
    if (!deadline.is_moment and slack_tsc > 0) try vm.soft_set(deadline.tsc);
}

/// The moment arrived: end the run there, or push the command to the guest agent and keep
/// running until it reports completion.
fn moment_arrive(vm: *VM) !?Outcome {
    assert(!vm.moment_reached);
    vm.moment_reached = true;
    vm.target_is_moment = false;
    const moment_now = try vm.moment();
    std.debug.print("[determinismo] at moment vtime={d}ns branches={d}\n", .{
        moment_now.vtime_ns, moment_now.branches,
    });
    const command = vm.moment_command orelse return .moment_reached;
    vm.action_pending = command;
    try vm.irq_pulse(irq_action);
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
}

fn timer_fire(vm: *VM) !void {
    assert(vm.pit.armed);
    try vm.trace("timer", vm.pit.fired);
    vm.pit.fire();
    vm.stats.timer_fires += 1;
    try vm.irq_pulse(PIT.irq);
}

const Idle = enum { timer, moment, none };

/// The guest halted with nothing to do: jump virtual time to the next deadline.
fn idle_skip(vm: *VM) !Idle {
    assert(vm.deterministic);
    const deadline = vm.deadline_next() orelse return .none;
    const state = try vm.det_state();
    if (deadline.tsc > state.tsc) {
        var skipped_tsc = deadline.tsc - state.tsc;
        _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ADD_TSC, @intFromPtr(&skipped_tsc));
        vm.stats.idle_tsc += skipped_tsc;
    }
    if (vm.target_branches != 0) try vm.target_set(0);
    assert(vm.target_branches == 0);
    try vm.trace("idle", deadline.tsc);
    vm.stats.idle_skips += 1;
    if (deadline.is_moment) return .moment;
    try vm.timer_fire();
    return .timer;
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
    if (block.write(offset, data, vm.memory)) {
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
        PIT.port_channel_0 => {
            const loaded = vm.pit.write_count(bytes[0], try vm.now_tsc());
            if (loaded and vm.target_branches != 0) try vm.target_set(0); // Re-armed next loop.
        },
        port_doorbell => {
            if (bytes.len != 4) return error.BadGuestRequest;
            const setup_was_complete = vm.events.setup_complete != null;
            try vm.handle_request(std.mem.readInt(u32, bytes[0..4], .little));
            if (vm.events.last_event_is("exec_done")) {
                if (vm.moment_reached and vm.moment_command != null) return .command_done;
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

fn moment(vm: *VM) !Events.Moment {
    if (!vm.deterministic) return .{ .vtime_ns = 0, .branches = 0 };
    const state = try vm.det_state();
    return .{
        .vtime_ns = @divFloor(state.tsc, tsc_per_ns),
        .branches = vm.branches_offset + state.branches,
    };
}

/// One request from the guest module: a page holding { op: u32, len: u32, result: u64, data }.
fn handle_request(vm: *VM, address: u32) !void {
    if (address % page_size != 0) return error.BadGuestRequest;
    if (address + page_size > vm.memory.len) return error.BadGuestRequest;
    const page = vm.memory[address..][0..page_size];
    const operation = std.mem.readInt(u32, page[0..4], .little);
    const size = std.mem.readInt(u32, page[4..8], .little);
    if (size > page_size - request_header_size) return error.BadGuestRequest;
    const data = page[request_header_size..][0..size];
    try vm.trace("request", @as(u64, operation) << 32 | size);
    switch (operation) {
        request_operation_emit => {
            // One event per line: SDKs that buffer may write several lines at once.
            const moment_now = try vm.moment();
            var lines = std.mem.tokenizeScalar(u8, data, '\n');
            while (lines.next()) |line| {
                try vm.events.emit(moment_now, line);
                if (vm.strategy) |strategy| try strategy.event(moment_now, line);
                if (vm.moment_reached) {
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
            try vm.decide_random(data);
        },
        else => return error.BadGuestRequest,
    }
}

/// One randomness pull: the seeded default, unless a replayed tape or the strategy overrides it.
fn decide_random(vm: *VM, value: []u8) !void {
    assert(value.len > 0);
    const pull = vm.decisions.pulls;
    vm.decisions.random(value);
    assert(vm.decisions.pulls == pull + 1);
    if (vm.overrides) |overrides| {
        assert(vm.strategy == null); // A replay never consults the strategy.
        _ = try overrides.apply(pull, value);
    } else if (vm.strategy) |strategy| {
        if (value.len > Strategy.override_size_max) return; // Too large to override.
        if (try strategy.random(pull, try vm.moment(), value)) {
            if (vm.tape_fd) |fd| tape.write_override(fd, pull, value);
        }
    }
}

fn trace(vm: *VM, comptime kind: []const u8, value: u64) !void {
    const fd = vm.trace_fd orelse return;
    assert(vm.deterministic);
    const state = try vm.det_state();
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_REGS, @intFromPtr(&regs));
    var line_buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, kind ++ " {d} branches={d} rip={x}\n", .{
        value, state.branches, regs.rip,
    }) catch unreachable;
    _ = linux.write(fd, line.ptr, line.len); // Best effort: a debugging aid.
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
