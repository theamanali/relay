# Host assets

`relay-light.ico` / `relay-dark.ico` — the tray icon, embedded into
`relay-host.exe` by `src/tray.rs` (`include_bytes!`). Windows does not tint
notification-area icons, so there is one drawn black (for a light taskbar) and one
drawn white (for a dark taskbar); the host picks by `SystemUsesLightTheme` and swaps
on a theme change. Each file holds PNG images at 16, 20, 24, 32, 40, 48, 64 and 256 px;
the host loads the one nearest `SM_CXSMICON` for the current DPI.

The artwork is the client's tower-and-MacBook glyph
(`client/Sources/Relay/Glyphs.swift`, `towerAndMacBook`), rendered by the client
itself so both apps share one drawing. To regenerate, **on the Mac**:

```bash
cd client && swift run Relay --render-icons ../host/assets
```

then commit the two files and rebuild the host.

> **Placeholder notice (2026-09-17):** the files checked in right now were drawn by a
> throwaway script on the PC to the same rough geometry so the host would build; they
> are not the Swift render. Run the command above on the Mac and overwrite them.

Not covered: the exe's own file icon (Explorer, taskbar while a dialog is up). That
needs a non-tintable colour version and a resource-compiler step; out of scope for now.
