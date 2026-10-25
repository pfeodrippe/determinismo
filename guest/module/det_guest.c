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
 */
#include <linux/fs.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#define DET_DOORBELL_PORT 0x510
#define DET_OP_EMIT 1
#define DET_OP_RANDOM 2
#define DET_OP_ACTION 3
#define DET_IRQ 5
#define DET_IOCTL_WAIT_ACTION 0xde01
#define DET_MAX_DATA (PAGE_SIZE - 16)

struct det_request {
	u32 op;
	u32 len;
	u64 result;
	u8 data[DET_MAX_DATA];
} __packed;

static struct det_request *req;
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

static long det_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	long size;

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

static const struct file_operations det_fops = {
	.owner = THIS_MODULE,
	.read = det_read,
	.write = det_write,
	.unlocked_ioctl = det_ioctl,
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
	if (err) {
		free_irq(DET_IRQ, NULL);
		free_page((unsigned long)req);
	}
	return err;
}

static void __exit det_exit(void)
{
	misc_deregister(&det_dev);
	free_irq(DET_IRQ, NULL);
	free_page((unsigned long)req);
}

module_init(det_init);
module_exit(det_exit);
MODULE_LICENSE("Dual MIT/GPL");
MODULE_DESCRIPTION("determinismo guest channel");
