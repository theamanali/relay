//! Opt-in source timing diagnostics. No values here affect capture or the wire.
//! Capture/helper threads only update fixed counters and try_send a bounded
//! summary; a separate thread formats/writes it, outside GPU-slot ownership.
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static ENABLED: AtomicBool = AtomicBool::new(false);
static NEXT_ID: AtomicU32 = AtomicU32::new(1);
const INTERVAL: Duration = Duration::from_secs(5);
const FILE_LIMIT: usize = 8 * 1024 * 1024;
const REASONS: usize = 12;
const SAMPLE_LIMIT: usize = 16;

/// Called once at process startup, including the service's user helper.
pub fn configure(enabled: bool) {
    ENABLED.store(enabled, Ordering::Relaxed);
}
pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reason {
    Missing,
    Invalid,
    Future,
    Known,
    Empty,
    Partial,
    Busy,
    Rejected,
    Backwards,
    Published,
    SentKnown,
    SentUnknown,
}
impl Reason {
    const ALL: [Self; REASONS] = [
        Self::Missing,
        Self::Invalid,
        Self::Future,
        Self::Known,
        Self::Empty,
        Self::Partial,
        Self::Busy,
        Self::Rejected,
        Self::Backwards,
        Self::Published,
        Self::SentKnown,
        Self::SentUnknown,
    ];
}

/// Same classification as frame_present_us, with conversion supplied by the
/// caller. Pure so future/invalid/missing cannot be confused by the logger.
pub(crate) fn source_reason(qpc: Option<i64>, converted: Option<u64>, submit: u64) -> Reason {
    match (qpc, converted) {
        (None, _) => Reason::Missing,
        (Some(qpc), _) if qpc <= 0 => Reason::Invalid,
        (_, Some(source)) if source <= submit => Reason::Known,
        (_, Some(_)) => Reason::Future,
        _ => Reason::Invalid,
    }
}

/// Local association only; never serialized in Relay's TCP or helper pipe.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Trace {
    pub capture_id: u32,
    pub picture: u32,
    pub helper_sequence: Option<u64>,
    pub raw_100ns: Option<i64>,
    pub source_qpc: Option<i64>,
    /// Observation/acquisition context, never a substitute source timestamp.
    pub acquired_us: Option<u64>,
    pub fresh: bool,
    pub sample_override: Option<bool>,
}
impl Trace {
    fn selected(self) -> bool {
        self.sample_override.unwrap_or_else(|| {
            self.helper_sequence.map_or_else(
                || self.capture_id == 0 || self.picture.is_multiple_of(64),
                |n| n == 1 || n.is_multiple_of(64),
            )
        })
    }
    pub fn tag(self) -> TraceTag {
        TraceTag {
            capture_id: self.capture_id,
            picture: self.picture,
            sampled: self.selected(),
        }
    }
}

