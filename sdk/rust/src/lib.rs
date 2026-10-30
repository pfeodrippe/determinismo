// SPDX-License-Identifier: MIT
//! determinismo SDK for Rust: assertions, events and platform randomness.
//!
//! Inside determinismo everything goes through `/dev/determinismo`: events are recorded with their
//! moment, and every random value is a decision the platform can steer and replay. Outside it
//! (local runs) randomness comes from the OS and events go to the file `DETERMINISMO_SDK_LOCAL_OUTPUT`
//! (or Antithesis's `ANTITHESIS_SDK_LOCAL_OUTPUT`) names, one JSON object a line, else to stderr.
//!
//! ```ignore
//! use determinismo::{always, json};
//! let account = determinismo::random_below(10);
//! always!(total == 1000, "total balance is conserved", &json!({ "total": total }));
//! ```
//!
//! The assertion catalog: every assertion macro's message is a literal, kept in the program's
//! `det_catalog` section (the C and Zig SDKs' layout) and announced as the program starts, before
//! the assertion runs (Antithesis's catalog), so one no timeline reaches is judged too;
//! [`catalog::assertions`] lists them.
//!
//! The same API as the other SDKs (docs/SDKS.md): randomness ([`random_bytes`], [`random_u64`],
//! [`random_below`], [`random_choice`], [`random`], [`rng`], [`prng`]), named decisions
//! ([`decide`], [`random_below_named`]), [`buggify`] and [`buggify_pause`], the assertions
//! ([`always!`], [`always_or_unreachable!`], [`sometimes!`], [`reachable!`], [`unreachable!`]),
//! the guidance comparisons ([`always_greater_than!`] ...), [`always_some!`] and
//! [`sometimes_all!`], [`set_assertion_events`], [`declare`], [`catalog`], [`setup_complete`],
//! [`event`], [`output`], [`stop_faults`], [`fault`], and edge coverage (feature `coverage`).
//! Antithesis's macro names (`assert_always!`, `assert_always_greater_than_or_equal_to!`, ...)
//! and functions (`get_random`, `send_event`) work too: its code ports with a changed import.

use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

pub use serde_json::{json, Value};

const DEVICE_PATH: &str = "/dev/determinismo";
/// One event or one randomness pull per device call.
pub const MESSAGE_SIZE_MAX: usize = 4096 - 16;
/// faults.zig's control_path.
const FAULTS_CONTROL: &str = "/opt/determinismo/faults-control";

// The device ------------------------------------------------------------------------------

fn device() -> Option<&'static File> {
    static DEVICE: OnceLock<Option<File>> = OnceLock::new();
    DEVICE
        .get_or_init(|| {
            if !cfg!(feature = "full") {
                return None;
            }
            OpenOptions::new().read(true).write(true).open(DEVICE_PATH).ok() // Not inside: None.
        })
        .as_ref()
}

/// Whether this process runs inside determinismo.
pub fn inside() -> bool {
    device().is_some()
}

fn local_output() -> Option<&'static Mutex<File>> {
    static LOCAL: OnceLock<Option<Mutex<File>>> = OnceLock::new();
    LOCAL
        .get_or_init(|| {
            let path = std::env::var_os("DETERMINISMO_SDK_LOCAL_OUTPUT")
                .or_else(|| std::env::var_os("ANTITHESIS_SDK_LOCAL_OUTPUT"))?;
            let file = OpenOptions::new().create(true).append(true).open(path).ok()?;
            Some(Mutex::new(file))
        })
        .as_ref()
}

fn emit(message: &Value) {
    if !cfg!(feature = "full") {
        return;
    }
    let line = message.to_string();
    let Some(mut device) = device() else {
        match local_output() {
            Some(file) => {
                let mut file = file.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                let _ = writeln!(file, "{line}");
            }
            None => eprintln!("{line}"),
        }
        return;
    };
    let mut data = line.into_bytes();
    if data.len() > MESSAGE_SIZE_MAX {
        // The assertion must not be lost: drop the details.
        let mut shortened = message.clone();
        if let Some(assertion) = shortened.get_mut("assert").and_then(Value::as_object_mut) {
            assertion.insert("details".into(), Value::String("<details too large>".into()));
        }
        data = shortened.to_string().into_bytes();
        data.truncate(MESSAGE_SIZE_MAX);
    }
    let _ = device.write(&data); // One write, one event.
}

