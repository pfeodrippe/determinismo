// SPDX-License-Identifier: MIT
//! The built-in crash and exit properties' names, as det-init and det-core judge them: one
//! property a process (a known one counted, not failed).
pub const crash_prefix = "no process crashes: ";
pub const known_crash_prefix = "a process crash the system is known to have: ";
pub const known_exit_prefix = "an exit the system is known to make: ";
