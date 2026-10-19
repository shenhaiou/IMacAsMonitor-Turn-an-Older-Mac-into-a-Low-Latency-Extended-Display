# IMacAsMonitor — Turn an Older Mac into an Extended Display

**Use a 2017 MacBook Pro or iMac as a low-latency secondary display for an
Apple silicon Mac over a direct Thunderbolt connection.**

IMacAsMonitor is an open-source macOS virtual-display and screen-streaming app.
It creates a separate HiDPI desktop on the source Mac, captures it with
ScreenCaptureKit, hardware-encodes it with VideoToolbox, transfers it over
Thunderbolt Bridge, and presents it full-screen with Metal on the receiver Mac.

Keywords: macOS extended display, use old Mac as monitor, iMac as monitor,
MacBook Pro as second screen, Thunderbolt display streaming, virtual display,
ScreenCaptureKit, VideoToolbox, Metal, Swift.

See the standalone [installation and setup guide](INSTALLATION_GUIDE.html) for
installation, permissions, Thunderbolt Bridge setup, automatic discovery, and
manual receiver-IP lookup.

## Highlights

- A true extended macOS desktop, not only screen mirroring.
- Automatic receiver discovery with Bonjour; no fixed IP address required.
- Receiver-driven Retina resolution and refresh-rate negotiation.
- Hardware H.264 encoding and decoding through VideoToolbox.
- Full-screen Metal presentation with automatic menu bar and Dock hiding.
- Direct Thunderbolt Bridge transport with manual IP fallback.
- One universal app for Apple silicon and Intel Macs.

The current tested receiver is a 2017 15-inch MacBook Pro running macOS Ventura.
A 2017 27-inch iMac is the next target and uses the same receiver architecture;
its 5K image is downscaled to a safe H.264 hardware-decoding resolution.

## How it works

On connection, the receiver reports its built-in display's current logical size,
backing-pixel size, and refresh rate. The source uses that profile to create the
virtual HiDPI display and configure capture and encoding. If the receiver does
not support this handshake, the source falls back to 1440×900/60 fps.

The receiver advertises `_imacasmonitor._tcp` with Bonjour. When the optional
address field is empty, the source discovers and connects to the receiver
automatically. A numeric address can still be entered for diagnostics.

It has two source modes:

- **Extended desktop** (default): creates a virtual HiDPI display on the source
  Mac and streams that display. macOS treats it as a separate desktop, so windows
  can be moved onto it.
- **Mirror**: clear the virtual-display checkbox to stream the source Mac's main
  display instead.

The virtual display uses private CoreGraphics interfaces. It is intended for
local/ad-hoc use, cannot be distributed through the Mac App Store, and may need
maintenance after a macOS update. The public capture, codec, network, and render
paths remain independently usable in mirror mode.

## Build

Requirements on the build Mac:

- macOS with Xcode and the macOS 13 SDK or later.
- Swift 6 or later.

Build and test:

```bash
swift test
zsh scripts/package_app.sh release
```

This creates `dist/IMacAsMonitor.app` as a universal Apple silicon/Intel app.

## First run

1. Copy `IMacAsMonitor.app` to both Macs.
2. Keep both Macs awake, connected to power, and connected by Thunderbolt.
3. On the 2017 MacBook Pro, open the app and click **Start Receiver**. Allow
   incoming network connections if macOS asks.
4. On the M1 Max, open the app. Leave the optional receiver-address field empty,
   leave **Create a virtual extended display** selected, then click **Start
   Source**. The receiver should be discovered automatically.
5. Grant Screen Recording access on the M1 Max when macOS asks. If capture does
   not begin after permission is granted, quit and reopen the source app.
6. The receiver enters full-screen when the first H.264 configuration arrives.
   The receiver automatically hides its menu bar and Dock. Press Escape to
   restore them and reveal the control window.
7. On the M1 Max, open **System Settings > Displays > Arrange** and place
   **IMacAsMonitor Extended Display** to the side you prefer. Drag a window or the
   pointer across that edge to use the second desktop.

The source Mac's keyboard and pointing device control the extended desktop.
Keyboard and mouse forwarding from the receiver is not implemented yet.

Press **Command-Q** at any time to quit cleanly. You can also press Escape and
use the **Quit** button, or close the main control window.

The 2017 MacBook Pro can request its Retina backing resolution. Modes larger
than the safe H.264 hardware limit (for example, a 5K iMac panel) retain their
logical desktop dimensions but are streamed at a lower negotiated pixel size.

## Troubleshooting

- If automatic discovery fails, verify Thunderbolt Bridge is active on both
  Macs. Enter the receiver's current `169.254.x.x` address manually as a fallback.
- Verify the source app is enabled in System Settings > Privacy & Security >
  Screen Recording.
- If extended mode fails after a macOS update, clear the virtual-display
  checkbox to verify that the public capture/streaming path still works.
- In System Settings > Network > Firewall > Options, allow incoming connections
  for IMacAsMonitor on the receiver.
- Link-local addresses can change after reconnecting the cable; automatic
  discovery avoids storing them.

## Author

Developed by **Haiou Shen** — [shenhaiou@gmail.com](mailto:shenhaiou@gmail.com)

## License

IMacAsMonitor is released under the [MIT License](LICENSE). The isolated private
virtual-display shim is based on the MIT-licensed DeskPad project; see
[third-party notices](THIRD_PARTY_NOTICES.md).
