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

pub fn advertise(instance_name: &str, port: u16) -> Result<Advertisement> {
    let daemon = ServiceDaemon::new().context("starting mDNS responder")?;
    let hostname = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "travelpc".into());
    let host = format!("{}.local.", hostname.to_lowercase());
    let mut props = HashMap::new();
    props.insert("v".to_string(), VERSION.to_string());
    let info = ServiceInfo::new(SERVICE_TYPE, instance_name, &host, "", port, Some(props))
        .context("building mDNS service info")?
        .enable_addr_auto();
    let fullname = info.get_fullname().to_string();
    daemon.register(info).context("registering mDNS service")?;
    log::info!("advertising {fullname} on port {port}");
    Ok(Advertisement { daemon, fullname })
}

impl Drop for Advertisement {
    fn drop(&mut self) {
        if let Ok(rx) = self.daemon.unregister(&self.fullname) {
            let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
        }
        let _ = self.daemon.shutdown();
    }
}
