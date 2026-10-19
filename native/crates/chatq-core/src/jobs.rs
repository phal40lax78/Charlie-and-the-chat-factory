//! The job store as [Get-ChatqJobs](src/queue.ps1) reads it: every job file
//! in the queue folder, in the one queue order (SPEC 2.4), and the lane a
//! job's limits apply to ([Get-ChatqLane](src/watcher.ps1)). Vector:
//! native/vectors/jobs-order.json. And the two writes chatqd makes to a job
//! file (SPEC 2.4): the `-Now` wake's ([clear_defer]) and a failed pick's
//! ([fail_job]).

use crate::paths::{self, Paths};
use crate::time::{Flavour, Instant, Zone, parse_stamp_in, stamp_utc};
use crate::{fsx, json, log};
use chrono::{NaiveDate, NaiveDateTime};
use serde_json::Value;
use std::cmp::{Ordering, Reverse};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// The files [Get-ChatqJobs](src/queue.ps1) reads,
/// `Get-ChildItem <queue> -Filter *.json -File`, in the order Windows
/// PowerShell 5.1 lists them: NTFS's, by name with case folded. pwsh 7 sorts
/// by the culture's collation instead, which agrees for the names chatq
/// gives jobs. The order matters: it is the order ties keep, or lose, in
/// [order_jobs].
/// Deferred: DEFERRED.md "PowerShell's culture compares, approximated"
pub fn job_files(queue_dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(queue_dir) else {
        return Vec::new();
    };
    let mut files: Vec<(Vec<u16>, PathBuf)> = rd
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.to_ascii_lowercase()
                .ends_with(".json")
                .then(|| (n.to_uppercase().encode_utf16().collect(), e.path()))
        })
        .collect();
    files.sort();
    files.into_iter().map(|(_, p)| p).collect()
}

/// Every job [Get-ChatqJobs](src/queue.ps1) finds, in [job_files]' order and
/// not yet sorted ([get_jobs] sorts). A file holding an object with an id is
/// one job; a file holding an array is as Read-ChatqJson's `return` hands it
/// on (see `jobs_of`); a file that does not parse is left out, as
/// Read-ChatqJson's $null is. Each file is read as the PowerShell `fl` reads
/// it.
pub fn read_jobs(queue_dir: &Path, fl: Flavour) -> Vec<Value> {
    job_files(queue_dir)
        .iter()
        .filter_map(|p| crate::fsx::read_json(p, fl))
        .flat_map(jobs_of)
        .collect()
}

/// [Get-ChatqJobs](src/queue.ps1): [read_jobs] in the queue order
/// ([order_jobs]), a zoneless date read in `zone` as pwsh 7 reads it.
pub fn get_jobs(queue_dir: &Path, fl: Flavour, zone: Zone) -> Vec<Value> {
    order_jobs(read_jobs(queue_dir, fl), fl, zone)
}

/// What `if ($j -and $j.id) { $j }` passes on of one parsed file. A
/// top-level array arrives unrolled: none of it when empty, its one element
/// when it has one, else the array, whose `.id` is PowerShell's member
/// enumeration (`member_ids`) and whose elements all go on, id or not -
/// Sort-Object then drops a $null.
fn jobs_of(v: Value) -> Vec<Value> {
    let j = match v {
        Value::Array(mut a) if a.len() < 2 => match a.pop() {
            Some(one) => one,
            None => return Vec::new(),
        },
        v => v,
    };
    if !json::truthy(Some(&j)) {
        return Vec::new();
    }
    match j {
        Value::Array(items) => {
            let mut ids = Vec::new();
            member_ids(&items, &mut ids);
            let kept = match ids.len() {
                0 => false,
                1 => json::truthy(ids.first()),
                _ => true,
            };
            if kept {
                items.into_iter().filter(|x| !x.is_null()).collect()
            } else {
                Vec::new()
            }
        }
        j if json::truthy(json::get(Some(&j), "id")) => vec![j],
        _ => Vec::new(),
    }
}

/// `$array.id`: each object's id, an array id spread out, an object with
/// none giving $null; a nested array looked into; anything else giving
/// nothing.
fn member_ids(items: &[Value], out: &mut Vec<Value>) {
    for e in items {
        match e {
            Value::Object(_) => match json::get(Some(e), "id") {
                Some(Value::Array(a)) => out.extend(a.iter().cloned()),
                Some(v) => out.push(v.clone()),
                None => out.push(Value::Null),
            },
            Value::Array(a) => member_ids(a, out),
            _ => {}
        }
    }
}

/// The four keys of Get-ChatqJobs' `Sort-Object`, compared in turn.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    /// 0 put first, 1 a continue (`kind` or `rule`), 2 the rest
    group: u8,
    /// the `first` date, latest ahead
    first: Reverse<NaiveDateTime>,
    /// the `createdAt` date
    created: NaiveDateTime,
    /// `[int]seq` ranked as PowerShell compares it with the $null of a
    /// conversion that threw: below 0, above every negative number
    seq: i64,
}

