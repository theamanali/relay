//! Dev tool: pretend to be a client. Connects to a host, completes the hello
//! exchange, answers pings, counts frames and optionally writes the stream back
//! out as Annex-B so it can be checked with ffprobe/ffplay:
//!
//!   probe --out capture.hevc --seconds 5
//!   probe --quality balanced --444 --10bit --out capture.hevc
//!   ffprobe -show_entries stream=profile,pix_fmt capture.hevc
//!   ffplay -f hevc capture.hevc

use std::fs::File;
use std::io::{BufWriter, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};

use relay_host::crypto::{self, SecureReader, SecureWriter};
use relay_host::protocol::{self, encoder_quality, msg, video_flags, Codec, VideoFormat};

/// CLIENT_HELLO's `encoder_quality`, by the Mac's names.
#[derive(Debug, Clone, Copy, ValueEnum)]
enum EncoderQuality {
    Fastest,
    Balanced,
    Best,
}

impl EncoderQuality {
    fn wire(self) -> u8 {
        match self {
            EncoderQuality::Fastest => encoder_quality::FASTEST,
            EncoderQuality::Balanced => encoder_quality::BALANCED,
            EncoderQuality::Best => encoder_quality::BEST,
        }
    }
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum CodecArg {
    H264,
    Hevc,
}

#[derive(Parser, Debug)]
#[command(about = "Fake Relay client for testing the host")]
struct Args {
    /// host:port to connect to
    #[arg(long, default_value = "127.0.0.1:8468")]
    addr: String,
    /// Resolution to ask for
    #[arg(long, default_value_t = 1920)]
    width: u16,
    #[arg(long, default_value_t = 1080)]
    height: u16,
    #[arg(long, default_value_t = 60)]
    hz: u16,
    /// Video bitrate to request, in Mbps
    #[arg(
        long,
        default_value_t = protocol::DEFAULT_BITRATE_MBPS,
        value_parser = clap::value_parser!(u16).range(1..=1_000)
    )]
    bitrate: u16,
    /// How long to stay connected
    #[arg(long, default_value_t = 5)]
    seconds: u64,
    /// Write the elementary stream (Annex-B) here
    #[arg(long)]
    out: Option<PathBuf>,
    /// Wiggle the mouse across the display while connected (tests input injection)
    #[arg(long)]
    wiggle: bool,
    /// Print the frames received in each second, to see capture stop and resume
    #[arg(long)]
    progress: bool,
    /// PIN to pair with if this probe identity is not paired yet
    #[arg(long)]
    pin: Option<String>,
    /// Use a fresh throwaway identity instead of the persisted probe identity
    #[arg(long)]
    fresh_identity: bool,
    /// Ask the host to forget this probe's identity instead of streaming
    #[arg(long)]
    unpair: bool,
    /// Pair if needed, then close without requesting the display
    #[arg(long, conflicts_with = "unpair")]
    pair_only: bool,
    /// Client name to send during pairing (when supported) and streaming
    #[arg(long, default_value = "probe")]
    name: String,
    /// Test older v4 clients by omitting the pairing-name extension
    #[arg(long)]
    legacy_pair: bool,
    /// Send PAIR, read PAIR_REPLY, then close without confirming (the host
    /// must count it as a failed PIN)
    #[arg(long, requires = "pin", conflicts_with = "unpair")]
    abandon_pair: bool,
    /// Offer only this codec (default: H.264 and HEVC, like the Mac)
    #[arg(long, value_enum)]
    codec: Option<CodecArg>,
    /// Send this raw CLIENT_HELLO codec mask instead (e.g. 4: a codec the
    /// host cannot encode), to test the "no codec in common" refusal
    #[arg(long, conflicts_with = "codec", hide = true)]
    codec_mask: Option<u8>,
    /// Ask for an encoder quality (CLIENT_HELLO extension; sent only when the
    /// host advertises it, and only with this, --444 or --10bit)
    #[arg(long, value_enum)]
    quality: Option<EncoderQuality>,
    /// Ask for HEVC 4:4:4 (CLIENT_HELLO extension)
    #[arg(long = "444")]
    full_color: bool,
    /// Ask for HEVC 10-bit (CLIENT_HELLO extension)
    #[arg(long = "10bit")]
    ten_bit: bool,
    /// Clock sync and per-frame timing (CAP_TIMING): send TIME_REQUESTs as
    /// the Mac does, print the offset once a second and every frame's
    /// present → submit → sent → received. With --wiggle, also input → applied.
    #[arg(long)]
    timing: bool,
    /// Ask for this Windows display scale in percent (CLIENT_HELLO
    /// `display_scale`, after the picture options; 0 = Windows' own). Sent only
    /// when the host advertises CAP_DISPLAY_SCALE. Applies to the virtual
    /// display; a --no-vdd host logs it and leaves its monitors alone
    #[arg(long)]
    display_scale: Option<u16>,
}

