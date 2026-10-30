// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * determinismo guest plumbing: /dev/determinismo.
 *
 *   write(fd, json, n)   one event (JSON object) for the platform: logs, assertions, lifecycle;
 *                        with it, which process wrote it (its comm) when the page has room
 *   read(fd, buf, n)     n bytes of randomness chosen by the platform (a decision point); the
 *                        platform also learns which process asks (its comm), the decision's source
 *   ioctl(fd, DET_IOCTL_WAIT_ACTION, buf)
 *                        sleeps until the platform pushes an action (it raises DET_IRQ at the
 *                        moment it chose), then copies the action into buf and returns its size
 *
 * Each call is one request to the VMM through the doorbell port (a deterministic VM exit).
 * Test authors never use this directly; SDKs and the in-guest runtime do.
 *
 *   ioctl(fd, DET_IOCTL_DURABILITY_ARM, &arm)
 *                        arms (or, with one_in 0, disarms) a node's durability points: its
 *                        cgroup's fsyncs and sync writes. Each is then a decision (a randomness
 *                        pull: seeded, replayed), and one in `one_in` stalls there, or asks for
 *                        the node's crash there (see "Durability points" below)
 *   ioctl(fd, DET_IOCTL_DURABILITY_WAIT, &request)
 *                        sleeps until a durability point asks for its node's crash
 *   ioctl(fd, DET_IOCTL_INTERLEAVE_ARM, &arm)
 *                        arms (or, with one_in 0, disarms) a node's interleavings: one in
 *                        `one_in` of the scheduler's choices among its threads is drawn here
 *                        (see "Interleavings" below)
 *
 * And detfs (mount -t detfs detfs <dir>): a regular file, `output`, whose writes are those
 * events too. For SDKs that need a regular file (Antithesis's Go SDK truncates its output file,
 * which a device cannot be): truncating it is accepted and changes nothing. And `setup`, which
 * reads 1 once an SDK declared the system's setup complete (the composer waits for it).
 */
#include <linux/cgroup.h>
#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/kprobes.h>
#include <linux/sched/jobctl.h>
#include <linux/sched/signal.h>
#include <linux/spinlock.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#define DET_DOORBELL_PORT 0x510
#define DET_OP_EMIT 1
#define DET_OP_RANDOM 2
#define DET_OP_ACTION 3
#define DET_IRQ 5
#define DET_IOCTL_WAIT_ACTION 0xde01
#define DET_IOCTL_DURABILITY_ARM 0xde02
#define DET_IOCTL_DURABILITY_WAIT 0xde03
#define DET_IOCTL_INTERLEAVE_ARM 0xde04
#define DET_MAX_DATA (PAGE_SIZE - 16)

struct det_request {
	u32 op;
	u32 len;
	u64 result;
	u8 data[DET_MAX_DATA];
} __packed;

static struct det_request *req;
/* An SDK declared the system's setup complete (antithesis_setup): detfs's `setup` reads 1. */
static atomic_t det_sdk_setup = ATOMIC_INIT(0);
static DEFINE_MUTEX(det_lock);
static DECLARE_WAIT_QUEUE_HEAD(det_actions);

static void det_call(void);
static atomic_t det_action_pending = ATOMIC_INIT(0);

static irqreturn_t det_interrupt(int irq, void *context)
{
	atomic_set(&det_action_pending, 1);
	wake_up_interruptible(&det_actions);
	return IRQ_HANDLED;
}

static long det_durability_ioctl(unsigned int cmd, unsigned long arg);
static long det_interleave_ioctl(unsigned long arg);