/// `$job.kind -eq 'continue'` as an `if` sees it, in [Get-ChatqJobs](src/queue.ps1)'s
/// order and [Write-ChatqBoard](src/alerts.ps1)'s texts: the word in any
/// case, `$true` (the word converts to it), or an array holding either.
pub fn is_continue(v: Option<&Value>) -> bool {
    fn one(x: &Value) -> bool {
        match x {
            Value::String(s) => json::ieq(s, "continue"),
            Value::Bool(b) => *b,
            _ => false,
        }
    }
    match v {
        Some(Value::Array(a)) => a.iter().any(one),
        Some(x) => one(x),
        None => false,
    }
}

fn key_of(j: &Value, fl: Flavour, zone: Zone, zero: NaiveDateTime) -> Key {
    let get = |name| json::get(Some(j), name);
    // ConvertTo-ChatqDate, then `if ($d) { $d } else { $zero }`: a time as
    // its local wall-clock ticks, which is what DateTime compares
    let wall = |v: Option<&Value>| {
        v.and_then(Value::as_str)
            .and_then(|s| parse_stamp_in(s, fl, zone))
            .map_or(zero, |t| zone.wall(t))
    };
    let group = if json::truthy(get("first")) {
        0
    } else if is_continue(get("kind")) || json::ieq(&json::to_ps_string(get("rule")), "restart") {
        1
    } else {
        2
    };
    Key {
        group,
        first: Reverse(wall(get("first"))),
        created: wall(get("createdAt")),
        seq: ps_int(get("seq"), fl).map_or(-1, |n| 2 * i64::from(n)),
    }
}

/// The order of [Get-ChatqJobs](src/queue.ps1)'s `Sort-Object`: put first
/// (latest `first` ahead), then the continues, then the rest, each oldest
/// `createdAt` first, then by `[int]seq`. Not stable: jobs whose four keys
/// tie come out as .NET's unstable sort leaves them, which differs by
/// PowerShell - 5.1's depth-limited quicksort, which swaps even two equal
/// jobs, and pwsh 7's introsort, stable only up to 16 jobs - so both are
/// done here as each does them.
pub fn order_jobs(jobs: Vec<Value>, fl: Flavour, zone: Zone) -> Vec<Value> {
    let zero = NaiveDate::from_ymd_opt(1, 1, 1)
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .expect("DateTime.MinValue");
    let keys: Vec<Key> = jobs.iter().map(|j| key_of(j, fl, zone, zero)).collect();
    let cmp = |a: usize, b: usize| keys[a].cmp(&keys[b]);
    let mut idx: Vec<usize> = (0..jobs.len()).collect();
    sort_as(fl, &mut idx, &cmp);
    let mut slots: Vec<Option<Value>> = jobs.into_iter().map(Some).collect();
    idx.into_iter().filter_map(|i| slots[i].take()).collect()
}

/// `List<T>.Sort(IComparer<T>)` as each PowerShell's .NET does it.
fn sort_as(fl: Flavour, k: &mut [usize], c: &dyn Fn(usize, usize) -> Ordering) {
    let n = k.len();
    if n < 2 {
        return;
    }
    match fl {
        // .NET Framework's ArraySortHelper for an app that targets 4.0, as
        // powershell.exe does: depth 32, then heapsort
        Flavour::Desktop => quick_sort(k, 0, n as isize - 1, 32, c),
        Flavour::Core => intro_sort(k, 2 * (n.ilog2() + 1), c),
    }
}

fn swap_if_greater(k: &mut [usize], a: usize, b: usize, c: &dyn Fn(usize, usize) -> Ordering) {
    if a != b && c(k[a], k[b]) == Ordering::Greater {
        k.swap(a, b);
    }
}

/// .NET Framework's DepthLimitedQuickSort over `k[left..=right]`.
fn quick_sort(
    k: &mut [usize],
    mut left: isize,
    mut right: isize,
    mut depth: u32,
    c: &dyn Fn(usize, usize) -> Ordering,
) {
    loop {
        if depth == 0 {
            heap_sort(&mut k[left as usize..=right as usize], c);
            return;
        }
        let (mut i, mut j) = (left, right);
        let middle = i + ((j - i) >> 1);
        swap_if_greater(k, i as usize, middle as usize, c);
        swap_if_greater(k, i as usize, j as usize, c);
        swap_if_greater(k, middle as usize, j as usize, c);
        let x = k[middle as usize];
        loop {
            while c(k[i as usize], x) == Ordering::Less {
                i += 1;
            }
            while c(x, k[j as usize]) == Ordering::Less {
                j -= 1;
            }
            if i > j {
                break;
            }
            if i < j {
                k.swap(i as usize, j as usize);
            }
            i += 1;
            j -= 1;
            if i > j {
                break;
            }
        }
        depth -= 1;
        if j - left <= right - i {
            if left < j {
                quick_sort(k, left, j, depth, c);
            }
            left = i;
        } else {
            if i < right {
                quick_sort(k, i, right, depth, c);
            }
            right = j;
        }
        if left >= right {
            return;
        }
    }
}

/// .NET's IntroSort, as pwsh 7 runs on it.
fn intro_sort(k: &mut [usize], mut depth: u32, c: &dyn Fn(usize, usize) -> Ordering) {
    let mut size = k.len();
    while size > 1 {
        if size <= 16 {
            match size {
                2 => swap_if_greater(k, 0, 1, c),
                3 => {
                    swap_if_greater(k, 0, 1, c);
                    swap_if_greater(k, 0, 2, c);
                    swap_if_greater(k, 1, 2, c);
                }
                _ => insertion_sort(&mut k[..size], c),
            }
            return;
        }
        if depth == 0 {
            heap_sort(&mut k[..size], c);
            return;
        }
        depth -= 1;
        let p = partition(&mut k[..size], c);
        intro_sort(&mut k[p + 1..size], depth, c);
        size = p;
    }
}