/// NTP's estimate from one TIME_REPLY: t1 client send, t2 host receive,
/// t3 host send, t4 client receive. `offset` is host − client.
#[derive(Debug, Clone, Copy)]
struct ClockSample {
    delay_us: i64,
    offset_us: i64,
}

impl ClockSample {
    fn new(t1: u64, t2: u64, t3: u64, t4: u64) -> Self {
        let (t1, t2, t3, t4) = (t1 as i64, t2 as i64, t3 as i64, t4 as i64);
        Self {
            delay_us: (t4 - t1) - (t3 - t2),
            offset_us: ((t2 - t1) + (t3 - t4)) / 2,
        }
    }
}

/// The last eight samples; the one with the lowest delay wins.
#[derive(Default)]
struct ClockSync {
    samples: std::collections::VecDeque<ClockSample>,
}

impl ClockSync {
    fn add(&mut self, sample: ClockSample) {
        if self.samples.len() == 8 {
            self.samples.pop_front();
        }
        self.samples.push_back(sample);
    }

    fn best(&self) -> Option<ClockSample> {
        self.samples.iter().copied().min_by_key(|s| s.delay_us)
    }

    /// A host-clock stamp on this machine's clock.
    fn to_local(&self, host_us: u64) -> Option<i64> {
        self.best().map(|s| host_us as i64 - s.offset_us)
    }
}

fn ms(us: i64) -> f64 {
    us as f64 / 1000.0
}

/// p50 / p95 of a list of microseconds, in ms.
fn percentiles(values: &mut [i64]) -> Option<(f64, f64)> {
    if values.is_empty() {
        return None;
    }
    values.sort_unstable();
    let at = |q: f64| ms(values[((values.len() - 1) as f64 * q).round() as usize]);
    Some((at(0.50), at(0.95)))
}

