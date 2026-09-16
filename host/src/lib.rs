//! TravelDisplay host library: virtual display control, capture/encode, wire protocol.

pub mod discovery;
pub mod display;
pub mod driver;
pub mod encoder;
pub mod gpu;
pub mod input;
mod native_nvenc;
mod nvenc_bindings;
pub mod protocol;
pub mod crypto;
pub mod server;
pub mod topology;
mod cursor_overlay;
