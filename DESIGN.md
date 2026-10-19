# IMacAsMonitor — Software Design

## 1. Executive summary

The Thunderbolt cable is currently acting as a fast point-to-point IP network. The
`169.254.x.x` addresses are normal self-assigned link-local addresses; they prove
that the two Macs can communicate, but the cable does **not** expose the 2017
MacBook Pro panel as a DisplayPort/Thunderbolt monitor input.

IMacAsMonitor should therefore be a two-ended low-latency remote-display system:

1. The M1 Max Mac creates or uses an additional display surface.
2. It captures that surface with ScreenCaptureKit.
3. It hardware-encodes the frames with VideoToolbox.
4. It sends them over the Thunderbolt Bridge.
5. The 2017 Mac hardware-decodes and presents them full-screen with Metal.

The difficult part is step 1. Apple provides public APIs to capture, encode,
transport, decode, and render a display, but no supported public API for a normal
app to create a new virtual monitor. This leads to two implementation modes:

- **Supported mode (recommended first):** connect a small HDMI/USB-C headless
  display adapter to the M1 Max. macOS creates a real extra desktop, and all
  software uses public APIs.
- **Software-only mode (experimental):** create a virtual display through the
  undocumented `CGVirtualDisplay` family used by some display utilities. This is
  suitable for a personal/local tool, but can break on a macOS update and is not
  appropriate for Mac App Store distribution.

Build the streaming path first against a real or headless display. Keep display
creation behind an interface so the experimental provider can be added without
changing the rest of the system.

## 2. Product scope

### Goals

- The M1 Max treats the remote screen as an extended desktop, not a mirror.
- The 2017 Mac shows that desktop full-screen at its panel's native pixel size.
- Target 60 fps with interactive latency and sharp desktop text.
- Automatically discover and reconnect over the Thunderbolt Bridge.
- Avoid hard-coded `169.254` addresses, because link-local addresses can change.
- Use the M1 Max keyboard/trackpad normally; optionally allow the receiver's
  keyboard and trackpad to control the M1 Max.

### Non-goals for version 1

- DRM/HDCP-protected video playback.
- Login-window, FileVault, or lock-screen display.
- HDR, audio forwarding, touch input, or multiple receivers.
- Operation when no user is logged in on the 2017 Mac.
- Mac App Store distribution of the software-only virtual-display mode.

## 3. Feasibility and platform constraints

- A MacBook Pro panel is not an external video input. Target Display Mode was an
  older iMac-only feature, so the Thunderbolt cable cannot directly drive this
  panel.
- A 2017 MacBook Pro is not in Apple's officially supported receiver list for
  AirPlay to Mac (the normal requirement is a 2018-or-later MacBook Pro). Before
  building anything, still check **System Settings > General > AirDrop & Handoff**
  for an AirPlay Receiver switch. If it exists and the M1 can select the 2017 Mac
  in Screen Mirroring as an extended display, the built-in feature already solves
  the problem. It will usually be unavailable on this model.
- ScreenCaptureKit captures an existing display and produces `CMSampleBuffer`
  frames backed by `IOSurface`; it does not create a display.
- The current public macOS SDK has no public `CGVirtualDisplay` declaration and
  DriverKit has no general-purpose virtual display family. A software-only true
  extended desktop consequently depends on undocumented API, a legacy/security-
  sensitive driver approach, or a physical headless adapter.
- Screen Recording permission is required on the M1 Max. Accessibility permission
  is required there only if input events from the 2017 Mac are injected.

## 4. System architecture

Install one universal macOS app on both computers. At launch it runs in one of two
roles: **Source** on the M1 Max and **Receiver** on the 2017 Mac.

```text
M1 Max (Source)                                  2017 MacBook Pro (Receiver)

DisplayProvider                                  ReceiverProfile
  | real/headless or private virtual display       | panel size, refresh, codecs
  v                                                v
ScreenCaptureKit -> VideoToolbox encoder -> Network.framework
                                                Thunderbolt Bridge
Network.framework -> VideoToolbox decoder -> Metal full-screen renderer
       ^                                                   |
       +------------- optional input events ---------------+
```