fn main() -> Result<()> {
    let args = Args::parse();
    let mut stream =
        TcpStream::connect(&args.addr).with_context(|| format!("connecting to {}", args.addr))?;
    stream.set_nodelay(true)?;

    // Handshake + pairing.
    let identity = if args.fresh_identity {
        crypto::Identity::generate()
    } else {
        crypto::Identity::load_or_create(&relay_host::state_dir()?.join("probe-identity.key"))?
    };
    let hs = crypto::client_handshake(&mut stream, &identity, None)?;
    let mut tx = SecureWriter::new(stream.try_clone()?, &hs.keys);
    let mut rx = SecureReader::new(stream, &hs.keys, protocol::MAX_PAYLOAD as usize);
    println!(
        "handshake ok: host {} , probe {}",
        crypto::fingerprint(&hs.peer),
        crypto::fingerprint(identity.public.as_bytes()),
    );
    // The host greets first and says whether it knows us; pairing (if
    // needed) happens before our hello.
    let (ty, _, p) = rx.recv()?;
    if ty != msg::SERVER_HELLO {
        bail!("expected SERVER_HELLO, got 0x{ty:02x}");
    }
    let (Some(version), Some(&name_len)) = (p.get(..2), p.get(2)) else {
        bail!("SERVER_HELLO of {} bytes", p.len());
    };
    let version = u16::from_be_bytes([version[0], version[1]]);
    let name_end = 3 + name_len as usize;
    let (Some(name), Some(&paired)) = (p.get(3..name_end), p.get(name_end)) else {
        bail!("SERVER_HELLO of {} bytes", p.len());
    };
    let name = String::from_utf8_lossy(name).into_owned();
    let paired = paired != 0;
    let capabilities = p.get(name_end + 1).copied().unwrap_or(0);
    let named_pairing = capabilities & protocol::CAP_PAIR_NAME != 0;
    let video_options = capabilities & protocol::CAP_VIDEO_OPTIONS != 0;
    let display_scale = capabilities & protocol::CAP_DISPLAY_SCALE != 0;
    let timing = args.timing && capabilities & protocol::CAP_TIMING != 0;
    if args.timing && !timing {
        println!("host does not advertise timing; not sending TIME_REQUEST");
    }
    println!(
        "host '{name}' protocol v{version}, {}, capabilities 0x{capabilities:02x}",
        if paired {
            "already paired"
        } else {
            "not paired"
        }
    );
    if args.unpair {
        tx.send(msg::UNPAIR, 0, &[])?;
        let (ty, _, p) = rx.recv()?;
        if ty == msg::STREAM_STOP && p.first() == Some(&protocol::stop_reason::UNPAIRED) {
            println!("host forgot this probe");
            return Ok(());
        }
        if ty == msg::STREAM_STOP {
            bail!("host stopped: {}", stop_name(p.first().copied()));
        }
        bail!("expected STREAM_STOP(UNPAIRED), got 0x{ty:02x} {p:?}");
    }
    if !paired || args.pin.is_some() {
        let pin = args
            .pin
            .clone()
            .context("not paired with this host: pass --pin <host PIN>")?;
        let pair_name = (named_pairing && !args.legacy_pair).then_some(args.name.as_str());
        crypto::client_pairing(
            &mut tx,
            &mut rx,
            &hs.keys,
            &pin,
            args.abandon_pair,
            pair_name,
        )?;
        if args.abandon_pair {
            println!("left after PAIR_REPLY without confirming; the host counts a failed PIN");
            return Ok(());
        }
        println!("paired");
    }
    if args.pair_only {
        println!("pair-only complete; not requesting the display");
        return Ok(());
    }

    let mut hello = Vec::new();
    hello.extend_from_slice(&protocol::VERSION.to_be_bytes());
    hello.extend_from_slice(&args.width.to_be_bytes());
    hello.extend_from_slice(&args.height.to_be_bytes());
    hello.extend_from_slice(&args.hz.to_be_bytes());
    hello.extend_from_slice(&args.bitrate.to_be_bytes());
    hello.push(0x01); // wants input
    hello.push(match (args.codec_mask, args.codec) {
        (Some(mask), _) => mask,
        (None, None) => Codec::H264.bit() | Codec::Hevc.bit(),
        (None, Some(CodecArg::H264)) => Codec::H264.bit(),
        (None, Some(CodecArg::Hevc)) => Codec::Hevc.bit(),
    });
    hello.extend_from_slice(&protocol::pair_name_ad(&args.name));
    let scale = args.display_scale.filter(|_| {
        display_scale || {
            println!("host does not advertise display scale; not sending it");
            false
        }
    });
    if args.quality.is_some() || args.full_color || args.ten_bit || scale.is_some() {
        let quality = args
            .quality
            .map_or(encoder_quality::DEFAULT, EncoderQuality::wire);
        let flags = (u8::from(args.full_color) * video_flags::FULL_COLOR)
            | (u8::from(args.ten_bit) * video_flags::TEN_BIT);
        if video_options {
            hello.extend_from_slice(&[quality, flags]);
            println!("picture options: quality {quality}, flags 0b{flags:02b}");
        } else {
            println!("host does not advertise picture options; sending CLIENT_HELLO without them");
        }
        // display_scale follows the picture options, which a host with
        // CAP_DISPLAY_SCALE always reads.
        if let Some(percent) = scale {
            hello.extend_from_slice(&percent.to_be_bytes());
            println!("display scale: {percent}%");
        }
    }
    tx.send(msg::CLIENT_HELLO, 0, &hello)?;

    let mut out = match &args.out {
        Some(p) => Some(BufWriter::new(File::create(p)?)),
        None => None,
    };
    let write_nals = |out: &mut Option<BufWriter<File>>, payload: &[u8]| -> Result<()> {
        if let Some(w) = out {
            let mut i = 0;
            while i + 4 <= payload.len() {
                let len = u32::from_be_bytes([
                    payload[i],
                    payload[i + 1],
                    payload[i + 2],
                    payload[i + 3],
                ]) as usize;
                i += 4;
                w.write_all(&[0, 0, 0, 1])?;
                w.write_all(&payload[i..i + len])?;
                i += len;
            }
        }
        Ok(())
    };

    let start = Instant::now();
    let deadline = start + Duration::from_secs(args.seconds);
    let (mut frames, mut keyframes, mut bytes, mut configs, mut timings) =
        (0u64, 0u64, 0u64, 0u64, 0u64);
    // FRAME_TIMING's frame_send_us: the host's encrypt + write time per frame.
    let (mut send_us_total, mut send_samples) = (0u64, 0u64);
    // capture + encode + send, the Mac latency overlay's "PC work".
    let mut work_us: Vec<u32> = Vec::new();
    let mut first_frame_at: Option<Duration> = None;
    let mut last_wiggle = Instant::now();
    let mut phase = 0u32;
    let (mut next_report, mut reported_frames) = (start + Duration::from_secs(1), 0u64);
    rx.set_read_timeout(Some(Duration::from_secs(3)))?;

    // --timing: like the Mac, five TIME_REQUESTs 50 ms apart after
    // STREAM_START, then one a second.
    let mut sync = ClockSync::default();
    let mut next_time_request: Option<Instant> = None;
    let mut time_requests = 0u32;
    let mut next_clock_report: Option<Instant> = None;
    let mut frame_received_us: Option<u64> = None;
    // When each input message after the first TIME_REQUEST was sent.
    let mut input_sent_us: Vec<u64> = Vec::new();
    let mut last_inputs_applied = 0u64;
    let (mut ext_frames, mut fresh, mut reused, mut out_of_order) = (0u64, 0u64, 0u64, 0u64);
    let (mut present_submit, mut submit_sent, mut sent_received, mut input_applied) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());

    while Instant::now() < deadline {
        if let Some(due) = next_time_request.filter(|&due| Instant::now() >= due) {
            tx.send(
                msg::TIME_REQUEST,
                0,
                &relay_host::clock::now_us().to_be_bytes(),
            )?;
            time_requests += 1;
            let gap = if time_requests < 5 { 50 } else { 1000 };
            next_time_request = Some(due + Duration::from_millis(gap));
        }
        if let Some(due) = next_clock_report.filter(|&due| Instant::now() >= due) {
            match sync.best() {
                Some(best) => println!(
                    "clock: offset {} µs, min delay {} µs ({} samples)",
                    best.offset_us,
                    best.delay_us,
                    sync.samples.len()
                ),
                None => println!("clock: no TIME_REPLY yet"),
            }
            next_clock_report = Some(due + Duration::from_secs(1));
        }
        if args.progress && Instant::now() >= next_report {
            println!(
                "t={:>3}s {:>4} frames",
                (next_report - start).as_secs(),
                frames - reported_frames
            );
            reported_frames = frames;
            next_report += Duration::from_secs(1);
        }
        let (ty, flags, p) = match rx.recv() {
            Ok(m) => m,
            Err(e)
                if e.kind() == std::io::ErrorKind::TimedOut
                    || e.kind() == std::io::ErrorKind::WouldBlock =>
            {
                println!("(no data for 3s)");
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        let received_us = relay_host::clock::now_us();
        match ty {
            msg::STREAM_START => {
                let w = u16::from_be_bytes([p[0], p[1]]);
                let h = u16::from_be_bytes([p[2], p[3]]);
                let fps = u16::from_be_bytes([p[4], p[5]]);
                let bitrate = u16::from_be_bytes([p[6], p[7]]);
                let byte = p.get(9).copied().unwrap_or(0);
                let format = VideoFormat::parse(byte);
                println!(
                    "STREAM_START {w}x{h} @ {fps} fps, {bitrate} Mbps, codec {}, video_format 0x{byte:02x} (quality {}, {}, {}-bit)",
                    p[8],
                    match format.quality {
                        encoder_quality::FASTEST => "fastest",
                        encoder_quality::BALANCED => "balanced",
                        encoder_quality::BEST => "best",
                        _ => "not reported",
                    },
                    if format.full_color { "4:4:4" } else { "4:2:0" },
                    if format.ten_bit { 10 } else { 8 }
                );
                if timing {
                    next_time_request = Some(Instant::now());
                    next_clock_report = Some(Instant::now() + Duration::from_secs(1));
                }
            }
            msg::TIME_REPLY => match protocol::TimeReply::parse(&p) {
                Some(reply) => sync.add(ClockSample::new(
                    reply.client_time_us,
                    reply.host_receive_us,
                    reply.host_send_us,
                    received_us,
                )),
                None => bail!("TIME_REPLY of {} bytes", p.len()),
            },
            msg::FRAME_TIMING_EXT => {
                let Some(t) = protocol::FrameTimingExt::parse(&p) else {
                    bail!("FRAME_TIMING_EXT of {} bytes", p.len());
                };
                timings += 1;
                ext_frames += 1;
                if t.send_us != protocol::UNKNOWN_MICROS {
                    send_us_total += u64::from(t.send_us);
                    send_samples += 1;
                }
                let parts = [t.capture_us, t.encode_us, t.send_us];
                if parts.iter().all(|&us| us != protocol::UNKNOWN_MICROS) {
                    work_us.push(parts.iter().sum());
                }
                let is_fresh = t.present_us != protocol::UNKNOWN_TIME;
                let submit_to_sent = t.sent_us as i64 - t.submit_us as i64;
                submit_sent.push(submit_to_sent);
                let present_to_submit = is_fresh.then(|| t.submit_us as i64 - t.present_us as i64);
                if let Some(us) = present_to_submit {
                    fresh += 1;
                    present_submit.push(us);
                    if us < 0 || submit_to_sent < 0 {
                        out_of_order += 1;
                    }
                } else {
                    reused += 1;
                }
                let sent_to_received = frame_received_us
                    .take()
                    .zip(sync.to_local(t.sent_us))
                    .map(|(received, sent)| received as i64 - sent);
                if let Some(us) = sent_to_received {
                    sent_received.push(us);
                }
                if t.inputs_applied > last_inputs_applied
                    && t.last_input_us != protocol::UNKNOWN_TIME
                {
                    last_inputs_applied = t.inputs_applied;
                    let sent = input_sent_us.get(t.inputs_applied as usize - 1);
                    if let (Some(&sent), Some(applied)) = (sent, sync.to_local(t.last_input_us)) {
                        input_applied.push(applied - sent as i64);
                    }
                }
                let show =
                    |us: Option<i64>| us.map_or("--".to_string(), |us| format!("{:.3}", ms(us)));
                println!(
                    "frame {:>5} {}: present→submit {} ms, submit→sent {:.3} ms, sent→received {} ms, inputs {}",
                    t.sequence,
                    if is_fresh { "fresh " } else { "reused" },
                    show(present_to_submit),
                    ms(submit_to_sent),
                    show(sent_to_received),
                    t.inputs_applied,
                );
            }
            msg::CODEC_CONFIG => {
                configs += 1;
                println!("CODEC_CONFIG {} bytes", p.len());
                write_nals(&mut out, &p)?;
            }
            msg::FRAME => {
                frame_received_us = Some(received_us);
                frames += 1;
                bytes += p.len() as u64;
                if flags & protocol::FLAG_KEYFRAME != 0 {
                    keyframes += 1;
                }
                if first_frame_at.is_none() {
                    first_frame_at = Some(start.elapsed());
                    println!(
                        "first frame after {:?} ({} bytes)",
                        start.elapsed(),
                        p.len()
                    );
                }
                write_nals(&mut out, &p)?;
            }
            msg::PING => {
                tx.send(msg::PONG, 0, &p)?;
            }
            msg::FRAME_TIMING => {
                if let Some(timing) = protocol::FrameTiming::parse(&p) {
                    timings += 1;
                    if timing.send_us != protocol::UNKNOWN_MICROS {
                        send_us_total += u64::from(timing.send_us);
                        send_samples += 1;
                    }
                    let parts = [timing.capture_us, timing.encode_us, timing.send_us];
                    if parts.iter().all(|&us| us != protocol::UNKNOWN_MICROS) {
                        work_us.push(parts.iter().sum());
                    }
                }
            }
            msg::STREAM_STOP => {
                println!("STREAM_STOP: {}", stop_name(p.first().copied()));
                break;
            }
            other => println!("message 0x{other:02x} ({} bytes)", p.len()),
        }

        if args.wiggle && last_wiggle.elapsed() > Duration::from_millis(16) {
            last_wiggle = Instant::now();
            phase = phase.wrapping_add(1);
            let t = (phase % 600) as f64 / 600.0 * std::f64::consts::TAU;
            let x = ((t.cos() * 0.4 + 0.5) * 65535.0) as u16;
            let y = ((t.sin() * 0.4 + 0.5) * 65535.0) as u16;
            let mut mm = Vec::with_capacity(4);
            mm.extend_from_slice(&x.to_be_bytes());
            mm.extend_from_slice(&y.to_be_bytes());
            tx.send(msg::MOUSE_MOVE, 0, &mm)?;
            if time_requests > 0 {
                input_sent_us.push(relay_host::clock::now_us());
            }
        }
    }

    let secs = start.elapsed().as_secs_f64();
    println!(
        "{frames} frames ({keyframes} key) in {secs:.1}s = {:.1} fps, {:.1} Mbps avg, {configs} codec configs, {timings} timing samples, host send avg {:.3} ms",
        frames as f64 / secs,
        bytes as f64 * 8.0 / secs / 1e6,
        send_us_total as f64 / send_samples.max(1) as f64 / 1000.0
    );
    if !work_us.is_empty() {
        work_us.sort_unstable();
        let at =
            |q: f64| f64::from(work_us[((work_us.len() - 1) as f64 * q).round() as usize]) / 1000.0;
        println!(
            "PC work (capture + encode + send) p50 / p95 {:.2} / {:.2} ms over {} samples",
            at(0.50),
            at(0.95),
            work_us.len()
        );
    }
    if timing {
        match sync.best() {
            Some(best) => println!(
                "clock: {time_requests} TIME_REQUESTs, {} replies kept; offset {} µs at min delay {} µs",
                sync.samples.len(),
                best.offset_us,
                best.delay_us
            ),
            None => println!("clock: {time_requests} TIME_REQUESTs, no TIME_REPLY"),
        }
        println!(
            "FRAME_TIMING_EXT on {ext_frames} frames: {fresh} fresh, {reused} reused (present = u64::MAX), {out_of_order} fresh out of order (present > submit or submit > sent)"
        );
        for (label, values) in [
            ("present → submit", &mut present_submit),
            ("submit → sent", &mut submit_sent),
            ("sent → received", &mut sent_received),
            ("input → applied", &mut input_applied),
        ] {
            let n = values.len();
            if let Some((p50, p95)) = percentiles(values) {
                println!("  {label} p50 / p95 {p50:.3} / {p95:.3} ms over {n} samples");
            }
        }
        if args.wiggle {
            println!(
                "inputs: probe sent {} after its first TIME_REQUEST, host last reported {last_inputs_applied}",
                input_sent_us.len()
            );
        }
    }
    if let Some(mut w) = out {
        w.flush()?;
        println!("wrote {}", args.out.unwrap().display());
    }
    Ok(())
}

fn stop_name(reason: Option<u8>) -> String {
    use protocol::stop_reason as r;
    match reason {
        Some(r::HOST_SHUTDOWN) => "host shutting down".into(),
        Some(r::ENCODER_FAILED) => "encoder failed".into(),
        Some(r::DISPLAY_LOST) => "display lost".into(),
        Some(r::BAD_VERSION) => "bad protocol version".into(),
        Some(r::NOT_PAIRED) => "not paired".into(),
        Some(r::UNPAIRED) => "unpaired".into(),
        Some(r::BUSY) => "busy with another client".into(),
        Some(r::BANDWIDTH_EXCEEDED) => "selected bitrate exceeds connection bandwidth".into(),
        Some(other) => format!("reason {other}"),
        None => "no reason given".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_sample_recovers_a_known_offset() {
        // Host 5 s ahead, 100 µs each way, 300 µs inside the host.
        let host = |client: u64| client + 5_000_000;
        let (t1, t4) = (1_000, 1_500);
        let sample = ClockSample::new(t1, host(1_100), host(1_400), t4);
        assert_eq!(sample.offset_us, 5_000_000);
        assert_eq!(sample.delay_us, 200);
        // Host behind, asymmetric path: the error is half the asymmetry.
        let sample = ClockSample::new(10_000, 7_300, 7_300, 10_500);
        assert_eq!(sample.delay_us, 500);
        assert_eq!(sample.offset_us, -2_950);
    }

    #[test]
    fn clock_sync_uses_the_lowest_delay_of_the_last_eight() {
        let mut sync = ClockSync::default();
        assert!(sync.to_local(1).is_none());
        sync.add(ClockSample {
            delay_us: 10,
            offset_us: 7,
        });
        for i in 0..8 {
            sync.add(ClockSample {
                delay_us: 100 + i,
                offset_us: i,
            });
        }
        // The 10 µs sample has aged out.
        assert_eq!(sync.best().unwrap().offset_us, 0);
        assert_eq!(sync.to_local(1_000), Some(1_000));
    }
}