// Randomness ------------------------------------------------------------------------------

/// Fills `buffer` with random bytes: a platform decision inside determinismo.
pub fn random_bytes(buffer: &mut [u8]) {
    assert!(!buffer.is_empty() && buffer.len() <= MESSAGE_SIZE_MAX, "random_bytes: {} bytes", buffer.len());
    match device() {
        Some(mut device) => {
            let read = device.read(buffer).expect("random_bytes: the platform's device");
            assert_eq!(read, buffer.len(), "random_bytes: the platform gave fewer bytes");
        }
        None => os_random(buffer),
    }
}

fn os_random(buffer: &mut [u8]) {
    static URANDOM: OnceLock<Mutex<File>> = OnceLock::new();
    let file = URANDOM.get_or_init(|| Mutex::new(File::open("/dev/urandom").expect("/dev/urandom")));
    let mut file = file.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    file.read_exact(buffer).expect("/dev/urandom");
}

/// A random 64-bit integer.
pub fn random_u64() -> u64 {
    let mut bytes = [0u8; 8];
    random_bytes(&mut bytes);
    u64::from_le_bytes(bytes)
}

/// Antithesis's name for [`random_u64`].
pub fn get_random() -> u64 {
    random_u64()
}

/// A uniformly random integer in `[0, count)`.
pub fn random_below(count: u64) -> u64 {
    assert!(count > 0, "random_below: count must be positive");
    random_u64() % count
}

/// One of `items`, at random; None when there is none.
pub fn random_choice<T>(items: &[T]) -> Option<&T> {
    if items.is_empty() {
        return None;
    }
    Some(&items[random_below(items.len() as u64) as usize])
}

/// A float in `[0, 1)` from 53 random bits.
pub fn random() -> f64 {
    unit_float(random_u64())
}

fn unit_float(value: u64) -> f64 {
    (value >> 11) as f64 / (1u64 << 53) as f64
}

/// A generator whose every draw is a platform decision (steerable, replayed from tapes): one
/// request to the platform a draw. For hot loops, [`prng`].
pub fn rng() -> Rng {
    Rng
}

/// Draws from the platform, one a call (see [`rng`]).
#[derive(Clone, Copy, Debug, Default)]
pub struct Rng;

/// Antithesis's name for [`Rng`].
pub type AntithesisRng = Rng;

/// A generator the platform seeds once (SplitMix64): draws cost nothing, and replay with the
/// seed.
pub fn prng() -> Prng {
    Prng { state: random_u64() }
}

/// A SplitMix64 generator (see [`prng`]).
#[derive(Clone, Debug)]
pub struct Prng {
    state: u64,
}

impl Prng {
    /// One seeded with `seed` (a test's own).
    pub fn from_seed(seed: u64) -> Prng {
        Prng { state: seed }
    }
}

/// What both generators draw.
pub trait Generator {
    fn next_u64(&mut self) -> u64;

    /// A float in `[0, 1)`.
    fn random(&mut self) -> f64 {
        unit_float(self.next_u64())
    }

    /// An integer in `[0, count)`.
    fn below(&mut self, count: u64) -> u64 {
        assert!(count > 0, "below: count must be positive");
        self.next_u64() % count
    }

    fn choice<'a, T>(&mut self, items: &'a [T]) -> Option<&'a T> {
        if items.is_empty() {
            return None;
        }
        Some(&items[self.below(items.len() as u64) as usize])
    }

    /// Shuffles `items` in place (Fisher-Yates).
    fn shuffle<T>(&mut self, items: &mut [T]) {
        for index in (1..items.len()).rev() {
            let other = self.below(index as u64 + 1) as usize;
            items.swap(index, other);
        }
    }
}

impl Generator for Rng {
    fn next_u64(&mut self) -> u64 {
        random_u64()
    }
}

impl Generator for Prng {
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }
}

#[cfg(any(feature = "rand_core_0_6", feature = "rand_core_0_9"))]
fn fill_from(generator: &mut impl Generator, destination: &mut [u8]) {
    for chunk in destination.chunks_mut(8) {
        let bytes = generator.next_u64().to_le_bytes();
        chunk.copy_from_slice(&bytes[..chunk.len()]);
    }
}