/// IntroSort's PickPivotAndPartition: median of three, the pivot parked at
/// `hi - 1`.
fn partition(k: &mut [usize], c: &dyn Fn(usize, usize) -> Ordering) -> usize {
    let hi = k.len() - 1;
    let middle = hi >> 1;
    swap_if_greater(k, 0, middle, c);
    swap_if_greater(k, 0, hi, c);
    swap_if_greater(k, middle, hi, c);
    let pivot = k[middle];
    k.swap(middle, hi - 1);
    let (mut left, mut right) = (0, hi - 1);
    while left < right {
        left += 1;
        while c(k[left], pivot) == Ordering::Less {
            left += 1;
        }
        right -= 1;
        while c(pivot, k[right]) == Ordering::Less {
            right -= 1;
        }
        if left >= right {
            break;
        }
        k.swap(left, right);
    }
    if left != hi - 1 {
        k.swap(left, hi - 1);
    }
    left
}

fn insertion_sort(k: &mut [usize], c: &dyn Fn(usize, usize) -> Ordering) {
    for i in 0..k.len() - 1 {
        let t = k[i + 1];
        let mut j = i as isize;
        while j >= 0 && c(t, k[j as usize]) == Ordering::Less {
            k[j as usize + 1] = k[j as usize];
            j -= 1;
        }
        k[(j + 1) as usize] = t;
    }
}

/// The heapsort both .NETs fall back on.
fn heap_sort(k: &mut [usize], c: &dyn Fn(usize, usize) -> Ordering) {
    let n = k.len();
    for i in (1..=n / 2).rev() {
        down_heap(k, i, n, c);
    }
    for i in (2..=n).rev() {
        k.swap(0, i - 1);
        down_heap(k, 1, i - 1, c);
    }
}

fn down_heap(k: &mut [usize], mut i: usize, n: usize, c: &dyn Fn(usize, usize) -> Ordering) {
    let d = k[i - 1];
    while i <= n / 2 {
        let mut child = 2 * i;
        if child < n && c(k[child - 1], k[child]) == Ordering::Less {
            child += 1;
        }
        if c(d, k[child - 1]) != Ordering::Less {
            break;
        }
        k[i - 1] = k[child - 1];
        i = child;
    }
    k[i - 1] = d;
}

/// `[int]$x` on a value read from JSON, as [Get-ChatqJobs](src/queue.ps1)
/// ranks `seq` and [Restore-ChatqWatchState](src/watcher.ps1) reads
/// `attempts`, or None where the conversion throws: $null is 0, a bool 0 or 1, a fraction rounds half to even, a
/// string is read as an integer, `0x` hex, or a number with `,` separators,
/// a fraction or an exponent, and arrays and objects never convert. Only
/// pwsh 7 reads a blank string as 0; its other extras ('1kb', '0b101',
/// '5d') are not taken.
/// Deferred: DEFERRED.md "Numbers as a JSON read holds them"
pub fn ps_int(v: Option<&Value>, fl: Flavour) -> Option<i32> {
    match v {
        None | Some(Value::Null) => Some(0),
        Some(Value::Bool(b)) => Some(i32::from(*b)),
        Some(Value::Number(n)) => match n.as_i64() {
            Some(i) => i32::try_from(i).ok(),
            None => n.as_f64().and_then(round_to_int),
        },
        Some(Value::String(s)) => str_to_int(s, fl),
        Some(_) => None,
    }
}

/// `Convert.ToInt32(double)`: half to even, and out of range throws.
fn round_to_int(f: f64) -> Option<i32> {
    let r = f.round_ties_even();
    (r >= f64::from(i32::MIN) && r <= f64::from(i32::MAX)).then_some(r as i32)
}

fn str_to_int(s: &str, fl: Flavour) -> Option<i32> {
    if s.is_empty() {
        return Some(0);
    }
    let t = s.trim();
    if t.is_empty() {
        return (fl == Flavour::Core).then_some(0);
    }
    if let Some(h) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        if h.is_empty() || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        // Convert.ToInt32(h, 16): eight digits wrap into the negatives
        return u32::from_str_radix(h, 16).ok().map(|u| u as i32);
    }
    if let Ok(i) = t.parse::<i64>() {
        return i32::try_from(i).ok();
    }
    float_text(t)?.parse::<f64>().ok().and_then(round_to_int)
}

