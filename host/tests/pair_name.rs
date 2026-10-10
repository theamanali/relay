//! Run the real probe CLI against an isolated loopback pairing endpoint.
//! No Relay service, installed state, GPU, display, or driver is touched.
use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use relay_host::crypto::{self, Identity, PairLimiter, PeerList, SecureReader, SecureWriter};
use relay_host::protocol::{self, msg};

#[test]
fn probe_pair_only_persists_names_and_negotiates_legacy_hosts() {
    // Capability on/off and an explicit legacy client; none sends CLIENT_HELLO.
    for (case, capability, legacy_client, wrong_pin, abandon) in [
        ("named", true, false, false, false),
        ("old-host", false, false, false, false),
        ("old-client", true, true, false, false),
        ("wrong-pin", true, false, true, false),
        ("abandoned", true, false, false, true),
    ] {
        let dir =
            std::env::temp_dir().join(format!("relay-probe-name-{}-{case}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("peers.txt");
        let peers = Arc::new(Mutex::new(PeerList::load(&path).unwrap()));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let host_peers = Arc::clone(&peers);
        let host_path = path.clone();
        let host = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "probe did not connect");
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(e) => panic!("accept: {e}"),
                }
            };
            // Windows inherits the listener's nonblocking mode on accept.
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            socket
                .set_write_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let hs =
                crypto::host_handshake(&mut socket, &Identity::generate(), &host_peers).unwrap();
            let mut tx = SecureWriter::new(socket.try_clone().unwrap(), &hs.keys);
            let mut rx = SecureReader::new(socket, &hs.keys, 4096);
            let hello = if capability {
                protocol::server_hello_with_capabilities("Pair-name fixture", false)
            } else {
                protocol::server_hello("Pair-name fixture", false)
            };
            tx.send(msg::SERVER_HELLO, 0, &hello).unwrap();
            let (ty, _, payload) = rx.recv().unwrap();
            assert_eq!(ty, msg::PAIR);
            let named = capability && !legacy_client;
            assert_eq!(
                protocol::PairRequest::parse(&payload)
                    .unwrap()
                    .name
                    .is_some(),
                named
            );
            let paired = crypto::host_pairing(
                &mut tx,
                &mut rx,
                &hs.keys,
                &payload,
                "123456",
                &Mutex::new(PairLimiter::new()),
                |name| {
                    assert!(!wrong_pin && !abandon);
                    assert_eq!(name, named.then_some("Aman’s MacBook Pro"));
                    host_peers.lock().unwrap().add_pairing(hs.peer, name)?;
                    // Persistence precedes PAIR_RESULT, not a later streaming hello.
                    assert_eq!(
                        PeerList::load(&host_path)?.name_of(&hs.peer),
                        Some(if named {
                            "Aman’s MacBook Pro"
                        } else {
                            "Paired MacBook"
                        })
                    );
                    Ok(())
                },
            )
            .unwrap();
            assert_eq!(paired, !wrong_pin && !abandon);
            if paired {
                let error = rx
                    .recv()
                    .expect_err("pair-only must close without CLIENT_HELLO");
                assert!(crypto::peer_closed(&error));
            }
        });

        let mut command = Command::new(env!("CARGO_BIN_EXE_probe"));
        command.args([
            "--addr",
            &address.to_string(),
            "--fresh-identity",
            "--pair-only",
            "--name",
            "Aman’s MacBook Pro",
            "--pin",
            if wrong_pin { "000000" } else { "123456" },
        ]);
        if legacy_client {
            command.arg("--legacy-pair");
        }
        if abandon {
            command.arg("--abandon-pair");
        }
        let mut child = command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("probe timed out in {case}");
            }
            thread::sleep(Duration::from_millis(10));
        }
        let output = child.wait_with_output().unwrap();
        host.join().unwrap();
        assert_eq!(
            output.status.success(),
            !wrong_pin,
            "{case}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        if !wrong_pin && !abandon {
            assert!(String::from_utf8_lossy(&output.stdout).contains("pair-only complete"));
        }
        assert_eq!(
            peers.lock().unwrap().len(),
            usize::from(!wrong_pin && !abandon)
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
