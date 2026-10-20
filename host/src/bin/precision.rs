//! Non-exclusive native SDR precision diagnostic. Physical monitors stay on.
use anyhow::{Context, Result};
use clap::Parser;
use relay_host::{display, driver, gpu, precision, topology};
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// Add the virtual display alongside physical monitors (elevated, service stopped).
    #[arg(long)]
    virtual_display: bool,
    /// Legacy BGRA8 capture baseline. Default is true RGB10 SDR.
    #[arg(long)]
    eight_bit: bool,
    /// H.264/8-bit compatibility dump, regardless of the 10-bit default.
    #[arg(long)]
    h264: bool,
    #[arg(long)]
    full_color: bool,
    /// Existing active display name; defaults to primary. Never changes its colour settings.
    #[arg(long)]
    display: Option<String>,
    /// Write actual captured/composed patch CSV and a production HEVC dump.
    #[arg(long)]
    dump: Option<PathBuf>,
    /// Keep the native ramp visible while another host/probe captures it.
    #[arg(long, default_value_t = 0)]
    hold_seconds: u64,
    /// Verify actual WGC cursor pixels at two positions; restores the pointer.
    #[arg(long)]
    cursor_check: bool,
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let args = Args::parse();
    let ten_bit = !args.eight_bit && !args.h264;
    let codec = if args.h264 {
        relay_host::protocol::Codec::H264
    } else {
        relay_host::protocol::Codec::Hevc
    };
    let gpu = gpu::choose(&gpu::enumerate()?, None)?;
    if !args.virtual_display {
        let name = args
            .display
            .or_else(|| display::primary().map(|m| m.device_name))
            .context("no active display")?;
        return precision::run(
            &gpu,
            &name,
            ten_bit,
            args.full_color,
            codec,
            args.dump.as_deref(),
            precision::Options {
                hold: std::time::Duration::from_secs(args.hold_seconds),
                check_cursor: args.cursor_check,
            },
        );
    }
    // This test never acquires an exclusive topology or disables a physical
    // output. A saved snapshot and the existing crash restore cover interruption.
    anyhow::ensure!(
        relay_host::service::is_active() == Some(false),
        "stop Relay service before changing the VDD for a diagnostic"
    );
    let drv = driver::open()?;
    drv.cleanup()?;
    topology::recover_saved()?;
    let snapshot = topology::Snapshot::take()?;
    snapshot.save()?;
    let result = (|| -> Result<()> {
        let (attachment, monitor) = drv.attach(
            display::Mode {
                width: 1920,
                height: 1080,
                hz: 60,
            },
            &gpu,
            ten_bit,
        )?;
        let (x, y) = display::next_free_position();
        let run = (|| -> Result<()> {
            display::attach_display(
                &monitor.device_name,
                display::Mode {
                    width: 1920,
                    height: 1080,
                    hz: 60,
                },
                x,
                y,
            )?;
            std::thread::sleep(std::time::Duration::from_secs(2));
            precision::run(
                &gpu,
                &monitor.device_name,
                ten_bit,
                args.full_color,
                codec,
                args.dump.as_deref(),
                precision::Options {
                    hold: std::time::Duration::from_secs(args.hold_seconds),
                    check_cursor: args.cursor_check,
                },
            )
        })();
        let restored = snapshot.restore();
        let detached = drv.detach(attachment);
        restored?;
        detached?;
        topology::Snapshot::clear_saved();
        run
    })();
    if result.is_err() {
        snapshot.restore()?;
        drv.cleanup()?;
        topology::Snapshot::clear_saved();
    }
    result
}