/// A number as `[double]` reads one - sign, digits with `,` separators,
/// fraction, exponent - with the separators dropped; None for anything else.
fn float_text(t: &str) -> Option<String> {
    let b = t.as_bytes();
    let mut i = 0;
    let mut out = String::new();
    let mut digits = 0;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        out.push(b[i] as char);
        i += 1;
    }
    if i < b.len() && b[i].is_ascii_digit() {
        while i < b.len() && (b[i].is_ascii_digit() || b[i] == b',') {
            if b[i] != b',' {
                out.push(b[i] as char);
                digits += 1;
            }
            i += 1;
        }
    }
    if i < b.len() && b[i] == b'.' {
        out.push('.');
        i += 1;
        while i < b.len() && b[i].is_ascii_digit() {
            out.push(b[i] as char);
            digits += 1;
            i += 1;
        }
    }
    if digits == 0 {
        return None;
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        out.push('e');
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            out.push(b[i] as char);
            i += 1;
        }
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            out.push(b[i] as char);
            i += 1;
        }
        if i == start {
            return None;
        }
    }
    (i == b.len()).then_some(out)
}

/// [Get-ChatqLane](src/watcher.ps1): what a limit or an overload applies
/// to - the provider, or `provider|home` when the job names a home - each
/// part as PowerShell makes a string of it.
pub fn lane(job: &Value) -> String {
    let provider = json::to_ps_string(json::get(Some(job), "provider"));
    let home = json::get(Some(job), "home");
    if json::truthy(home) {
        format!("{provider}|{}", json::to_ps_string(home))
    } else {
        provider
    }
}

/// `$job.state -in <states>`, as [Invoke-ChatqJob](src/watcher.ps1) and
/// [Invoke-ChatqWatchLoop](src/watcher.ps1) test a job: case-blind as `-in`
/// is.
pub fn state_in(job: &Value, states: &[&str]) -> bool {
    states
        .iter()
        .any(|s| json::eq_str(json::get(Some(job), "state"), s))
}

/// Any job `queued`: [Invoke-ChatqWatchLoop](src/watcher.ps1)'s `$queued`,
/// `Get-ChatqJobs | Where-Object { $_.state -eq 'queued' }`, not empty.
pub fn any_queued(jobs: &[Value]) -> bool {
    jobs.iter().any(|j| state_in(j, &["queued"]))
}

/// `$j.id` as a string puts it.
fn id_of(job: &Value) -> String {
    json::to_ps_string(json::get(Some(job), "id"))
}

/// [Find-ChatqJob](src/queue.ps1) `-Exact` over `jobs`: the one job whose id
/// is `id` trimmed, a leading `#` taken off, as `-eq` compares; None when no
/// job's is, or more than one's.
pub fn find_exact<'a>(jobs: &'a [Value], id: &str) -> Option<&'a Value> {
    let r = id.trim().trim_start_matches('#');
    if r.is_empty() {
        return None;
    }
    let mut hits = jobs.iter().filter(|j| json::ieq(&id_of(j), r));
    match (hits.next(), hits.next()) {
        (Some(j), None) => Some(j),
        _ => None,
    }
}

/// [Test-ChatqJobFound](src/watcher.ps1): whether `job`'s own id finds it
/// in `jobs`, the whole queue, as the pick will look for it. No when a
/// second job file holds the same id, or the id is blank or finds another
/// job: the pick would find nothing every pass, with no wait between.
pub fn found_by_id(jobs: &[Value], job: &Value) -> bool {
    let id = id_of(job);
    find_exact(jobs, &id).is_some_and(|f| json::ieq(&id_of(f), &id))
}

/// [Get-ChatqJobFiles](src/queue.ps1): the names of the job files holding a
/// job with this id, as `-eq` compares one, in [job_files]' order.
pub fn files_with_id(queue_dir: &Path, id: &str, fl: Flavour) -> Vec<String> {
    job_files(queue_dir)
        .into_iter()
        .filter(|p| {
            fsx::read_json(p, fl)
                .into_iter()
                .flat_map(jobs_of)
                .any(|j| json::ieq(&id_of(&j), id))
        })
        .filter_map(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .collect()
}

/// `$script:ChatqDot`
const DOT: char = '\u{00B7}';

/// The `why` a pick failure records (SPEC 2.4).
pub const FAIL_WHY: &str = "chatq error";

/// What a write chatqd makes to a job file came to (SPEC 2.4). Each is
/// Update-only: a file removed meanwhile stays removed.
#[derive(Debug, Clone, PartialEq)]
pub enum Written {
    /// Written over its file: the job as it now stands.
    Saved(Value),
    /// Nothing written: no such job in its file (removed, or never there),
    /// or nothing to write.
    Left,
    /// The file read `repaired` or `lossy`, or holds a list rather than one
    /// job object (SPEC 2.2): chatqd does not write it, and the same change
    /// goes through a `job-write` step. The job as read.
    Step(Value),
}

/// A job as its file `<queue>/<id>.json` holds it now, as
/// [Save-ChatqJob](src/queue.ps1) names the file a job is saved to.
struct Reread {
    path: PathBuf,
    raw: Vec<u8>,
    job: Value,
    /// chatqd may write it: one job object, read with no repair and no loss
    native: bool,
}

/// The job with id `id` (as [Find-ChatqJob](src/queue.ps1) `-Exact` compares
/// one) in the file it is saved to, read as `fl` reads it. None when the
/// file is gone or holds no such job.
fn reread(p: &Paths, id: &str, fl: Flavour) -> Option<Reread> {
    let path = PathBuf::from(paths::join(&p.queue, &format!("{id}.json")));
    let (raw, t) = fsx::read_json_raw(&path, fl)?;
    let v = t.value?;
    let one = v.is_object();
    let job = jobs_of(v)
        .into_iter()
        .find(|j| json::ieq(&json::to_ps_string(json::get(Some(j), "id")), id))?;
    Some(Reread {
        path,
        raw,
        job,
        native: one && !t.repaired && !t.lossy,
    })
}

impl Reread {
    /// [Save-ChatqJob](src/queue.ps1) `-Existing` of `job`. A string a 5.1
    /// `ConvertTo-Json` wrote as `"\/Date(...)\/"` is written so again, as
    /// that is the one spelling 5.1 reads as a date (SPEC 2.2 Dates).
    fn save(self, job: Value) -> io::Result<Written> {
        let mut text = json::to_pretty(&job);
        let raw = String::from_utf8_lossy(&self.raw);
        let mut dates = Vec::new();
        ms_dates(&job, &mut dates);
        for s in dates {
            let escaped = format!("\"\\/Date({})\\/\"", &s[6..s.len() - 2]);
            if raw.contains(&escaped) {
                text = text.replace(&format!("\"{s}\""), &escaped);
            }
        }
        Ok(if fsx::update_text(&self.path, &text)? {
            Written::Saved(job)
        } else {
            Written::Left
        })
    }
}

/// Every string in `v` shaped `/Date(...)/`.
fn ms_dates<'a>(v: &'a Value, out: &mut Vec<&'a str>) {
    match v {
        Value::String(s) if s.len() >= 8 && s.starts_with("/Date(") && s.ends_with(")/") => {
            out.push(s)
        }
        Value::Array(a) => a.iter().for_each(|x| ms_dates(x, out)),
        Value::Object(m) => m.values().for_each(|x| ms_dates(x, out)),
        _ => {}
    }
}