#[cfg(any(feature = "rand_core_0_6", feature = "rand_core_0_9"))]
// `RngCore` for the rand crate's users: rand_core 0.6 also wants try_fill_bytes. Not
// `CryptoRng`: a timeline's draws replay.
macro_rules! rng_core {
    ($rand_core:ident $(, $try_fill:item)?) => {
        impl $rand_core::RngCore for Rng {
            fn next_u32(&mut self) -> u32 {
                Generator::next_u64(self) as u32
            }
            fn next_u64(&mut self) -> u64 {
                Generator::next_u64(self)
            }
            fn fill_bytes(&mut self, destination: &mut [u8]) {
                for chunk in destination.chunks_mut(MESSAGE_SIZE_MAX) {
                    random_bytes(chunk);
                }
            }
            $($try_fill)?
        }
        impl $rand_core::RngCore for Prng {
            fn next_u32(&mut self) -> u32 {
                Generator::next_u64(self) as u32
            }
            fn next_u64(&mut self) -> u64 {
                Generator::next_u64(self)
            }
            fn fill_bytes(&mut self, destination: &mut [u8]) {
                fill_from(self, destination);
            }
            $($try_fill)?
        }
    };
}

#[cfg(feature = "rand_core_0_6")]
mod rand_core_0_6_impls {
    use super::*;
    rng_core!(
        rand_core_0_6,
        fn try_fill_bytes(&mut self, destination: &mut [u8]) -> Result<(), rand_core_0_6::Error> {
            rand_core_0_6::RngCore::fill_bytes(self, destination);
            Ok(())
        }
    );
}

#[cfg(feature = "rand_core_0_9")]
mod rand_core_0_9_impls {
    use super::*;
    rng_core!(rand_core_0_9);
}

// Labeled decisions: the platform's strategies see the name and the options -------------------

/// A named decision among options (which fault, which account, which node): the index chosen,
/// a platform decision announced with the options' names.
pub fn decide<S: AsRef<str>>(name: &str, options: &[S]) -> usize {
    assert!(!options.is_empty(), "decide: no options");
    if inside() {
        let names: Vec<&str> = options.iter().map(AsRef::as_ref).collect();
        emit(&json!({ "decision": { "name": name, "options": names } }));
    }
    random_below(options.len() as u64) as usize
}

/// [`random_below`], named for strategies ("retry.jitter_ms").
pub fn random_below_named(name: &str, count: u64) -> u64 {
    if inside() {
        emit(&json!({ "decision": { "name": name, "range": count } }));
    }
    random_below(count)
}

struct BuggifyPoint {
    generator: Option<Prng>,
    until: Instant,
}

const BUGGIFY_PERIOD: Duration = Duration::from_secs(2);

fn buggify_draw<T>(name: &str, draw: impl FnOnce(&mut Prng) -> T) -> Option<T> {
    static POINTS: OnceLock<Mutex<HashMap<String, BuggifyPoint>>> = OnceLock::new();
    if !inside() {
        return None;
    }
    let now = Instant::now(); // Virtual time inside determinismo.
    let points = POINTS.get_or_init(Default::default);
    let mut points = points.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let expired = points.get(name).map_or(true, |point| now >= point.until);
    if expired {
        let active = random_below_named(&format!("buggify {name}"), 4) == 0;
        let generator = if active { Some(prng()) } else { None };
        points.insert(name.to_string(), BuggifyPoint { generator, until: now + BUGGIFY_PERIOD });
    }
    points.get_mut(name)?.generator.as_mut().map(draw)
}

/// A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
/// of two seconds (virtual time) in four, a named decision ("buggify <name>") at the stretch's
/// first evaluation; while active, it is true one evaluation in four, drawn from its own
/// generator seeded by the platform for the stretch (a hot point costs a decision a stretch).
/// Outside determinismo, always false. Where it is true, take a rare path the real system can
/// take too (a pause, a retry), never one it cannot.
pub fn buggify(name: &str) -> bool {
    buggify_draw(name, |generator| generator.below(4) == 0).unwrap_or(false)
}