static long det_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	long size;

	if (cmd == DET_IOCTL_DURABILITY_ARM || cmd == DET_IOCTL_DURABILITY_WAIT)
		return det_durability_ioctl(cmd, arg);
	if (cmd == DET_IOCTL_INTERLEAVE_ARM)
		return det_interleave_ioctl(arg);
	if (cmd != DET_IOCTL_WAIT_ACTION)
		return -ENOTTY;
	if (wait_event_interruptible(det_actions, atomic_xchg(&det_action_pending, 0)))
		return -ERESTARTSYS;
	mutex_lock(&det_lock);
	req->op = DET_OP_ACTION;
	req->len = 0;
	det_call();
	size = min_t(u32, READ_ONCE(req->len), DET_MAX_DATA);
	if (copy_to_user((void __user *)arg, req->data, size))
		size = -EFAULT;
	mutex_unlock(&det_lock);
	return size;
}

/*
 * The VMM reads and writes *req during the VM exit this causes. outl() has no memory clobber,
 * so without the barrier the compiler could keep values it stored before the call (or reuse
 * them afterwards) instead of reading what the VMM wrote.
 */
static void det_call(void)
{
	barrier();
	outl((u32)virt_to_phys(req), DET_DOORBELL_PORT);
	barrier();
}

static ssize_t det_write(struct file *f, const char __user *buf, size_t n, loff_t *off)
{
	if (n > DET_MAX_DATA)
		return -EMSGSIZE;
	mutex_lock(&det_lock);
	if (copy_from_user(req->data, buf, n)) {
		mutex_unlock(&det_lock);
		return -EFAULT;
	}
	if (!atomic_read(&det_sdk_setup) && strnstr((char *)req->data, "\"antithesis_setup\"", n))
		atomic_set(&det_sdk_setup, 1);
	req->op = DET_OP_EMIT;
	req->len = n;
	/* The source after the event, flagged in result, when it fits. */
	req->result = 0;
	if (n + TASK_COMM_LEN <= DET_MAX_DATA) {
		memset(req->data + n, 0, TASK_COMM_LEN);
		strscpy((char *)req->data + n, current->comm, TASK_COMM_LEN);
		req->result = 1;
	}
	det_call();
	mutex_unlock(&det_lock);
	return n;
}

static ssize_t det_read(struct file *f, char __user *buf, size_t n, loff_t *off)
{
	ssize_t ret;

	n = min_t(size_t, n, DET_MAX_DATA);
	mutex_lock(&det_lock);
	req->op = DET_OP_RANDOM;
	req->len = n;
	/* The source, in the data the VMM then overwrites with the answer. */
	memset(req->data, 0, TASK_COMM_LEN);
	strscpy((char *)req->data, current->comm, TASK_COMM_LEN);
	det_call();
	ret = copy_to_user(buf, req->data, n) ? -EFAULT : n;
	mutex_unlock(&det_lock);
	return ret;
}

/* Durability points ------------------------------------------------------------------------ */

/*
 * A node's fsyncs, fdatasyncs, msyncs and sync writes all reach vfs_fsync_range: its durability
 * points, where a system persists what it then acts on (a vote, an acknowledged write). A kprobe
 * on its entry sends the armed nodes' calls to det_fsync_wrapper (it changes the instruction
 * pointer, as error injection does: the wrapper runs as the function would, in process context,
 * where it may ask the VMM and sleep). Each call is then a decision (one randomness pull), and
 * the one picked, one in `one_in`:
 *   stall    holds the syncing thread for stall_ms_min to stall_ms_max ms of virtual time, while the
 *            node's other threads run: the interleavings around persisting
 *   crash    parks it before its data reaches the disk (or just after) and asks det-faults
 *            (waiting in DET_IOCTL_DURABILITY_WAIT) for the node's crash: det-faults freezes
 *            the node, disarms it (which releases the parked task, now frozen on its way out:
 *            the freeze left it a pending signal), then cuts its disk and kills it
 * The wrapper calls the real function with the probe bypassed for the task (nested calls too,
 * as overlayfs's fsync of its upper file).
 */

#define DET_DURABILITY_NODES 32
#define DET_DURABILITY_PARKED 16
#define DET_DURABILITY_BYPASS 64
#define DET_STALL 0
#define DET_CRASH_BEFORE 1
#define DET_CRASH_AFTER 2