/// [Set-ChatqProp](src/alerts.ps1): the property of that name, found
/// case-blind and keeping its spelling and place, set; else added at the
/// end.
fn set_prop(job: &mut Value, name: &str, v: Value) {
    let Some(m) = job.as_object_mut() else {
        return;
    };
    let key = m
        .keys()
        .find(|k| *k == name)
        .or_else(|| m.keys().find(|k| json::member_eq(k, name)))
        .cloned();
    m.insert(key.unwrap_or_else(|| name.to_string()), v);
}

/// The `-Now` wake's write in [Invoke-ChatqWatchLoop](src/watcher.ps1), on
/// the job as its file holds it now: `if ($j.deferUntil) { Set-ChatqProp $j
/// 'deferUntil' $null; $null = Save-ChatqJob $j -Existing }`.
pub fn clear_defer(p: &Paths, id: &str, fl: Flavour) -> io::Result<Written> {
    let Some(mut f) = reread(p, id, fl) else {
        return Ok(Written::Left);
    };
    if !json::truthy(json::get(Some(&f.job), "deferUntil")) {
        return Ok(Written::Left);
    }
    if !f.native {
        return Ok(Written::Step(f.job));
    }
    let mut job = std::mem::take(&mut f.job);
    set_prop(&mut job, "deferUntil", Value::Null);
    f.save(job)
}

/// A pick failure's `complete` (SPEC 2.4, 3.6 `job-write`): `{state, why,
/// result}`, `<reason>` being the step's (SPEC 3.6 "Failure").
pub fn fail_complete(reason: &str) -> Value {
    serde_json::json!({
        "state": "failed",
        "why": FAIL_WHY,
        "result": {"kind": "failed", "reason": format!("{FAIL_WHY}: helper step {reason}")},
    })
}

/// The pick-failure write (SPEC 2.4 items 2 to 4), as the loop's catch in
/// [Invoke-ChatqWatchLoop](src/watcher.ps1) fails a job through
/// [Complete-ChatqJob](src/watcher.ps1) and
/// [Set-ChatqJobState](src/queue.ps1), but Update-only: the job read again,
/// written only while `queued` or `running`, and then its `jobs.log` line
/// ([Write-ChatqJobLog](src/queue.ps1), a failed append let go). A job with
/// no `history` is not written: Set-ChatqJobState's `$Job.history = ...`
/// throws there before the save.
pub fn fail_job(
    p: &Paths,
    id: &str,
    reason: &str,
    fl: Flavour,
    now: Instant,
) -> io::Result<Written> {
    let Some(mut f) = reread(p, id, fl) else {
        return Ok(Written::Left);
    };
    if !state_in(&f.job, &["queued", "running"]) {
        return Ok(Written::Left);
    }
    // @($Job.history): a list as it is, anything else (null too) a list of one
    let mut history = match json::get(Some(&f.job), "history") {
        None => return Ok(Written::Left),
        Some(Value::Array(a)) => a.clone(),
        Some(x) => vec![x.clone()],
    };
    if !f.native {
        return Ok(Written::Step(f.job));
    }
    let done = fail_complete(reason);
    let stamp = Value::String(stamp_utc(now));
    let mut job = std::mem::take(&mut f.job);
    set_prop(&mut job, "result", done["result"].clone());
    set_prop(&mut job, "endedAt", stamp.clone());
    let end_len = end_len(&job);
    set_prop(&mut job, "endLen", end_len);
    set_prop(&mut job, "runnerPid", Value::Null);
    set_prop(&mut job, "state", done["state"].clone());
    history.push(serde_json::json!({"at": stamp, "state": "failed", "why": FAIL_WHY}));
    set_prop(&mut job, "history", Value::Array(history));
    let w = f.save(job)?;
    if let Written::Saved(job) = &w {
        let line = format!(
            "#{} failed - {FAIL_WHY} {DOT} {}",
            json::to_ps_string(json::get(Some(job), "seq")),
            json::to_ps_string(json::get(Some(job), "title"))
        );
        let _ = log::add_log_line(&p.log_dir(), "jobs.log", &line, now);
    }
    Ok(w)
}