/// At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
/// (rarer than buggify: pause points sit on hot paths, and a few pauses a stretch are enough for
/// the other threads to run in the window).
pub fn buggify_pause(name: &str) {
    let pause = buggify_draw(name, |generator| {
        if generator.below(32) != 0 {
            0
        } else {
            generator.below(10)
        }
    });
    if let Some(ms) = pause.filter(|&ms| ms > 0) {
        std::thread::sleep(Duration::from_millis(ms));
    }
}

// Assertions ------------------------------------------------------------------------------

/// Which evaluations become events: every one (the default: queries see each), or, as
/// Antithesis's SDKs do, each assertion's first pass and first failure in this process (for hot
/// paths: the same verdict, far fewer events).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssertionEvents {
    Every,
    First,
}

static FIRST_ONLY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Sets [`AssertionEvents`], once, at the start.
pub fn set_assertion_events(mode: AssertionEvents) {
    FIRST_ONLY.store(mode == AssertionEvents::First, std::sync::atomic::Ordering::Relaxed);
}

/// Where an assertion is in the code (the macros fill it in).
#[derive(Clone, Copy, Debug)]
pub struct Location {
    pub file: &'static str,
    pub line: u32,
    pub column: u32,
    pub function: &'static str,
}

struct AssertionState {
    seen: HashSet<(String, bool)>,
    located: HashSet<String>,
    best: HashMap<String, f64>,
}

fn assertion_state() -> std::sync::MutexGuard<'static, AssertionState> {
    static STATE: OnceLock<Mutex<AssertionState>> = OnceLock::new();
    STATE
        .get_or_init(|| {
            Mutex::new(AssertionState { seen: HashSet::new(), located: HashSet::new(), best: HashMap::new() })
        })
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[doc(hidden)]
pub fn __assert(kind: &'static str, condition: bool, message: &str, details: &Value, location: Location) {
    if !cfg!(feature = "full") {
        return;
    }
    let with_location = {
        let mut state = assertion_state();
        if FIRST_ONLY.load(std::sync::atomic::Ordering::Relaxed) && !state.seen.insert((message.to_string(), condition)) {
            return;
        }
        state.located.insert(message.to_string()) // Its location once per process: the platform keeps it.
    };
    let details = if details.is_null() { json!({}) } else { details.clone() };
    let mut body = json!({ "type": kind, "message": message, "condition": condition, "details": details });
    if with_location {
        body["location"] = json!({
            "file": location.file,
            "line": location.line,
            "column": location.column,
            "function": location.function,
        });
    }
    emit(&json!({ "assert": body }));
}

// Guidance assertions: the compared values in the details, and a guidance event telling
// strategies how far the timeline is from the interesting outcome (an `always` violated, a
// `sometimes` true): `distance`, lower is closer, 0 or less is there.

fn guidance(message: &str, distance: f64) {
    {
        let mut state = assertion_state();
        if let Some(&best) = state.best.get(message) {
            if distance >= best {
                return; // Only improvements.
            }
        }
        state.best.insert(message.to_string(), distance);
    }
    emit(&json!({ "guidance": { "message": message, "distance": distance } }));
}

/// An objective's direction ([`optimize`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Goal {
    Maximize,
    Minimize,
}

/// An objective for exploration (Antithesis's "Optimizing our way through Metroid"): `bucket`'s
/// strings and booleans split states into buckets (a leader, a phase), explored evenly, each
/// keeping the state with the best `value` by `goal`; the tree returns there and goes further
/// from it.
pub fn optimize(message: &str, bucket: &Value, value: f64, goal: Goal) {
    if !value.is_finite() {
        return;
    }
    let bucket = if bucket.is_null() { json!({}) } else { bucket.clone() };
    let goal = match goal {
        Goal::Maximize => "maximize",
        Goal::Minimize => "minimize",
    };
    emit(&json!({ "optimize": { "message": message, "bucket": bucket, "value": value, "goal": goal } }));
}

/// The numbers the guidance comparisons take.
pub trait Number: Copy + PartialOrd + Into<Value> {
    fn as_f64(self) -> f64;
}

macro_rules! numbers {
    ($($t:ty),*) => { $(impl Number for $t { fn as_f64(self) -> f64 { self as f64 } })* };
}
numbers!(i8, i16, i32, i64, isize, u8, u16, u32, u64, usize, f32, f64);

