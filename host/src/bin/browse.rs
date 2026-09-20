//! Print what Relay hosts advertise over mDNS, TXT record included: the PC
//! has no `dns-sd`, and Windows' own resolver does not answer mDNS TXT
//! queries. Runs for `--seconds` and prints every announcement it hears, so a
//! re-advertise (new `pg`, new `ip`) shows up as a second line.

use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use clap::Parser;
use mdns_sd::{ServiceDaemon, ServiceEvent};

#[derive(Parser)]
#[command(about = "Browse _relay._tcp and print the TXT records heard")]
struct Args {
    /// How long to listen
    #[arg(long, default_value_t = 5)]
    seconds: u64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let daemon = ServiceDaemon::new().context("starting mDNS browser")?;
    let rx = daemon
        .browse(relay_host::protocol::SERVICE_TYPE)
        .context("browsing")?;
    let until = Instant::now() + Duration::from_secs(args.seconds);
    while let Some(left) = until.checked_duration_since(Instant::now()) {
        let Ok(event) = rx.recv_timeout(left) else {
            break;
        };
        match event {
            ServiceEvent::ServiceResolved(info) => {
                let mut txt: Vec<(String, String)> = info
                    .get_properties()
                    .iter()
                    .map(|p| (p.key().to_string(), p.val_str().to_string()))
                    .collect();
                txt.sort();
                println!(
                    "{} port {} {:?}",
                    info.get_fullname(),
                    info.get_port(),
                    info.get_addresses()
                );
                for (k, v) in txt {
                    println!("  {k}={v}");
                }
            }
            ServiceEvent::ServiceRemoved(_, name) => println!("{name} gone"),
            _ => {}
        }
    }
    let _ = daemon.shutdown();
    Ok(())
}