### Source components

#### `DisplayProvider`

Protocol implemented by:

- `ExistingDisplayProvider`: user selects an already connected display. This is
  the development path and the supported headless-adapter path.
- `PrivateVirtualDisplayProvider`: dynamically loads the undocumented virtual
  display classes, publishes modes matching the receiver, and tears down the
  display on disconnect. It must fail cleanly if the OS changes.

The requested mode should match the receiver panel. Common 2017 MacBook Pro
panels are 2560×1600 (13-inch) or 2880×1800 (15-inch). The receiver must report
the actual pixel size rather than relying on the model name. Offer both a Retina
logical mode and a lower-bandwidth mode.

#### `CapturePipeline`

- Enumerate `SCShareableContent` and match the selected display by
  `CGDirectDisplayID`.
- Create an `SCContentFilter` for only that display.
- Configure `SCStream` for the negotiated pixel dimensions and 60 fps.
- Start with SDR BGRA capture; convert to NV12 only if the encoder cannot consume
  the supplied pixel buffer efficiently.
- Set `showsCursor = true`. The receiver hides its local pointer in presentation
  mode so only the source cursor is visible.
- Use a bounded one- or two-frame queue. If the encoder is behind, discard the
  oldest unencoded frame instead of accumulating latency.

#### `VideoEncoder`

Use a hardware-backed `VTCompressionSession`:

- Version 1 codec: H.264, 8-bit 4:2:0, for the safest hardware support on the
  2017 Intel Mac.
- Later codec: HEVC when both endpoints report hardware support.
- `RealTime = true`.
- `AllowFrameReordering = false` to avoid B-frame latency.
- 60 fps target, approximately 20–60 Mbit/s for a Retina desktop; tune from
  measured text quality and latency.
- Keyframe every one or two seconds, plus on receiver request/reconnect.
- Preserve parameter sets and color metadata in the stream configuration.

#### `SourceSession`

Own the state machine and lifetime of the display, capture, encoder, and network
connection. A useful state model is:

```text
idle -> discovered -> pairing -> negotiating -> displayReady -> streaming
                    \-> failed              streaming -> reconnecting -> streaming
```

Destroying an experimental virtual display must happen only after capture is
stopped and in-flight callbacks have drained.

#### `InputInjector` (optional after video is stable)

Convert normalized receiver coordinates into global coordinates in the virtual
display's Core Graphics bounds and post mouse, scroll, and keyboard `CGEvent`s.
This requires Accessibility permission on the source. Keep it disabled by default
because the user can control the extended desktop with the M1's own input devices.

### Receiver components

#### `ReceiverProfile`

Report:

- Native backing-pixel width and height.
- Current refresh rate.
- H.264/HEVC hardware-decode availability.
- Color-space capabilities.
- Whether receiver-side input forwarding is enabled.

#### `VideoDecoder`

- Reconstruct `CMSampleBuffer`s from each encoded access unit.
- Create/re-create a `VTDecompressionSession` on format changes.
- Decode asynchronously and drop any decoded frame older than the newest frame
  already queued for presentation.
- Request a new keyframe after a discontinuity or unrecoverable decode error.

#### `MetalRenderer`

- Use `CVMetalTextureCache` to wrap decoded `CVPixelBuffer`s without a CPU copy.
- Render into a borderless full-screen `NSWindow` on the built-in display.
- Pace presentation to the local display (`MTKView`/display link).
- Use aspect-fit during negotiation, then require an exact negotiated aspect ratio.
- Hide the menu bar, Dock, and local cursor while connected.
- Hold an activity assertion so the receiver does not display-sleep mid-session.
- Press Escape (or a configurable chord) to leave presentation mode safely.

## 5. Networking and protocol

### Discovery and path selection

- The receiver advertises `_imacasmonitor._tcp` with `NWListener`; the source
  discovers it with Bonjour/`NWBrowser`.
- Show the interface and peer name in the connection UI. Prefer a path whose
  interface name is the Thunderbolt Bridge and warn if traffic is using Wi-Fi.