#[doc(hidden)]
pub fn __compare<T: Number>(
    kind: &'static str,
    relation: &str,
    left: T,
    right: T,
    message: &str,
    details: &Value,
    location: Location,
) {
    let (holds, margin) = match relation {
        ">" => (left > right, left.as_f64() - right.as_f64()),
        ">=" => (left >= right, left.as_f64() - right.as_f64()),
        "<" => (left < right, right.as_f64() - left.as_f64()),
        _ => (left <= right, right.as_f64() - left.as_f64()),
    };
    let merged = json!({ "left": left.into(), "right": right.into(), "details": if details.is_null() { json!({}) } else { details.clone() } });
    __assert(kind, holds, message, &merged, location);
    guidance(message, if kind == "always" { margin } else { -margin });
}

#[doc(hidden)]
pub fn __boolean(kind: &'static str, conditions: &[(&str, bool)], message: &str, details: &Value, location: Location) {
    let held = conditions.iter().filter(|(_, value)| *value).count();
    let named: serde_json::Map<String, Value> =
        conditions.iter().map(|(name, value)| (name.to_string(), Value::Bool(*value))).collect();
    let merged = json!({ "conditions": named, "details": if details.is_null() { json!({}) } else { details.clone() } });
    if kind == "always" {
        __assert("always", held > 0, message, &merged, location);
        guidance(message, held as f64);
    } else {
        __assert("sometimes", held == conditions.len(), message, &merged, location);
        guidance(message, (conditions.len() - held) as f64);
    }
}

// The catalog -----------------------------------------------------------------------------

/// The magic that tells catalog entries from the linker's padding (the C and Zig SDKs').
pub const CATALOG_MAGIC: u64 = 0x676f6c6174616364;

/// One assertion call site in the `det_catalog` section (`struct det_catalog_entry`).
#[repr(C)]
#[doc(hidden)]
pub struct CatalogEntry {
    pub magic: u64,
    pub kind: *const u8,
    pub message: *const u8,
    pub message_size: u64,
}

// Pointers to string literals: read-only, for the program's life.
unsafe impl Sync for CatalogEntry {}

// The section exists in every program with this SDK (an entry the walk skips), so its bounds do.
#[cfg(target_os = "linux")]
#[link_section = "det_catalog"]
#[used]
static CATALOG_SENTINEL: CatalogEntry =
    CatalogEntry { magic: 0, kind: std::ptr::null(), message: std::ptr::null(), message_size: 0 };

#[cfg(target_os = "linux")]
extern "C" {
    #[link_name = "__start_det_catalog"]
    static CATALOG_START: u8;
    #[link_name = "__stop_det_catalog"]
    static CATALOG_STOP: u8;
}

/// The program's assertions, and announcing them.
pub mod catalog {
    use super::*;

    /// One assertion the program declares.
    #[derive(Clone, Debug, PartialEq, Eq, Hash)]
    pub struct Assertion {
        pub kind: String,
        pub message: String,
    }

    /// The assertions in the program's code (its macros' call sites) and those [`declare`]d.
    pub fn assertions() -> Vec<Assertion> {
        let mut listed = Vec::new();
        let mut known = HashSet::new();
        for (kind, message) in section().into_iter().chain(declared()) {
            if known.insert((kind.clone(), message.clone())) {
                listed.push(Assertion { kind, message });
            }
        }
        listed
    }

    /// Writes the catalog to `out`, one JSON object a line (`{"kind","message"}`): what a program
    /// checks, for review or CI.
    pub fn write(out: &mut dyn Write) -> std::io::Result<()> {
        for assertion in assertions() {
            writeln!(out, "{}", json!({ "kind": assertion.kind, "message": assertion.message }))?;
        }
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn section() -> Vec<(String, String)> {
        let mut found = Vec::new();
        // SAFETY: the linker's bounds of the det_catalog section, which holds CatalogEntry
        // values (8-aligned) and the linker's padding, which the magic tells apart.
        unsafe {
            let mut at = std::ptr::addr_of!(CATALOG_START) as usize;
            let stop = std::ptr::addr_of!(CATALOG_STOP) as usize;
            while at + std::mem::size_of::<CatalogEntry>() <= stop {
                let entry = &*(at as *const CatalogEntry);
                if entry.magic != CATALOG_MAGIC {
                    at += 8;
                    continue;
                }
                let kind = std::ffi::CStr::from_ptr(entry.kind.cast()).to_string_lossy().into_owned();
                let bytes = std::slice::from_raw_parts(entry.message, entry.message_size as usize);
                found.push((kind, String::from_utf8_lossy(bytes).into_owned()));
                at += std::mem::size_of::<CatalogEntry>();
            }
        }
        found
    }

    #[cfg(not(target_os = "linux"))]
    fn section() -> Vec<(String, String)> {
        Vec::new() // The section is an ELF one.
    }

    pub(crate) fn declared_set() -> &'static Mutex<Vec<(String, String)>> {
        static DECLARED: OnceLock<Mutex<Vec<(String, String)>>> = OnceLock::new();
        DECLARED.get_or_init(Default::default)
    }