struct det_durability_arm {
	u64 cgroup;		/* The node's cgroup (its directory's inode number in cgroup2). */
	u32 one_in;		/* A pick at one durability point in this many; 0 disarms. */
	u32 mode;		/* DET_STALL, DET_CRASH_BEFORE or DET_CRASH_AFTER. */
	u32 stall_ms_min;	/* A stall lasts from stall_ms_min to stall_ms_max ms. */
	u32 stall_ms_max;
	char node[32];		/* For events. */
} __packed;

struct det_durability_request {
	u64 cgroup;
	s32 pid;
	u32 mode;
	char comm[TASK_COMM_LEN];
} __packed;

struct det_parked {
	struct task_struct *task;
	u64 cgroup;
	bool released;
};

static DEFINE_SPINLOCK(det_durability_lock);
static struct det_durability_arm det_armed[DET_DURABILITY_NODES];
static atomic_t det_armed_count = ATOMIC_INIT(0);
static struct task_struct *det_bypassing[DET_DURABILITY_BYPASS];
static struct det_parked det_parked[DET_DURABILITY_PARKED];
/* Crash requests, oldest first: parked tasks not yet handed to det-faults. */
static struct det_durability_request det_requests[DET_DURABILITY_PARKED];
static u32 det_request_count;
static DECLARE_WAIT_QUEUE_HEAD(det_durability_requests);
static DECLARE_WAIT_QUEUE_HEAD(det_durability_released);

/* Under det_durability_lock: the armed node of `cgroup`, or NULL. */
static struct det_durability_arm *det_armed_of(u64 cgroup)
{
	int i;

	for (i = 0; i < DET_DURABILITY_NODES; i++)
		if (det_armed[i].one_in && det_armed[i].cgroup == cgroup)
			return &det_armed[i];
	return NULL;
}

/*
 * The arm of the current task's node (one_in 0 when none): its cgroup's, or an ancestor's (a
 * node's processes may sit in cgroups of their own under it, as a container runtime's do).
 */
static struct det_durability_arm det_arm_current(void)
{
	struct det_durability_arm arm = { .one_in = 0 }, *found = NULL;
	struct cgroup *cgroup;
	unsigned long flags;

	spin_lock_irqsave(&det_durability_lock, flags);
	rcu_read_lock();
	for (cgroup = task_dfl_cgroup(current); cgroup && !found; cgroup = cgroup_parent(cgroup))
		found = det_armed_of(cgroup_ino(cgroup));
	rcu_read_unlock();
	if (found)
		arm = *found;
	spin_unlock_irqrestore(&det_durability_lock, flags);
	return arm;
}

static bool det_bypassed(struct task_struct *task)
{
	int i;

	for (i = 0; i < DET_DURABILITY_BYPASS; i++)
		if (READ_ONCE(det_bypassing[i]) == task)
			return true;
	return false;
}

/* Lets the task's vfs_fsync_range calls through (the wrapper calling the real one), or not. */
static bool det_bypass(struct task_struct *task, bool on)
{
	struct task_struct *from = on ? NULL : task, *to = on ? task : NULL;
	unsigned long flags;
	bool done = false;
	int i;

	spin_lock_irqsave(&det_durability_lock, flags);
	for (i = 0; i < DET_DURABILITY_BYPASS && !done; i++) {
		if (det_bypassing[i] == from) {
			WRITE_ONCE(det_bypassing[i], to);
			done = true;
		}
	}
	spin_unlock_irqrestore(&det_durability_lock, flags);
	return done;
}

/* A randomness pull, as a process's read of /dev/determinismo (its comm is the source). */
static u64 det_pull(void)
{
	u64 value;

	mutex_lock(&det_lock);
	req->op = DET_OP_RANDOM;
	req->len = sizeof(value);
	memset(req->data, 0, TASK_COMM_LEN);
	strscpy((char *)req->data, current->comm, TASK_COMM_LEN);
	det_call();
	memcpy(&value, req->data, sizeof(value));
	mutex_unlock(&det_lock);
	return value;
}

