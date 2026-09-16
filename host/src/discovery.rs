//! mDNS advertisement so the Mac finds us on a DHCP-less cable: both ends get
//! IPv6 link-local addresses instantly and Bonjour resolves over those.

use std::collections::HashMap;

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceInfo};

use crate::protocol::{SERVICE_TYPE, VERSION};

pub struct Advertisement {
    daemon: ServiceDaemon,
    fullname: String,
}

pub fn advertise(instance_name: &str, port: u16, public_key: &[u8; 32]) -> Result<Advertisement> {
    let daemon = ServiceDaemon::new().context("starting mDNS responder")?;
    let hostname = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "travelpc".into());
    let host = format!("{}.local.", hostname.to_lowercase());
    let info = service_info(instance_name, &host, port, public_key)?.enable_addr_auto();
    let fullname = info.get_fullname().to_string();
    daemon.register(info).context("registering mDNS service")?;
    log::info!("advertising {fullname} on port {port}");
    Ok(Advertisement { daemon, fullname })
}

/// Build the advertised service record: the protocol version and the host's
/// identity public key as 64 lowercase hex chars, so a client can show whether
/// it is already paired before connecting. `pk` is public and never trusted in
/// place of the handshake (see docs/PROTOCOL.md).
fn service_info(
    instance_name: &str,
    host: &str,
    port: u16,
    public_key: &[u8; 32],
) -> Result<ServiceInfo> {
    let mut props = HashMap::new();
    props.insert("v".to_string(), VERSION.to_string());
    props.insert("pk".to_string(), hex::encode(public_key));
    ServiceInfo::new(SERVICE_TYPE, instance_name, host, "", port, Some(props))
        .context("building mDNS service info")
}

impl Drop for Advertisement {
    fn drop(&mut self) {
        if let Ok(rx) = self.daemon.unregister(&self.fullname) {
            let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
        }
        let _ = self.daemon.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advertises_version_and_public_key_hex() {
        let key = [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x0f, 0x1e, 0x2d, 0x3c,
            0x4b, 0x5a, 0x69, 0x78,
        ];
        let info = service_info("Test PC", "test-pc.local.", 8468, &key).unwrap();
        assert_eq!(info.get_property_val_str("v").unwrap(), VERSION.to_string());
        let pk = info.get_property_val_str("pk").unwrap();
        assert_eq!(pk.len(), 64);
        assert_eq!(pk, hex::encode(key));
        assert_eq!(pk, pk.to_lowercase());
    }
}