- Retain a manual host field for diagnostics; the current receiver address would
  be `169.254.143.183`, but it must not be stored as identity.
- Use the connection path and Bonjour endpoint so IPv6 scope identifiers and
  future link-local address changes are handled correctly.

### Version 1 transport

Start with one TLS-over-TCP `NWConnection`, because a direct Thunderbolt link is
fast and normally loss-free. It is much simpler to validate. Multiplex framed
control and video messages, but prioritize control messages and cap queued bytes.

If measurements show TCP head-of-line stalls, version 2 should keep reliable TLS
for control and move video to QUIC datagrams or UDP with frame fragmentation. Do
not design a custom unreliable transport before profiling the direct link.

### Framing

Every message has a fixed network-byte-order header:

```text
magic(4) | protocolVersion(2) | type(2) | flags(4) | payloadLength(4)
sessionID(8) | sequence(8) | presentationTimeNs(8) | payload(...)
```

Message types:

- `hello` / `helloAck`: protocol versions, stable device ID, nonce.
- `receiverProfile`: pixel size, refresh, codecs, color spaces.
- `streamConfiguration`: codec, dimensions, rate, parameter sets, color metadata.
- `videoAccessUnit`: one complete encoded frame in version 1.
- `requestKeyframe`, `pause`, `resume`, `stop`, `ping`, `pong`.
- `stats`: RTT, frames decoded/presented/dropped, queue depth.
- `inputEvent`: optional normalized pointer, key, or scroll event.

Set a strict maximum payload size before allocating memory. Reject unexpected
state transitions, malformed lengths, or unsupported protocol versions.

### Pairing and security

Even on a direct cable, authenticate the peer:

1. First connection displays a six-digit code on one Mac and asks for confirmation
   on the other.
2. Generate and store device identities in Keychain.
3. Pin the peer identity on later TLS connections.
4. Provide an explicit “Forget paired Mac” command.

## 6. Latency, quality, and backpressure

Target glass-to-glass latency is 25–50 ms at 60 fps:

| Stage | Initial budget |
|---|---:|
| Capture scheduling | 4–17 ms |
| Encode | 3–8 ms |
| Thunderbolt transport | <2 ms typical |
| Decode | 3–8 ms |
| Wait/render | 0–17 ms |

Latency matters more than showing every frame. Each stage therefore has a bounded
queue, and the pipeline drops stale frames. Monitor capture-to-present latency,
not only FPS. Reduce bitrate or resolution when the sender's queued-byte count or
receiver decode queue remains above threshold.

Start in SDR/sRGB. Correct range and transfer-function metadata is more important
than adding HDR early; a range mismatch makes text and grays visibly wrong.

## 7. Permissions and lifecycle

Source permissions:

- Screen Recording: required for ScreenCaptureKit.
- Local Network/Bonjour: required for discovery and connection where enforced.
- Accessibility: optional, only for receiver input forwarding.

Receiver permissions:

- Local Network/Bonjour.
- Input Monitoring only if a global escape chord or event tap actually requires it;
  prefer ordinary AppKit events while the full-screen window is focused.

Handle cable removal, display reconfiguration, screen lock, sleep/wake, app
termination, and encoder failure. On any failure, show the receiver's local UI,
release the sleep assertion, and restore the cursor immediately.

## 8. Repository/module layout

```text
IMacAsMonitor.xcodeproj
Packages/MAMCore/
  Sources/MAMProtocol/        Codable messages, framing, validation
  Sources/MAMTransport/       Bonjour, TLS connection, metrics
  Sources/MAMVideo/           codec negotiation and shared media types
Apps/IMacAsMonitor/
  App/                        SwiftUI/AppKit app and role selection
  Source/                     display, capture, encode, input injection
  Receiver/                   listen, decode, Metal renderer, input capture
Tests/
  ProtocolTests/
  TransportTests/
  VideoTests/
  EndToEndTests/
```

Use Swift for orchestration and Objective-C++ only where a private display shim or
low-level framework boundary makes it necessary. Keep the private shim in its own
target so a public-API build can exclude it entirely.