/// A small Copy token travels with the access unit. Raw samples stay in the
/// diagnostics queue, avoiding per-frame allocation or large video events.
#[derive(Clone, Copy, Debug)]
pub(crate) struct TraceTag {
    capture_id: u32,
    picture: u32,
    sampled: bool,
}
impl TraceTag {
    pub fn trace(self) -> Trace {
        Trace {
            capture_id: self.capture_id,
            picture: self.picture,
            sample_override: Some(self.sampled),
            ..Trace::default()
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Sample {
    pub reason: Reason,
    pub trace: Trace,
    pub source_us: Option<u64>,
    pub submit_us: Option<u64>,
    pub sent_us: Option<u64>,
    pub wire_sequence: Option<u64>,
    pub observed_us: u64,
}
impl Sample {
    pub fn capture(reason: Reason, trace: Trace) -> Self {
        Self {
            reason,
            trace,
            source_us: trace.source_qpc.map(crate::clock::qpc_to_us),
            submit_us: None,
            sent_us: None,
            wire_sequence: None,
            observed_us: crate::clock::now_us(),
        }
    }
}

#[derive(Clone, Debug, Default)]
struct Counts {
    reasons: [u64; REASONS],
    samples: [Option<Sample>; SAMPLE_LIMIT],
    future_bins: [u64; 8],
    future_sum_us: u128,
    future_max_us: u64,
}
impl Counts {
    fn record(&mut self, sample: Sample) {
        let index = sample.reason as usize;
        self.reasons[index] += 1;
        // Shared deterministic sequence sampling lets the helper/broker/
        // submit/wire logs identify the same picture without a pipe change.
        let selected = sample.trace.selected();
        let duplicate = self.samples.iter().flatten().any(|previous| {
            previous.reason == sample.reason
                && previous.trace.helper_sequence == sample.trace.helper_sequence
                && previous.trace.capture_id == sample.trace.capture_id
                && previous.trace.picture == sample.trace.picture
        });
        if selected && !duplicate {
            if let Some(slot) = self.samples.iter_mut().find(|slot| slot.is_none()) {
                *slot = Some(sample);
            }
        }
        if sample.reason == Reason::Future {
            if let (Some(source), Some(submit)) = (sample.source_us, sample.submit_us) {
                let lead = source.saturating_sub(submit);
                let bin = [100, 250, 500, 1_000, 2_000, 5_000, 10_000]
                    .iter()
                    .position(|&limit| lead <= limit)
                    .unwrap_or(7);
                self.future_bins[bin] += 1;
                self.future_sum_us += u128::from(lead);
                self.future_max_us = self.future_max_us.max(lead);
            }
        }
    }
}

#[derive(Debug)]
struct Summary {
    stage: &'static str,
    id: u32,
    start_us: u64,
    end_us: u64,
    dropped: u64,
    counts: Counts,
}

pub(crate) struct Reporter {
    stage: &'static str,
    pub id: u32,
    sender: SyncSender<Summary>,
    start_us: u64,
    since: Instant,
    dropped: u64,
    counts: Counts,
    startup_sent: bool,
}
impl Reporter {
    pub fn new(stage: &'static str) -> Option<Self> {
        if !enabled() {
            return None;
        }
        static WRITER: OnceLock<Option<SyncSender<Summary>>> = OnceLock::new();
        let sender = WRITER.get_or_init(start_writer).as_ref()?.clone();
        Some(Self {
            stage,
            id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
            sender,
            start_us: crate::clock::now_us(),
            since: Instant::now(),
            dropped: 0,
            counts: Counts::default(),
            startup_sent: false,
        })
    }
    pub fn record(&mut self, sample: Sample) {
        self.counts.record(sample);
        let startup = !self.startup_sent
            && sample.trace.selected()
            && matches!(
                sample.reason,
                Reason::Published
                    | Reason::Known
                    | Reason::Future
                    | Reason::Invalid
                    | Reason::Rejected
                    | Reason::Backwards
                    | Reason::SentKnown
                    | Reason::SentUnknown
            );
        if startup || self.since.elapsed() >= INTERVAL {
            self.startup_sent |= startup;
            self.flush();
        }
    }
    fn flush(&mut self) {
        let end_us = crate::clock::now_us();
        let summary = Summary {
            stage: self.stage,
            id: self.id,
            start_us: self.start_us,
            end_us,
            dropped: self.dropped,
            counts: std::mem::take(&mut self.counts),
        };
        self.dropped = if self.sender.try_send(summary).is_ok() {
            0
        } else {
            self.dropped + 1
        };
        self.start_us = end_us;
        self.since = Instant::now();
    }
}
impl Drop for Reporter {
    fn drop(&mut self) {
        self.flush();
    }
}

fn start_writer() -> Option<SyncSender<Summary>> {
    let path = std::env::temp_dir().join(format!("relay-source-timing-{}.log", std::process::id()));
    // Done once during setup, before entering capture/publish loops.
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| {
            log::warn!(
                "source timing diagnostics unavailable at {}: {e}",
                path.display()
            );
        })
        .ok()?;
    let (sender, receiver) = mpsc::sync_channel::<Summary>(8);
    std::thread::Builder::new().name("source-timing-log".into()).spawn(move || {
        let mut file = std::io::BufWriter::new(file);
        let header = format!("source timing diagnostics pid={} qpc_frequency={} max_bytes={} interval_s=5 sample_limit={} helper_sample_first=1 helper_sample_modulo=64\n",
            std::process::id(), crate::clock::qpc_frequency(), FILE_LIMIT, SAMPLE_LIMIT);
        if file.write_all(header.as_bytes()).is_err() { return; }
        let mut written = header.len();
        for summary in receiver {
            let utc_us = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_micros();
            let reasons = Reason::ALL.iter().map(|r| format!("{r:?}={}", summary.counts.reasons[*r as usize]))
                .collect::<Vec<_>>().join(" ");
            let future = summary.counts.reasons[Reason::Future as usize];
            let mut text = format!("unix_us={utc_us} stage={} id={} start_qpc_us={} end_qpc_us={} dropped_summaries={} {reasons} future_lead_us_mean={} max={} bins_le_100_250_500_1000_2000_5000_10000_gt={:?}\n",
                summary.stage, summary.id, summary.start_us, summary.end_us, summary.dropped,
                summary.counts.future_sum_us / u128::from(future.max(1)), summary.counts.future_max_us, summary.counts.future_bins);
            for sample in summary.counts.samples.iter().flatten() {
                let trace = sample.trace;
                text.push_str(&format!("sample stage={} id={} reason={:?} capture_id={} picture={} helper_seq={:?} raw_100ns={:?} source_qpc={:?} acquired_us={:?} fresh={} source_us={:?} submit_us={:?} sent_us={:?} wire_seq={:?} observed_us={}\n",
                    summary.stage, summary.id, sample.reason, trace.capture_id, trace.picture,
                    trace.helper_sequence, trace.raw_100ns, trace.source_qpc, trace.acquired_us,
                    trace.fresh, sample.source_us, sample.submit_us, sample.sent_us,
                    sample.wire_sequence, sample.observed_us));
            }
            if written + text.len() > FILE_LIMIT { break; }
            if file.write_all(text.as_bytes()).and_then(|_| file.flush()).is_err() { break; }
            written += text.len();
        }
    }).ok()?;
    log::info!("source timing diagnostics: {}", path.display());
    Some(sender)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn distinguishes_missing_invalid_future_and_ordered_source() {
        assert_eq!(source_reason(None, None, 100), Reason::Missing);
        assert_eq!(source_reason(Some(0), Some(0), 100), Reason::Invalid);
        assert_eq!(source_reason(Some(-1), Some(0), 100), Reason::Invalid);
        assert_eq!(source_reason(Some(1), None, 100), Reason::Invalid);
        assert_eq!(source_reason(Some(1), Some(99), 100), Reason::Known);
        assert_eq!(source_reason(Some(1), Some(100), 100), Reason::Known);
        assert_eq!(source_reason(Some(1), Some(101), 100), Reason::Future);
    }
    fn future(lead: u64) -> Sample {
        Sample {
            reason: Reason::Future,
            trace: Trace::default(),
            source_us: Some(100 + lead),
            submit_us: Some(100),
            sent_us: None,
            wire_sequence: None,
            observed_us: 0,
        }
    }
    #[test]
    fn counts_every_future_lead_but_bounds_representative_samples() {
        let mut counts = Counts::default();
        for lead in [1, 100, 101, 251, 501, 1_001, 2_001, 5_001, 10_001] {
            counts.record(future(lead));
        }
        assert_eq!(counts.future_bins, [2, 1, 1, 1, 1, 1, 1, 1]);
        assert_eq!(counts.reasons[Reason::Future as usize], 9);
        assert_eq!(counts.future_max_us, 10_001);
        assert_eq!(counts.future_sum_us, 18_958);
        assert_eq!(counts.samples.iter().flatten().count(), 1);
    }
    #[test]
    fn shared_sequence_samples_are_bounded_and_duplicate_polls_do_not_fill_buffer() {
        let mut counts = Counts::default();
        for sequence in 1..=2_000 {
            let mut sample = future(10);
            sample.trace.helper_sequence = Some(sequence);
            for _ in 0..10 {
                counts.record(sample);
            }
        }
        assert_eq!(counts.reasons[Reason::Future as usize], 20_000);
        let samples: Vec<_> = counts.samples.iter().flatten().collect();
        assert_eq!(samples.len(), SAMPLE_LIMIT);
        assert_eq!(samples[0].trace.helper_sequence, Some(1));
        assert_eq!(samples[15].trace.helper_sequence, Some(960));
        assert!(samples.iter().all(|s| {
            let n = s.trace.helper_sequence.unwrap();
            n == 1 || n.is_multiple_of(64)
        }));
    }
    #[test]
    fn saturated_writer_drops_a_summary_and_reports_the_gap_without_waiting() {
        let (sender, receiver) = mpsc::sync_channel(1);
        let mut reporter = Reporter {
            stage: "test",
            id: 1,
            sender,
            start_us: 0,
            since: Instant::now(),
            dropped: 0,
            counts: Counts::default(),
            startup_sent: false,
        };
        reporter.counts.record(future(10));
        reporter.flush();
        reporter.counts.record(future(20));
        reporter.flush(); // queue is full: must return without a receiver.
        assert_eq!(reporter.dropped, 1);
        assert_eq!(receiver.try_recv().unwrap().counts.future_max_us, 10);
        reporter.counts.record(future(30));
        reporter.flush();
        let next = receiver.try_recv().unwrap();
        assert_eq!(next.dropped, 1);
        assert_eq!(next.counts.future_max_us, 30);
        assert_eq!(reporter.dropped, 0);
    }
    #[test]
    fn startup_source_sample_is_queued_before_a_short_lived_helper_can_exit() {
        let (sender, receiver) = mpsc::sync_channel(2);
        let mut reporter = Reporter {
            stage: "test",
            id: 1,
            sender,
            start_us: 0,
            since: Instant::now(),
            dropped: 0,
            counts: Counts::default(),
            startup_sent: false,
        };
        reporter.record(future(10));
        assert_eq!(receiver.try_recv().unwrap().counts.future_max_us, 10);
        reporter.record(future(20));
        assert!(matches!(
            receiver.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
    }
    #[test]
    fn picture_tag_preserves_helper_sample_selection_through_encoder_output() {
        let source = Trace {
            capture_id: 7,
            picture: 9,
            helper_sequence: Some(64),
            source_qpc: Some(123),
            raw_100ns: Some(456),
            ..Trace::default()
        };
        let wire = source.tag().trace();
        assert!(source.selected());
        assert!(
            wire.selected(),
            "wire must sample the same picture despite a different sequence base"
        );
        assert_eq!((wire.capture_id, wire.picture), (7, 9));
        assert_eq!(
            wire.raw_100ns, None,
            "raw timing is not copied or invented on the wire path"
        );
        let skipped = Trace {
            helper_sequence: Some(65),
            ..source
        };
        assert!(!skipped.selected());
        assert!(!skipped.tag().trace().selected());
    }
}