static void det_emit_stall(const struct det_durability_arm *arm, u32 ms)
{
	char comm[TASK_COMM_LEN];
	int i;

	/* A name is any bytes: none that would end the JSON string. */
	strscpy(comm, current->comm, sizeof(comm));
	for (i = 0; comm[i]; i++)
		if (comm[i] == '"' || comm[i] == '\\' || comm[i] < 0x20)
			comm[i] = '_';
	mutex_lock(&det_lock);
	req->op = DET_OP_EMIT;
	req->len = scnprintf((char *)req->data, DET_MAX_DATA,
			     "{\"event\":\"sync_stalled\",\"details\":{\"node\":\"%.32s\","
			     "\"process\":\"%s\",\"pid\":%d,\"ms\":%u}}",
			     arm->node, comm, task_pid_nr(current), ms);
	req->result = 0;
	det_call();
	mutex_unlock(&det_lock);
}

/*
 * Asks for the node's crash and waits until it is disarmed (the crash's freeze came first, or
 * the fault ended without one). Killable: the freeze does not wake it, the disarm does.
 */
static void det_park(u64 cgroup, u32 mode)
{
	struct det_parked *slot = NULL;
	unsigned long flags;
	int i;

	spin_lock_irqsave(&det_durability_lock, flags);
	for (i = 0; i < DET_DURABILITY_PARKED && !slot; i++) {
		if (!det_parked[i].task)
			slot = &det_parked[i];
	}
	if (slot && det_request_count < DET_DURABILITY_PARKED) {
		struct det_durability_request *request = &det_requests[det_request_count++];

		*slot = (struct det_parked){ .task = current, .cgroup = cgroup };
		request->cgroup = cgroup;
		request->pid = task_pid_nr(current);
		request->mode = mode;
		strscpy(request->comm, current->comm, TASK_COMM_LEN);
	} else {
		slot = NULL;
	}
	spin_unlock_irqrestore(&det_durability_lock, flags);
	if (!slot)
		return; /* No room: no crash here. */
	wake_up_interruptible(&det_durability_requests);
	wait_event_killable(det_durability_released, READ_ONCE(slot->released));
	spin_lock_irqsave(&det_durability_lock, flags);
	slot->task = NULL;
	spin_unlock_irqrestore(&det_durability_lock, flags);
}

static int det_fsync_wrapper(struct file *file, loff_t start, loff_t end, int datasync)
{
	struct det_durability_arm arm = det_arm_current();
	bool picked = false;
	int ret;

	if (arm.one_in) {
		u64 pull = det_pull();

		picked = (u32)pull % arm.one_in == 0;
		if (picked && arm.mode == DET_STALL) {
			u32 span = arm.stall_ms_max - min(arm.stall_ms_min, arm.stall_ms_max) + 1;
			u32 ms = arm.stall_ms_min + (u32)(pull >> 32) % span;

			det_emit_stall(&arm, ms);
			schedule_timeout_killable(msecs_to_jiffies(ms));
		}
		if (picked && arm.mode == DET_CRASH_BEFORE) {
			det_park(arm.cgroup, DET_CRASH_BEFORE);
			if (fatal_signal_pending(current))
				return -EIO;
			/*
			 * The crash's freeze: frozen on the way out, then killed, never synced (restarted
			 * only if the crash failed and thawed it). Otherwise it syncs as asked.
			 */
			if (READ_ONCE(current->jobctl) & JOBCTL_TRAP_FREEZE)
				return -ERESTARTNOINTR;
		}
	}
	/* More tasks syncing at once than slots: this one waits for one (never in our guests). */
	while (!det_bypass(current, true)) {
		if (fatal_signal_pending(current))
			return -EINTR;
		schedule_timeout_killable(1);
	}
	ret = vfs_fsync_range(file, start, end, datasync);
	det_bypass(current, false);
	if (picked && arm.mode == DET_CRASH_AFTER)
		det_park(arm.cgroup, DET_CRASH_AFTER); /* Synced; frozen before it acts on it. */
	return ret;
}