    fn declared() -> Vec<(String, String)> {
        declared_set().lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
    }

    /// Announces the section's assertions: inside determinismo only, and once per program file on
    /// each machine or node (a marker named after the file, as the C SDK's).
    #[cfg(target_os = "linux")]
    pub(crate) fn announce() {
        use std::os::unix::fs::MetadataExt;
        if !inside() {
            return;
        }
        if let Ok(status) = std::fs::metadata("/proc/self/exe") {
            let marker = format!("/tmp/.determinismo-catalog-rust-{:x}-{:x}", status.dev(), status.ino());
            if OpenOptions::new().write(true).create_new(true).open(&marker).is_err()
                && std::path::Path::new(&marker).exists()
            {
                return;
            }
        }
        for (kind, message) in section() {
            emit(&json!({ "assert": { "type": kind, "message": message, "hit": false } }));
        }
    }
}

/// Announces an assertion before it runs (one with a message computed at run time, or one in
/// code that never links in): one never reached is judged too.
pub fn declare(kind: &str, message: &str) {
    {
        let mut declared = catalog::declared_set().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if declared.iter().any(|(k, m)| k == kind && m == message) {
            return;
        }
        declared.push((kind.to_string(), message.to_string()));
    }
    emit(&json!({ "assert": { "type": kind, "message": message, "hit": false } }));
}

#[cfg(all(target_os = "linux", feature = "full"))]
extern "C" fn catalog_announce() {
    catalog::announce();
}

// As the program starts (a constructor, as the C SDK's), before any assertion runs.
#[cfg(all(target_os = "linux", feature = "full"))]
#[used]
#[link_section = ".init_array"]
static CATALOG_ANNOUNCE: extern "C" fn() = catalog_announce;

// Lifecycle and events ----------------------------------------------------------------------

/// The system is ready: the platform snapshots here and starts exploring.
pub fn setup_complete(details: &Value) {
    let details = if details.is_null() { json!({}) } else { details.clone() };
    emit(&json!({ "lifecycle": "setup_complete", "details": details }));
}

/// A structured event: `{"event": name, "details": details}`.
pub fn event(name: &str, details: &Value) {
    assert!(!name.is_empty(), "event: a name");
    let details = if details.is_null() { json!({}) } else { details.clone() };
    emit(&json!({ "event": name, "details": details }));
}

/// Antithesis's name for [`event`].
pub fn send_event(name: &str, details: &Value) {
    event(name, details)
}

/// Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md).
pub fn output(object: &Value) {
    emit(object);
}

// The fault injector ------------------------------------------------------------------------

fn faults_control(message: &[u8]) {
    use std::os::unix::fs::OpenOptionsExt;
    let Ok(mut fifo) = OpenOptions::new().write(true).custom_flags(0o4000 /* O_NONBLOCK */).open(FAULTS_CONTROL)
    else {
        return; // No injector running.
    };
    let _ = fifo.write(message); // Atomic: under PIPE_BUF.
}

/// A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS): faults stop for `seconds`, except clock
/// skips; 0 ends it. Only while the fault injector runs.
pub fn stop_faults(seconds: f64) {
    let ns = (seconds.max(0.0) * 1e9) as u64;
    faults_control(&ns.to_le_bytes());
}