## 9. Delivery plan

### Phase 0 — feasibility spikes (1–2 days)

1. Record the exact macOS versions and 2017 model/panel dimensions.
2. Check whether built-in AirPlay Receiver happens to be available.
3. Ping and transfer a large test payload over the Thunderbolt Bridge; record RTT
   and throughput and verify the chosen `NWConnection` path is not Wi-Fi.
4. Capture a selected display with ScreenCaptureKit and encode/decode ten minutes
   of 60-fps motion with hardware acceleration on both Macs.
5. In a disposable experimental target, verify that a private virtual display is
   created, appears in `SCShareableContent`, accepts a Retina mode, and survives
   sleep/reconnect on the M1's current macOS version.

**Gate:** if step 5 fails or is unstable, ship the supported headless-adapter mode
and keep software-only mode out of the critical path.

### Phase 1 — mirror prototype (3–5 days)

- Manual receiver IP and one TCP connection.
- Capture an existing M1 display at 30 fps, H.264 encode, decode, and Metal render.
- On-screen latency/FPS/drop counters.
- No discovery, pairing, remote input, or virtual display yet.

This proves every high-throughput component without conflating it with display
creation.

### Phase 2 — true extended display (about 1 week)

- Add `DisplayProvider` and the headless-adapter path.
- Negotiate the receiver's native resolution and 60 fps.
- Confirm macOS arrangement, cursor transitions, Retina scaling, and reconnect.
- Add the private virtual-display provider behind an experimental preference if
  the Phase 0 spike passed.

### Phase 3 — product behavior (about 1 week)

- Bonjour discovery and Thunderbolt-path preference.
- TLS pairing and Keychain identities.
- Permission guidance, reconnect state machine, sleep/wake handling.
- Full-screen receiver UX and optional input forwarding.

### Phase 4 — optimization and hardening (1–2 weeks)

- Tune H.264 bitrate and queues at native panel resolution.
- Add HEVC negotiation only if it improves measured quality/latency.
- Test cable loss, decoder reset, resolution changes, 8-hour sessions, memory
  growth, thermal load, and mixed macOS versions.
- Package a signed/notarized direct-download build. The experimental private API
  remains clearly labeled and isolated.

## 10. Acceptance criteria

- The remote display appears in macOS Displays settings and can be arranged to the
  left or right of the M1's built-in display.
- A window dragged across the display boundary remains usable and visually sharp.
- 2560×1600 or 2880×1800 at 60 fps is sustained for 30 minutes with bounded memory.
- Median capture-to-present latency is below 50 ms on the direct Thunderbolt link.
- Disconnecting the cable recovers without a hung black full-screen window;
  reconnecting resumes without restarting either app.
- No stale input is injected after disconnect.
- The app never silently falls back to Wi-Fi without showing the active path.

## 11. Principal risks

| Risk | Mitigation |
|---|---|
| Private virtual-display API changes | Isolated provider, runtime checks, supported headless-adapter fallback |
| Protected content captures black | Document as unsupported; do not attempt to bypass HDCP/DRM |
| Text blur/chroma artifacts | Native-size capture, adequate bitrate, test 4:4:4 only after hardware capability profiling |
| Latency grows under load | One-frame queues, stale-frame dropping, no B-frames, adaptive rate |
| Traffic uses Wi-Fi | Inspect and display `NWPath`; prefer/bind to Thunderbolt Bridge |
| 2017 decode or thermal limits | H.264 first, hardware capability probe, 30-fps/fractional-resolution fallback |
| Link-local address changes | Bonjour identity and discovery; never persist the IP as identity |

## 12. Reference APIs

- Apple ScreenCaptureKit overview:
  https://developer.apple.com/documentation/screencapturekit
- Apple screen-capture sample:
  https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Apple VideoToolbox overview:
  https://developer.apple.com/documentation/videotoolbox
- Apple Network framework:
  https://developer.apple.com/documentation/network
- Apple AirPlay-to-Mac requirements:
  https://support.apple.com/en-us/108046
- Apple Target Display Mode requirements:
  https://support.apple.com/en-us/105126