static int det_fsync_pre(struct kprobe *probe, struct pt_regs *regs)
{
	if (!atomic_read(&det_armed_count) || det_bypassed(current))
		return 0;
	if (!det_arm_current().one_in)
		return 0;
	/* The call goes to the wrapper instead, with the same arguments and return address. */
	instruction_pointer_set(regs, (unsigned long)det_fsync_wrapper);
	return 1;
}

/*
 * Never called after a redirect (the wrapper runs instead of the single step). Its presence
 * keeps the probe an int3 one: an optimized probe (a jump, OPTPROBES) ignores what the
 * pre-handler returns, so its redirect would be lost.
 */
static void det_fsync_post(struct kprobe *probe, struct pt_regs *regs, unsigned long flags)
{
}

static struct kprobe det_fsync_probe = {
	.symbol_name = "vfs_fsync_range",
	.pre_handler = det_fsync_pre,
	.post_handler = det_fsync_post,
};

static long det_durability_ioctl(unsigned int cmd, unsigned long arg)
{
	struct det_durability_request request;
	struct det_durability_arm arm;
	unsigned long flags;
	int i, free = -1, count = 0;

	if (cmd == DET_IOCTL_DURABILITY_WAIT) {
		if (wait_event_interruptible(det_durability_requests, READ_ONCE(det_request_count)))
			return -ERESTARTSYS;
		spin_lock_irqsave(&det_durability_lock, flags);
		request = det_requests[0];
		for (i = 1; i < det_request_count; i++)
			det_requests[i - 1] = det_requests[i];
		det_request_count--;
		spin_unlock_irqrestore(&det_durability_lock, flags);
		return copy_to_user((void __user *)arg, &request, sizeof(request)) ? -EFAULT : 0;
	}
	if (copy_from_user(&arm, (void __user *)arg, sizeof(arm)))
		return -EFAULT;
	if (arm.mode > DET_CRASH_AFTER)
		return -EINVAL;
	arm.node[sizeof(arm.node) - 1] = 0;
	spin_lock_irqsave(&det_durability_lock, flags);
	for (i = 0; i < DET_DURABILITY_NODES; i++) {
		if (det_armed[i].one_in && det_armed[i].cgroup == arm.cgroup)
			det_armed[i].one_in = 0; /* Replaced (or disarmed). */
		if (!det_armed[i].one_in && free < 0)
			free = i;
	}
	if (arm.one_in && free >= 0)
		det_armed[free] = arm;
	for (i = 0; i < DET_DURABILITY_NODES; i++)
		count += det_armed[i].one_in != 0;
	atomic_set(&det_armed_count, count);
	if (!arm.one_in) {
		/* Disarmed: its parked tasks go on (into the freeze, when a crash comes). */
		for (i = 0; i < DET_DURABILITY_PARKED; i++)
			if (det_parked[i].task && det_parked[i].cgroup == arm.cgroup)
				WRITE_ONCE(det_parked[i].released, true);
		/* And its requests not yet taken are dropped. */
		for (i = 0; i < det_request_count;) {
			if (det_requests[i].cgroup != arm.cgroup) {
				i++;
				continue;
			}
			memmove(&det_requests[i], &det_requests[i + 1],
				(det_request_count - i - 1) * sizeof(det_requests[0]));
			det_request_count--;
		}
	}
	spin_unlock_irqrestore(&det_durability_lock, flags);
	if (!arm.one_in)
		wake_up_all(&det_durability_released);
	return arm.one_in && free < 0 ? -ENOSPC : 0;
}

/* Interleavings --------------------------------------------------------------------------- */

