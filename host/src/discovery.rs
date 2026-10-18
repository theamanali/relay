//! mDNS advertisement so the Mac finds us on a DHCP-less cable: both ends get
//! IPv6 link-local addresses instantly and Bonjour resolves over those.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceInfo};

use crate::protocol::{SERVICE_TYPE, VERSION};
use crate::sysinfo::HostFacts;

pub struct Advertisement {
    daemon: ServiceDaemon,
    fullname: String,
    /// The record as built, before the daemon filled in addresses, so a
    /// re-announcement picks up the interfaces present at that moment.
    info: ServiceInfo,
    registered: Instant,
    /// How many entries of `REANNOUNCE_AFTER` have gone out.
    reannounced: usize,
}

/// When to announce the record again after registering it, counted from the
/// registration. mdns-sd announces twice at registration (at once and 1 s
/// later) and then only answers queries. A worker that dies sends no goodbye,
/// so a Mac that dialled during the respawn gap reconfirms (flushes) the old
/// record and its long-running browse may not query again for a while; the
/// new worker's first two announcements can fall before that flush
/// (`host/NVIDIA-RECOVERY-RETEST.md` finding 6). A few more over the first
/// minute put the record back on the Mac without waiting for its backoff.
/// Each is one `register` call (two packets, 1 s apart); nothing goes out
/// after the last one.
const REANNOUNCE_AFTER: [Duration; 5] = [
    Duration::from_secs(3),
    Duration::from_secs(8),
    Duration::from_secs(16),
    Duration::from_secs(32),
    Duration::from_secs(60),
];

/// The new count of sent re-announcements if one is due `elapsed` after
/// registering with `done` already sent, or `None`. Entries that a late tick
/// skipped past count as sent: one announcement covers them all.
fn reannounce_step(elapsed: Duration, done: usize) -> Option<usize> {
    let due = REANNOUNCE_AFTER.iter().filter(|&&at| elapsed >= at).count();
    (due > done).then_some(due)
}

impl Advertisement {
    /// Announce the record again if the start-up schedule says so. Called
    /// about once a second by the server's readvertise thread.
    pub fn reannounce_if_due(&mut self, now: Instant) {
        let elapsed = now.saturating_duration_since(self.registered);
        let Some(done) = reannounce_step(elapsed, self.reannounced) else {
            return;
        };
        self.reannounced = done;
        match self.daemon.register(self.info.clone()) {
            Ok(()) => log::info!(
                "re-announced {} ({done}/{}, {} s after registering)",
                self.fullname,
                REANNOUNCE_AFTER.len(),
                elapsed.as_secs()
            ),
            Err(e) => log::warn!("re-announcing {} failed: {e}", self.fullname),
        }
    }
}

/// The live advertisement, shared between the thread that re-registers it on
/// an address change and the quit paths (tray Quit, Ctrl-C, logoff), which
/// all end in `process::exit` and so never run `Drop` on their own. Taking it
/// out of the slot and dropping it sends the goodbye that makes the Mac's
/// list forget the host at once instead of after the record's TTL.
pub type AdSlot = Arc<Mutex<Option<Advertisement>>>;

/// Withdraw the advertisement now (goodbye packet, responder stopped).
pub fn withdraw(slot: &AdSlot) {
    let ad = slot.lock().unwrap_or_else(|e| e.into_inner()).take();
    drop(ad);
}

pub fn advertise(
    instance_name: &str,
    port: u16,
    public_key: &[u8; 32],
    facts: &HostFacts,
    pairing_digest: &str,
) -> Result<Advertisement> {
    let daemon = ServiceDaemon::new().context("starting mDNS responder")?;
    let hostname = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "travelpc".into());
    let host = format!("{}.local.", hostname.to_lowercase());
    let info = service_info(
        instance_name,
        &host,
        port,
        public_key,
        facts,
        pairing_digest,
    )?
    .enable_addr_auto();
    let fullname = info.get_fullname().to_string();
    daemon
        .register(info.clone())
        .context("registering mDNS service")?;
    log::info!("advertising {fullname} on port {port}");
    Ok(Advertisement {
        daemon,
        fullname,
        info,
        registered: Instant::now(),
        reannounced: 0,
    })
}

/// Build the advertised service record: the protocol version, the host's
/// identity public key as 64 lowercase hex chars (so a client can show whether
/// it is already paired before connecting), the pairing digest `pg` (moves when a
/// client is paired or forgotten; a client that knows us re-checks its pairing
/// when it does), and the PC facts the client shows
/// on hover. All of it is public and none of it is trusted in place of the
/// handshake (see docs/PROTOCOL.md).
fn service_info(
    instance_name: &str,
    host: &str,
    port: u16,
    public_key: &[u8; 32],
    facts: &HostFacts,
    pairing_digest: &str,
) -> Result<ServiceInfo> {
    let mut props = HashMap::new();
    props.insert("v".to_string(), VERSION.to_string());
    props.insert("pk".to_string(), hex::encode(public_key));
    props.insert("pg".to_string(), pairing_digest.to_string());
    for (k, v) in facts.txt_entries() {
        // A TXT string is at most 255 bytes including "key=".
        let room = 255 - k.len() - 1;
        let v = if v.len() > room {
            let mut end = room;
            while !v.is_char_boundary(end) {
                end -= 1;
            }
            v[..end].to_string()
        } else {
            v
        };
        props.insert(k, v);
    }
    ServiceInfo::new(SERVICE_TYPE, instance_name, host, "", port, Some(props))
        .context("building mDNS service info")
}

