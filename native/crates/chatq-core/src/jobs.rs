//! The job store as [Get-ChatqJobs](src/queue.ps1) reads it: every job file
//! in the queue folder, in the one queue order (SPEC 2.4), and the lane a
//! job's limits apply to ([Get-ChatqLane](src/watcher.ps1)). Vector:
//! native/vectors/jobs-order.json.

use crate::json;
use crate::time::{Flavour, Zone, parse_stamp_in};
use chrono::{NaiveDate, NaiveDateTime};
use serde_json::Value;
use std::cmp::{Ordering, Reverse};
use std::fs;
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
}