/*
 * The `interleave` fault: while a node is armed, the fair scheduler asks det_interleave_choose
 * at its choices among the node's threads (guest/kernel/patches/0006): which runnable one runs
 * next, whether a woken one runs before its waker goes on, whether a tick preempts the running
 * one. One choice in `one_in` is drawn here (POS-style: random priorities at each scheduling
 * point), the others left to EEVDF. The draws come from a generator seeded from the platform at
 * each arm: replayed with the timeline, and new with each fault, so branches part.
 */

struct det_interleave_arm {
	u64 cgroup;		/* The node's cgroup (its directory's inode number in cgroup2). */
	u32 one_in;		/* A choice drawn at one scheduling point in this many; 0 disarms. */
	u32 reserved;
	char node[32];		/* For events. */
} __packed;

extern int (*det_sched_choose)(struct cgroup *cgroup, unsigned int choices);

static DEFINE_SPINLOCK(det_interleave_lock);
static struct det_interleave_arm det_interleaved[DET_DURABILITY_NODES];
static u64 det_interleave_drawn[DET_DURABILITY_NODES];
static int det_interleaved_count;
static u64 det_interleave_state = 1;

/* xorshift64*: the scheduler's draws between the platform's seeds. */
static u64 det_interleave_next(void)
{
	u64 x = det_interleave_state;

	x ^= x >> 12;
	x ^= x << 25;
	x ^= x >> 27;
	det_interleave_state = x;
	return x * 0x2545f4914f6cdd1dULL;
}

/*
 * Called by the scheduler, its runqueue locked and interrupts off. One vCPU: nothing runs
 * meanwhile, and the ioctl changes the table with interrupts off, so no lock is needed here.
 */
static int det_interleave_choose(struct cgroup *cgroup, unsigned int choices)
{
	u64 draw;
	int i;

	if (!READ_ONCE(det_interleaved_count))
		return -1;
	for (; cgroup; cgroup = cgroup_parent(cgroup)) {
		u64 ino = cgroup_ino(cgroup);

		for (i = 0; i < DET_DURABILITY_NODES; i++) {
			if (!det_interleaved[i].one_in || det_interleaved[i].cgroup != ino)
				continue;
			draw = det_interleave_next();
			if ((u32)draw % det_interleaved[i].one_in)
				return -1;
			det_interleave_drawn[i]++;
			return (draw >> 32) % choices;
		}
	}
	return -1;
}

static void det_emit_interleaved(const char *node, u64 drawn)
{
	mutex_lock(&det_lock);
	req->op = DET_OP_EMIT;
	req->len = scnprintf((char *)req->data, DET_MAX_DATA,
			     "{\"event\":\"interleaved\",\"details\":{\"node\":\"%.32s\","
			     "\"choices\":%llu}}",
			     node, drawn);
	req->result = 0;
	det_call();
	mutex_unlock(&det_lock);
}

static long det_interleave_ioctl(unsigned long arg)
{
	struct det_interleave_arm arm;
	unsigned long flags;
	u64 seed = 0, drawn = 0;
	bool ended = false;
	int i, free = -1, count = 0;

	if (copy_from_user(&arm, (void __user *)arg, sizeof(arm)))
		return -EFAULT;
	arm.node[sizeof(arm.node) - 1] = 0;
	if (arm.one_in)
		seed = det_pull();
	spin_lock_irqsave(&det_interleave_lock, flags);
	for (i = 0; i < DET_DURABILITY_NODES; i++) {
		if (det_interleaved[i].one_in && det_interleaved[i].cgroup == arm.cgroup) {
			det_interleaved[i].one_in = 0; /* Replaced (or disarmed). */
			drawn = det_interleave_drawn[i];
			ended = true;
		}
		if (!det_interleaved[i].one_in && free < 0)
			free = i;
	}
	if (arm.one_in && free >= 0) {
		det_interleaved[free] = arm;
		det_interleave_drawn[free] = 0;
		det_interleave_state = seed | 1; /* Never 0: xorshift's fixed point. */
	}
	for (i = 0; i < DET_DURABILITY_NODES; i++)
		count += det_interleaved[i].one_in != 0;
	WRITE_ONCE(det_interleaved_count, count);
	spin_unlock_irqrestore(&det_interleave_lock, flags);
	/* How many choices it drew, for the fault's end (none: its threads never competed). */
	if (ended && !arm.one_in)
		det_emit_interleaved(arm.node, drawn);
	return arm.one_in && free < 0 ? -ENOSPC : 0;
}