/// [Complete-ChatqJob](src/watcher.ps1)'s `endLen`: the length of the file
/// the job's `path` names, or null when it names none.
fn end_len(job: &Value) -> Value {
    let path = json::to_ps_string(json::get(Some(job), "path"));
    if path.is_empty() {
        return Value::Null;
    }
    fs::metadata(&path)
        .ok()
        .filter(|m| m.is_file())
        .map_or(Value::Null, |m| Value::from(m.len()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tied(fl: Flavour, n: usize) -> Vec<usize> {
        let mut k: Vec<usize> = (0..n).collect();
        sort_as(fl, &mut k, &|_, _| Ordering::Equal);
        k
    }

    #[test]
    fn ties_land_where_each_dotnet_leaves_them() {
        // as Sort-Object left n equal items, under each PowerShell
        assert_eq!(tied(Flavour::Desktop, 2), [1, 0]);
        assert_eq!(tied(Flavour::Desktop, 10), [6, 5, 7, 9, 8, 1, 0, 2, 4, 3]);
        assert_eq!(
            tied(Flavour::Desktop, 16),
            [10, 11, 8, 9, 14, 15, 12, 13, 2, 3, 0, 1, 6, 7, 4, 5]
        );
        assert_eq!(
            tied(Flavour::Desktop, 17),
            [11, 12, 9, 10, 15, 16, 13, 14, 8, 2, 3, 0, 1, 6, 7, 4, 5]
        );
        assert_eq!(
            tied(Flavour::Desktop, 40),
            [
                26, 25, 27, 29, 28, 21, 20, 22, 24, 23, 36, 35, 37, 39, 38, 31, 30, 32, 34, 33, 6,
                5, 7, 9, 8, 1, 0, 2, 4, 3, 16, 15, 17, 19, 18, 11, 10, 12, 14, 13
            ]
        );
        for n in 2..=16 {
            assert_eq!(tied(Flavour::Core, n), (0..n).collect::<Vec<_>>(), "n={n}");
        }
        assert_eq!(
            tied(Flavour::Core, 17),
            [0, 14, 13, 12, 11, 10, 9, 15, 8, 6, 5, 4, 3, 2, 1, 7, 16]
        );
        let mut forty = vec![
            0, 22, 23, 24, 25, 26, 27, 28, 21, 29, 31, 32, 33, 34, 35, 36, 37, 30,
        ];
        forty.extend([20, 19, 18]);
        forty.extend(1..=17);
        forty.extend([38, 39]);
        assert_eq!(tied(Flavour::Core, 40), forty);
    }

    #[test]
    fn both_sorts_sort() {
        // a pseudo-random spread with ties, against a stable sort's keys
        let vals: Vec<u32> = (0..300u32).map(|i| (i * 7919 + 13) % 37).collect();
        for fl in [Flavour::Desktop, Flavour::Core] {
            let mut k: Vec<usize> = (0..vals.len()).collect();
            sort_as(fl, &mut k, &|a, b| vals[a].cmp(&vals[b]));
            let got: Vec<u32> = k.iter().map(|&i| vals[i]).collect();
            let mut want = vals.clone();
            want.sort();
            assert_eq!(got, want);
        }
    }

    #[test]
    fn int_as_powershell_converts() {
        let d = Flavour::Desktop;
        for (v, want) in [
            (json!(2.5), Some(2)),
            (json!(3.5), Some(4)),
            (json!("3"), Some(3)),
            (json!(" 4 "), Some(4)),
            (json!("2.5"), Some(2)),
            (json!("0x1F"), Some(31)),
            (json!("1,000"), Some(1000)),
            (json!("1e3"), Some(1000)),
            (json!("+5"), Some(5)),
            (json!("-0"), Some(0)),
            (json!(""), Some(0)),
            (json!(true), Some(1)),
            (json!(null), Some(0)),
            (json!("abc"), None),
            (json!("1_000"), None),
            (json!("infinity"), None),
            (json!(3_000_000_000u64), None),
            (json!([1]), None),
            (json!({}), None),
        ] {
            assert_eq!(ps_int(Some(&v), d), want, "{v}");
        }
        assert_eq!(ps_int(None, d), Some(0));
        assert_eq!(ps_int(Some(&json!(" ")), d), None);
        assert_eq!(ps_int(Some(&json!(" ")), Flavour::Core), Some(0));
    }

    #[test]
    fn array_files_as_powershell_unrolls_them() {
        let n = |v: Value| jobs_of(v).len();
        assert_eq!(n(json!([])), 0);
        assert_eq!(n(json!([{"id": "a"}])), 1);
        assert_eq!(n(json!([[{"id": "a"}, {"id": "b"}]])), 2);
        assert_eq!(n(json!([{"id": "a"}, null])), 1);
        assert_eq!(n(json!([{"id": "a"}, "s"])), 2);
        assert_eq!(n(json!([{"x": 1}, {"y": 1}])), 2);
        assert_eq!(n(json!([{"id": []}, {"x": 1}])), 0);
        assert_eq!(n(json!(["x", "y"])), 0);
        assert_eq!(n(json!({"id": ""})), 0);
        assert_eq!(n(json!({"Id": "q"})), 1);
        assert_eq!(n(json!("hello")), 0);
    }

    #[test]
    fn lanes() {
        assert_eq!(lane(&json!({"provider": "claude"})), "claude");
        assert_eq!(
            lane(&json!({"provider": "codex", "home": "C:\\h"})),
            "codex|C:\\h"
        );
        assert_eq!(lane(&json!({"provider": "claude", "home": ""})), "claude");
        assert_eq!(lane(&json!("s")), "");
    }

    /// A tool root of its own with these job files in data/queue.
    fn root(name: &str, files: &[(&str, &str)]) -> Paths {
        let d = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-data/core-jobs")
            .join(name);
        let _ = fs::remove_dir_all(&d);
        let p = Paths::new(&d.to_string_lossy());
        fs::create_dir_all(p.queue_dir()).unwrap();
        for (id, text) in files {
            fs::write(p.queue_dir().join(format!("{id}.json")), text).unwrap();
        }
        p
    }

    fn file(p: &Paths, id: &str) -> Option<String> {
        fs::read_to_string(p.queue_dir().join(format!("{id}.json"))).ok()
    }

    fn jobs_log(p: &Paths) -> String {
        fs::read_to_string(p.log_dir().join("jobs.log")).unwrap_or_default()
    }

    fn now() -> Instant {
        "2026-10-18T06:03:29.4847222Z".parse().unwrap()
    }

    const STAMP: &str = "2026-10-18T06:03:29.4847222Z";

    #[test]
    fn a_job_is_found_by_its_id_as_find_chatqjob_exact_finds_it() {
        let jobs = [
            json!({"id": "d", "seq": 1}),
            json!({"id": "D", "seq": 2}),
            json!({"id": " ", "seq": 3}),
            json!({"id": " g", "seq": 4}),
            json!({"id": "g", "seq": 5}),
            json!({"id": "h", "seq": 6}),
        ];
        assert_eq!(find_exact(&jobs, "d"), None);
        assert_eq!(find_exact(&jobs, " "), None);
        assert_eq!(find_exact(&jobs, "#h").unwrap()["seq"], 6);
        assert_eq!(find_exact(&jobs, " g").unwrap()["seq"], 5);
        // twins by case, a blank id, and one that finds another job
        let found: Vec<bool> = jobs.iter().map(|j| found_by_id(&jobs, j)).collect();
        assert_eq!(found, [false, false, false, false, true, true]);
    }

    #[test]
    fn the_files_of_an_id_are_named_in_listing_order() {
        let p = root(
            "files",
            &[
                ("b", r#"{"id":"D"}"#),
                ("a", r#"{"id":"d"}"#),
                ("c", r#"{"id":"e"}"#),
                ("l", r#"[{"id":"x"},{"id":"d"}]"#),
            ],
        );
        let names = files_with_id(&p.queue_dir(), "d", Flavour::Desktop);
        assert_eq!(names, ["a.json", "b.json", "l.json"]);
    }

    #[test]
    fn a_failed_pick_is_written_as_complete_chatqjob_writes_it() {
        // Complete-ChatqJob -Existing over this file, under 5.1 and pwsh 7,
        // gave these keys in this order and these values (the reason 'x')
        let p = root("fail", &[]);
        let transcript = p.queue_dir().join("t.jsonl");
        fs::write(&transcript, "0123456789").unwrap();
        let path = transcript.to_string_lossy().replace('\\', "\\\\");
        let text = format!(
            r#"{{"id":"a","seq":7,"title":"T","state":"running","history":[{{"at":"x","state":"queued","why":null}}],"Result":1,"extra":[1],"n":2,"f":1.5,"path":"{path}","runnerPid":4242}}"#
        );
        fs::write(p.queue_dir().join("a.json"), text).unwrap();
        let w = fail_job(&p, "a", "x", Flavour::Desktop, now()).unwrap();
        let back: Value = serde_json::from_str(&file(&p, "a").unwrap()).unwrap();
        assert_eq!(w, Written::Saved(back.clone()));
        let keys: Vec<&str> = back
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        assert_eq!(
            keys,
            [
                "id",
                "seq",
                "title",
                "state",
                "history",
                "Result",
                "extra",
                "n",
                "f",
                "path",
                "runnerPid",
                "endedAt",
                "endLen"
            ]
        );
        assert_eq!(back["state"], "failed");
        assert_eq!(
            back["history"],
            json!([
                {"at": "x", "state": "queued", "why": null},
                {"at": STAMP, "state": "failed", "why": "chatq error"}
            ])
        );
        assert_eq!(
            back["Result"],
            json!({"kind": "failed", "reason": "chatq error: helper step x"})
        );
        assert_eq!(back["extra"], json!([1]));
        assert_eq!(back["n"], json!(2));
        assert_eq!(back["f"], json!(1.5));
        assert_eq!(back["runnerPid"], Value::Null);
        assert_eq!(back["endedAt"], STAMP);
        assert_eq!(back["endLen"], json!(10));
        assert!(jobs_log(&p).ends_with("  #7 failed - chatq error \u{b7} T\n"));
        assert!(!p.queue_dir().join("a.json.tmp").exists());
    }

    #[test]
    fn a_failed_pick_takes_history_as_powershell_lists_it() {
        let p = root(
            "history",
            &[
                ("b", r#"{"id":"b","seq":8,"state":"queued","history":null}"#),
                ("c", r#"{"id":"c","seq":9,"state":"queued","history":"s"}"#),
                ("e", r#"{"id":"e","seq":11,"state":"QUEUED","history":[]}"#),
                ("d", r#"{"id":"d","seq":10,"state":"queued"}"#),
            ],
        );
        let entry = json!({"at": STAMP, "state": "failed", "why": "chatq error"});
        for (id, want) in [
            ("b", json!([null, entry])),
            ("c", json!(["s", entry])),
            ("e", json!([entry])),
        ] {
            let Written::Saved(j) = fail_job(&p, id, "x", Flavour::Core, now()).unwrap() else {
                panic!("{id} not written");
            };
            assert_eq!(j["history"], want, "{id}");
            assert_eq!(j["endLen"], Value::Null, "{id}");
        }
        // no history: Set-ChatqJobState throws before the save
        let before = file(&p, "d");
        assert_eq!(
            fail_job(&p, "d", "x", Flavour::Core, now()).unwrap(),
            Written::Left
        );
        assert_eq!(file(&p, "d"), before);
        assert_eq!(jobs_log(&p).lines().count(), 3);
        assert!(jobs_log(&p).ends_with("  #11 failed - chatq error \u{b7} \n"));
    }

    #[test]
    fn a_failed_pick_leaves_a_removed_or_ended_job_alone() {
        let done = r#"{"id":"g","seq":1,"state":"done","history":[]}"#;
        let p = root("left", &[("g", done)]);
        for id in ["g", "gone"] {
            assert_eq!(
                fail_job(&p, id, "x", Flavour::Desktop, now()).unwrap(),
                Written::Left
            );
        }
        assert_eq!(file(&p, "g").as_deref(), Some(done));
        assert_eq!(file(&p, "gone"), None);
        assert_eq!(jobs_log(&p), "");
    }

    #[test]
    fn a_file_chatqd_may_not_write_goes_to_a_step() {
        let lossy = r#"{"id":"n","state":"queued","history":[],"deferUntil":"x","v":NaN}"#;
        let lone = r#"{"id":"s","state":"queued","history":[],"deferUntil":"x","title":"\ud800"}"#;
        let list = r#"[{"id":"l","state":"queued","history":[],"deferUntil":"x"}]"#;
        let p = root("step", &[("n", lossy), ("s", lone), ("l", list)]);
        for (id, text) in [("n", lossy), ("s", lone), ("l", list)] {
            for w in [
                fail_job(&p, id, "x", Flavour::Desktop, now()).unwrap(),
                clear_defer(&p, id, Flavour::Desktop).unwrap(),
            ] {
                let Written::Step(j) = w else {
                    panic!("{id}: {w:?}")
                };
                assert_eq!(j["id"], id);
            }
            assert_eq!(file(&p, id).as_deref(), Some(text));
        }
        assert_eq!(jobs_log(&p), "");
    }

    #[test]
    fn a_51_date_keeps_the_spelling_51_reads_as_a_date() {
        let text = r#"{"id":"c","state":"queued","history":[],"when":"\/Date(1760490123000)\/","said":"/Date(5)/"}"#;
        let p = root("date", &[("c", text)]);
        assert!(matches!(
            fail_job(&p, "c", "x", Flavour::Desktop, now()).unwrap(),
            Written::Saved(_)
        ));
        let back = file(&p, "c").unwrap();
        assert!(
            back.contains(r#""when": "\/Date(1760490123000)\/""#),
            "{back}"
        );
        assert!(back.contains(r#""said": "/Date(5)/""#), "{back}");
    }

    #[test]
    fn the_now_wake_clears_a_set_defer_until_and_nothing_else() {
        let set = r#"{"id":"a","seq":3,"state":"queued","deferUntil":"2026-10-18T07:00:00.0000000Z","tries":[2],"Other":{"k":1}}"#;
        let unset = r#"{"id":"b","state":"queued","deferUntil":null}"#;
        let p = root("now", &[("a", set), ("b", unset)]);
        let w = clear_defer(&p, "a", Flavour::Desktop).unwrap();
        let back: Value = serde_json::from_str(&file(&p, "a").unwrap()).unwrap();
        assert_eq!(w, Written::Saved(back.clone()));
        assert_eq!(
            back,
            json!({"id": "a", "seq": 3, "state": "queued", "deferUntil": null, "tries": [2], "Other": {"k": 1}})
        );
        for id in ["b", "gone"] {
            assert_eq!(
                clear_defer(&p, id, Flavour::Desktop).unwrap(),
                Written::Left
            );
        }
        assert_eq!(file(&p, "b").as_deref(), Some(unset));
        assert_eq!(file(&p, "gone"), None);
        assert_eq!(jobs_log(&p), "");
    }
}
