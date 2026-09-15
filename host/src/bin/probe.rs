//! Dev tool: pretend to be a client. Connects to a host, completes the hello
//! exchange, answers pings, counts frames and optionally writes the stream back
//! out as Annex-B so it can be checked with ffprobe/ffplay:
//!
//!   probe --out capture.hevc --seconds 5
//!   ffplay -f hevc capture.hevc

use std::fs::File;
use std::io::{BufWriter, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::Parser;

use traveldisplay_host::crypto::{self, SecureReader, SecureWriter};
use traveldisplay_host::protocol::{self, msg, Codec};

#[derive(Parser, Debug)]
#[command(about = "Fake TravelDisplay client for testing the host")]
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
    /// How long to stay connected
    #[arg(long, default_value_t = 5)]
    seconds: u64,
    /// Write the elementary stream (Annex-B) here
    #[arg(long)]
    out: Option<PathBuf>,
    /// Wiggle the mouse across the display while connected (tests input injection)
    #[arg(long)]
    wiggle: bool,
    /// PIN to pair with if this probe identity is not paired yet
    #[arg(long)]
    pin: Option<String>,
    /// Use a fresh throwaway identity instead of the persisted probe identity
    #[arg(long)]
    fresh_identity: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let mut stream = TcpStream::connect(&args.addr).with_context(|| format!("connecting to {}", args.addr))?;
    stream.set_nodelay(true)?;

    // Handshake + pairing.
    let identity = if args.fresh_identity {
        crypto::Identity::generate()
    } else {
        let dir = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).context("LOCALAPPDATA")?;
        crypto::Identity::load_or_create(&dir.join("TravelDisplay").join("probe-identity.key"))?
    };
    let hs = crypto::client_handshake(&mut stream, &identity, None)?;
    let mut tx = SecureWriter::new(stream.try_clone()?, &hs.keys.c2h);
    let mut rx = SecureReader::new(stream, &hs.keys.h2c);
    println!(
        "handshake ok: host {} , probe {} , {}",
        crypto::fingerprint(&hs.peer),
        crypto::fingerprint(identity.public.as_bytes()),
        if hs.paired { "already paired" } else { "not paired" }
    );
    // The host greets first; pairing (if needed) happens before our hello.
    let (ty, _, p) = rx.recv()?;
    if ty != msg::SERVER_HELLO {
        bail!("expected SERVER_HELLO, got 0x{ty:02x}");
    }
    let version = u16::from_be_bytes([p[0], p[1]]);
    let name = String::from_utf8_lossy(&p[3..3 + p[2] as usize]).into_owned();
    println!("host '{name}' protocol v{version}");
    if !hs.paired || args.pin.is_some() {
        let pin = args.pin.clone().context("not paired with this host: pass --pin <host PIN>")?;
        crypto::pair_as_client(&mut tx, &mut rx, &hs.keys, &pin)?;
        println!("paired");
    }

    let mut hello = Vec::new();
    hello.extend_from_slice(&protocol::VERSION.to_be_bytes());
    hello.extend_from_slice(&args.width.to_be_bytes());
    hello.extend_from_slice(&args.height.to_be_bytes());
    hello.extend_from_slice(&args.hz.to_be_bytes());
    hello.push(0x01); // wants input
    hello.push(Codec::H264.bit() | Codec::Hevc.bit());
    hello.push(5);
    hello.extend_from_slice(b"probe");
    tx.send(msg::CLIENT_HELLO, 0, &hello)?;

    let mut out = match &args.out {
        Some(p) => Some(BufWriter::new(File::create(p)?)),
        None => None,
    };
    let write_nals = |out: &mut Option<BufWriter<File>>, payload: &[u8]| -> Result<()> {
        if let Some(w) = out {
            let mut i = 0;
            while i + 4 <= payload.len() {
                let len = u32::from_be_bytes([payload[i], payload[i + 1], payload[i + 2], payload[i + 3]]) as usize;
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
    let (mut frames, mut keyframes, mut bytes, mut configs) = (0u64, 0u64, 0u64, 0u64);
    let mut first_frame_at: Option<Duration> = None;
    let mut last_wiggle = Instant::now();
    let mut phase = 0u32;
    rx.set_read_timeout(Some(Duration::from_secs(3)))?;

    while Instant::now() < deadline {
        let (ty, flags, p) = match rx.recv() {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut || e.kind() == std::io::ErrorKind::WouldBlock => {
                println!("(no data for 3s)");
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        match ty {
            msg::STREAM_START => {
                let w = u16::from_be_bytes([p[0], p[1]]);
                let h = u16::from_be_bytes([p[2], p[3]]);
                let fps = u16::from_be_bytes([p[4], p[5]]);
                println!("STREAM_START {w}x{h} @ {fps} fps, codec {}", p[6]);
            }
            msg::CODEC_CONFIG => {
                configs += 1;
                println!("CODEC_CONFIG {} bytes", p.len());
                write_nals(&mut out, &p)?;
            }
            msg::FRAME => {
                frames += 1;
                bytes += p.len() as u64;
                if flags & protocol::FLAG_KEYFRAME != 0 {
                    keyframes += 1;
                }
                if first_frame_at.is_none() {
                    first_frame_at = Some(start.elapsed());
                    println!("first frame after {:?} ({} bytes)", start.elapsed(), p.len());
                }
                write_nals(&mut out, &p)?;
            }
            msg::PING => {
                tx.send(msg::PONG, 0, &p)?;
            }
            msg::STREAM_STOP => {
                println!("STREAM_STOP reason {}", p.first().copied().unwrap_or(255));
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
        }
    }

    let secs = start.elapsed().as_secs_f64();
    println!(
        "{frames} frames ({keyframes} key) in {secs:.1}s = {:.1} fps, {:.1} Mbps avg, {configs} codec configs",
        frames as f64 / secs,
        bytes as f64 * 8.0 / secs / 1e6
    );
    if let Some(mut w) = out {
        w.flush()?;
        println!("wrote {}", args.out.unwrap().display());
    }
    Ok(())
}