static const struct file_operations det_fops = {
	.owner = THIS_MODULE,
	.read = det_read,
	.write = det_write,
	.unlocked_ioctl = det_ioctl,
};

/* detfs ------------------------------------------------------------------------------------ */

#define DETFS_MAGIC 0x64657466 /* "detf" */

static const struct file_operations det_output_fops = {
	.owner = THIS_MODULE,
	.write = det_write,
	.llseek = noop_llseek,
};

static ssize_t det_setup_read(struct file *f, char __user *buf, size_t n, loff_t *off)
{
	const char *state = atomic_read(&det_sdk_setup) ? "1\n" : "0\n";

	return simple_read_from_buffer(buf, n, off, state, 2);
}

static const struct file_operations det_setup_fops = {
	.owner = THIS_MODULE,
	.read = det_setup_read,
	.llseek = default_llseek,
};

static int detfs_fill_super(struct super_block *sb, struct fs_context *fc)
{
	/* Inode numbers from 2 (1 is the root), as simple_fill_super expects. */
	static const struct tree_descr files[] = {
		[2] = { "output", &det_output_fops, 0666 },
		[3] = { "setup", &det_setup_fops, 0444 },
		{ "" },
	};

	return simple_fill_super(sb, DETFS_MAGIC, files);
}

static int detfs_get_tree(struct fs_context *fc)
{
	return get_tree_single(fc, detfs_fill_super); /* One instance, wherever it is mounted. */
}

static const struct fs_context_operations detfs_context_ops = {
	.get_tree = detfs_get_tree,
};

static int detfs_init_fs_context(struct fs_context *fc)
{
	fc->ops = &detfs_context_ops;
	return 0;
}

static struct file_system_type detfs_type = {
	.owner = THIS_MODULE,
	.name = "detfs",
	.init_fs_context = detfs_init_fs_context,
	.kill_sb = kill_litter_super,
};

static struct miscdevice det_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "determinismo",
	.fops = &det_fops,
	.mode = 0666,
};

static int __init det_init(void)
{
	int err;

	/* Below 4 GiB so the 32-bit doorbell can carry its physical address. */
	req = (struct det_request *)get_zeroed_page(GFP_KERNEL | GFP_DMA32);
	if (!req)
		return -ENOMEM;
	err = request_irq(DET_IRQ, det_interrupt, 0, "determinismo", NULL);
	if (err) {
		free_page((unsigned long)req);
		return err;
	}
	err = misc_register(&det_dev);
	if (err)
		goto irq;
	err = register_filesystem(&detfs_type);
	if (err)
		goto device;
	err = register_kprobe(&det_fsync_probe);
	if (err)
		goto filesystem;
	WRITE_ONCE(det_sched_choose, det_interleave_choose);
	return 0;
filesystem:
	unregister_filesystem(&detfs_type);
device:
	misc_deregister(&det_dev);
irq:
	free_irq(DET_IRQ, NULL);
	free_page((unsigned long)req);
	return err;
}

static void __exit det_exit(void)
{
	WRITE_ONCE(det_sched_choose, NULL);
	synchronize_rcu(); /* The scheduler's calls run with preemption off. */
	unregister_kprobe(&det_fsync_probe);
	unregister_filesystem(&detfs_type);
	misc_deregister(&det_dev);
	free_irq(DET_IRQ, NULL);
	free_page((unsigned long)req);
}

module_init(det_init);
module_exit(det_exit);
MODULE_LICENSE("Dual MIT/GPL");
MODULE_DESCRIPTION("determinismo guest channel");
