# Contributing to IMacAsMonitor

Thanks for your interest in improving IMacAsMonitor.

## Development setup

- macOS 13 or later
- Xcode with Swift 6 or later
- Two Macs for end-to-end Thunderbolt Bridge testing

Build and run the automated tests:

```bash
swift test
zsh scripts/package_app.sh debug
```

## Pull requests

1. Keep changes focused and explain the user-visible behavior.
2. Add or update tests for protocol and configuration changes.
3. Run `swift test` before submitting.
4. Document testing on the source and receiver Mac models and macOS versions.
5. Do not replace the private virtual-display shim with copied code lacking a
   compatible license and attribution.

Bug reports should include both Mac models, both macOS versions, the connection
interface, the negotiated resolution, and the exact status or error message.