/// A fault now, from the scenario: `fault(&json!({"kind": "pause", "node": "db",
/// "duration_ms": 2000}))`. Applied, logged and undone like a drawn one (guest/runtime/faults.zig
/// lists the kinds). Only while the fault injector runs (the drivers).
pub fn fault(request: &Value) {
    let body = request.to_string().into_bytes();
    assert!(body.len() + 8 <= 4096, "a fault request is at most 4088 bytes");
    let mut message = ((1u64 << 63) | body.len() as u64).to_le_bytes().to_vec();
    message.extend_from_slice(&body);
    faults_control(&message);
}

/// Aims the fault injector at `node` from now on, until another call ("" for none): half its
/// faults involve it, each a decision strategies see and replays repeat (a primary, a leader).
pub fn fault_aim(node: &str) {
    let name = &node.as_bytes()[..node.len().min(32)];
    let mut message = ((1u64 << 61) | name.len() as u64).to_le_bytes().to_vec();
    message.extend_from_slice(name);
    faults_control(&message);
}

// The macros --------------------------------------------------------------------------------

#[doc(hidden)]
#[macro_export]
macro_rules! __catalog_site {
    ($kind:literal, $message:literal) => {{
        #[cfg_attr(target_os = "linux", link_section = "det_catalog")]
        #[used]
        static DET_CATALOG_SITE: $crate::CatalogEntry = $crate::CatalogEntry {
            magic: $crate::CATALOG_MAGIC,
            kind: ::core::concat!($kind, "\0").as_ptr(),
            message: ::core::concat!($message, "\0").as_ptr(),
            message_size: $message.len() as u64,
        };
    }};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __location {
    () => {{
        fn f() {}
        let name = ::core::any::type_name_of_val(&f);
        $crate::Location {
            file: ::core::file!(),
            line: ::core::line!(),
            column: ::core::column!(),
            function: name.strip_suffix("::f").unwrap_or(name),
        }
    }};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __details {
    () => {
        &$crate::Value::Null
    };
    ($details:expr) => {
        $details
    };
}

/// `condition` holds every time it is evaluated (and it is: a run that never evaluates it fails
/// it too). `always!(condition, "message")` or `always!(condition, "message", &json!({...}))`.
#[macro_export]
macro_rules! always {
    ($condition:expr, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("always", $message);
        $crate::__assert("always", $condition, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// `condition` holds every time it is evaluated, if it ever is.
#[macro_export]
macro_rules! always_or_unreachable {
    ($condition:expr, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("always_or_unreachable", $message);
        $crate::__assert("always_or_unreachable", $condition, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// `condition` holds at least once.
#[macro_export]
macro_rules! sometimes {
    ($condition:expr, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("sometimes", $message);
        $crate::__assert("sometimes", $condition, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// This line runs at least once.
#[macro_export]
macro_rules! reachable {
    ($message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("reachable", $message);
        $crate::__assert("reachable", true, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// This line never runs.
#[macro_export]
macro_rules! unreachable {
    ($message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("unreachable", $message);
        $crate::__assert("unreachable", true, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __comparison {
    ($kind:literal, $relation:literal, $left:expr, $right:expr, $message:literal $(, $details:expr)?) => {{
        $crate::__catalog_site!($kind, $message);
        $crate::__compare($kind, $relation, $left, $right, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// `left > right` every time, with guidance toward a violation.
#[macro_export]
macro_rules! always_greater_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", ">", $left, $right, $message $(, $details)?)
    };
}

/// `left >= right` every time.
#[macro_export]
macro_rules! always_greater_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", ">=", $left, $right, $message $(, $details)?)
    };
}

/// `left < right` every time.
#[macro_export]
macro_rules! always_less_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", "<", $left, $right, $message $(, $details)?)
    };
}

/// `left <= right` every time.
#[macro_export]
macro_rules! always_less_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", "<=", $left, $right, $message $(, $details)?)
    };
}

/// `left > right` at least once, with guidance toward it.
#[macro_export]
macro_rules! sometimes_greater_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", ">", $left, $right, $message $(, $details)?)
    };
}

/// `left >= right` at least once.
#[macro_export]
macro_rules! sometimes_greater_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", ">=", $left, $right, $message $(, $details)?)
    };
}

/// `left < right` at least once.
#[macro_export]
macro_rules! sometimes_less_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", "<", $left, $right, $message $(, $details)?)
    };
}

/// `left <= right` at least once.
#[macro_export]
macro_rules! sometimes_less_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", "<=", $left, $right, $message $(, $details)?)
    };
}

/// At least one of the named conditions holds, every time:
/// `always_some!({ leader: a, follower: b }, "a role")`.
#[macro_export]
macro_rules! always_some {
    ({ $($name:ident : $condition:expr),+ $(,)? }, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("always", $message);
        $crate::__boolean("always", &[$((::core::stringify!($name), $condition)),+], $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// All the named conditions hold together, at least once.
#[macro_export]
macro_rules! sometimes_all {
    ({ $($name:ident : $condition:expr),+ $(,)? }, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("sometimes", $message);
        $crate::__boolean("sometimes", &[$((::core::stringify!($name), $condition)),+], $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

// Antithesis's names: its code ports with a changed import.

#[macro_export]
macro_rules! assert_always { ($($t:tt)*) => { $crate::always!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_or_unreachable { ($($t:tt)*) => { $crate::always_or_unreachable!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes { ($($t:tt)*) => { $crate::sometimes!($($t)*) }; }
#[macro_export]
macro_rules! assert_reachable { ($($t:tt)*) => { $crate::reachable!($($t)*) }; }
#[macro_export]
macro_rules! assert_unreachable { ($($t:tt)*) => { $crate::unreachable!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_greater_than { ($($t:tt)*) => { $crate::always_greater_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_greater_than_or_equal_to { ($($t:tt)*) => { $crate::always_greater_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_less_than { ($($t:tt)*) => { $crate::always_less_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_less_than_or_equal_to { ($($t:tt)*) => { $crate::always_less_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_greater_than { ($($t:tt)*) => { $crate::sometimes_greater_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_greater_than_or_equal_to { ($($t:tt)*) => { $crate::sometimes_greater_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_less_than { ($($t:tt)*) => { $crate::sometimes_less_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_less_than_or_equal_to { ($($t:tt)*) => { $crate::sometimes_less_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_some { ($($t:tt)*) => { $crate::always_some!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_all { ($($t:tt)*) => { $crate::sometimes_all!($($t)*) }; }

/// Antithesis's start-up call: nothing to do here (the catalog announces itself as the program
/// starts), kept so its code ports unchanged.
pub fn antithesis_init() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prng_replays_from_its_seed() {
        let mut a = Prng::from_seed(7);
        let mut b = Prng::from_seed(7);
        let first: Vec<u64> = (0..4).map(|_| a.next_u64()).collect();
        let second: Vec<u64> = (0..4).map(|_| b.next_u64()).collect();
        assert_eq!(first, second);
        assert!(a.below(10) < 10);
        let mut items = [1, 2, 3, 4];
        a.shuffle(&mut items);
        items.sort();
        assert_eq!(items, [1, 2, 3, 4]);
    }

    #[test]
    fn assertions_and_catalog() {
        always!(1 + 1 == 2, "arithmetic holds", &json!({ "sum": 2 }));
        sometimes!(random_below(2) < 2, "a draw below two");
        reachable!("the test runs");
        always_greater_than!(3, 2, "three beats two");
        assert_always_greater_than_or_equal_to!(3u64, 3u64, "three ties three");
        always_some!({ a: true, b: false }, "a or b");
        sometimes_all!({ a: true, b: true }, "a and b");
        optimize("backlog", &json!({ "leader": "n1" }), 3.0, Goal::Maximize);
        optimize("ignored", &Value::Null, f64::NAN, Goal::Minimize);
        declare("sometimes", "a declared one");
        let listed = catalog::assertions();
        assert!(listed.iter().any(|entry| entry.message == "a declared one"));
        if cfg!(target_os = "linux") {
            assert!(listed.iter().any(|entry| entry.message == "three beats two" && entry.kind == "always"));
        }
        let mut out = Vec::new();
        catalog::write(&mut out).unwrap();
        assert!(String::from_utf8(out).unwrap().contains("a declared one"));
    }

    #[test]
    fn decisions_outside_determinismo() {
        assert!(decide("which", &["a", "b"]) < 2);
        assert!(random_below_named("jitter", 5) < 5);
        assert!(!buggify("anywhere"));
        buggify_pause("anywhere");
        assert!(random() < 1.0);
        assert_eq!(random_choice::<u8>(&[]), None);
    }
}