/// How long the responder stays up after the goodbye so its built-in
/// retransmission (120 ms later) also goes out. Multicast over Wi-Fi is
/// unacknowledged: with a single goodbye the Mac kept a half-expired entry
/// (TXT flushed, PTR still there) whenever that one packet was lost on the
/// Wi-Fi path, and the picker showed a nameless "Available" row.
const GOODBYE_LINGER: Duration = Duration::from_millis(400);

impl Drop for Advertisement {
    fn drop(&mut self) {
        if let Ok(rx) = self.daemon.unregister(&self.fullname) {
            let _ = rx.recv_timeout(Duration::from_secs(1));
            std::thread::sleep(GOODBYE_LINGER);
        }
        let _ = self.daemon.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reannounces_on_the_startup_schedule_then_stops() {
        let s = Duration::from_secs;
        assert_eq!(reannounce_step(s(0), 0), None);
        assert_eq!(reannounce_step(Duration::from_millis(2999), 0), None);
        assert_eq!(reannounce_step(s(3), 0), Some(1));
        assert_eq!(reannounce_step(s(5), 1), None);
        assert_eq!(reannounce_step(s(8), 1), Some(2));
        assert_eq!(reannounce_step(s(16), 2), Some(3));
        assert_eq!(reannounce_step(s(32), 3), Some(4));
        assert_eq!(reannounce_step(s(60), 4), Some(5));
        // Steady state: nothing after the last entry.
        assert_eq!(reannounce_step(s(61), 5), None);
        assert_eq!(reannounce_step(s(86_400), 5), None);
    }

    #[test]
    fn a_late_tick_sends_one_reannouncement_for_the_entries_it_skipped() {
        let s = Duration::from_secs;
        assert_eq!(reannounce_step(s(20), 1), Some(3));
        assert_eq!(reannounce_step(s(20), 3), None);
        assert_eq!(reannounce_step(s(100), 0), Some(REANNOUNCE_AFTER.len()));
    }

    #[test]
    fn the_schedule_grows_and_ends_within_a_minute() {
        assert!(REANNOUNCE_AFTER.windows(2).all(|w| w[0] < w[1]));
        assert!(REANNOUNCE_AFTER[0] > Duration::from_secs(1));
        assert!(*REANNOUNCE_AFTER.last().unwrap() <= Duration::from_secs(60));
    }

    #[test]
    fn advertises_version_and_public_key_hex() {
        let key = [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x0f, 0x1e, 0x2d, 0x3c,
            0x4b, 0x5a, 0x69, 0x78,
        ];
        let info = service_info(
            "Test PC",
            "test-pc.local.",
            8468,
            &key,
            &HostFacts::default(),
            "0badf00d",
        )
        .unwrap();
        assert_eq!(info.get_property_val_str("v").unwrap(), VERSION.to_string());
        let pk = info.get_property_val_str("pk").unwrap();
        assert_eq!(pk.len(), 64);
        assert_eq!(pk, hex::encode(key));
        assert_eq!(pk, pk.to_lowercase());
        assert!(info.get_property_val_str("cpu").is_none());
        assert_eq!(info.get_property_val_str("pg").unwrap(), "0badf00d");
    }

    #[test]
    fn advertises_facts_within_txt_limits() {
        let facts = HostFacts {
            cpu: "AMD Ryzen 9 7950X 16-Core Processor".into(),
            ram_gb: 64,
            gpu: "x".repeat(300),
            os: "Windows 11 Pro 24H2 (build 26100)".into(),
            ips: vec!["192.168.1.5".into(), "169.254.10.20".into()],
            encoder_features: "q,444,10".into(),
            ..Default::default()
        };
        let info = service_info(
            "Test PC",
            "test-pc.local.",
            8468,
            &[0u8; 32],
            &facts,
            "0badf00d",
        )
        .unwrap();
        assert_eq!(info.get_property_val_str("ram").unwrap(), "64");
        assert!(info.get_property_val_str("ramtype").is_none());
        assert_eq!(
            info.get_property_val_str("ip").unwrap(),
            "192.168.1.5,169.254.10.20"
        );
        assert_eq!(
            info.get_property_val_str("gpu").unwrap().len(),
            255 - "gpu=".len()
        );
        assert_eq!(info.get_property_val_str("enc").unwrap(), "q,444,10");
    }
}
