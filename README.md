# VentMac

Native macOS (Apple Silicon) client for legacy **Ventrilo 3** servers, with a real global push-to-talk key. Built on [Mangler](https://github.com/econnell/mangler)'s `libventrilo3` protocol library (vendored under `Vendor/` and `Sources/CVentrilo3/`).

## Why

Mangler no longer builds/runs on modern macOS, and Ventrilo under Crossover/Wine can't do a reliable system-wide PTT key. This is a from-parts native port: proven C protocol core, Swift/SwiftUI shell.

## Requirements

- macOS 13+, Apple Silicon
- Xcode Command Line Tools (Swift 5.9+)
- `brew install speex speexdsp`

## Build

```sh
swift build                 # everything
swift run ventctl --help    # headless smoke-test client
Scripts/make-app.sh         # assemble + sign VentMac.app
```

## Targets

| Target | What |
|---|---|
| `CVentrilo3` | Vendored libventrilo3 (protocol, crypto, Speex codec paths) |
| `VentCore` | Swift wrapper: event pump → AsyncStream, audio PCM in/out |
| `ventctl` | CLI: connect, dump channel tree/codec, join, listen, spacebar PTT |
| `VentMac` | SwiftUI app: connect UI, channel tree, talk indicators, global PTT |

## Global PTT

Two tiers:
1. **Hotkey (default)** — Carbon `RegisterEventHotKey`: works over fullscreen games, no permissions needed.
2. **Event tap (advanced)** — CGEventTap (listen-only) for mouse side buttons / bare modifiers; requires Input Monitoring.

## License

GPL-3.0 (inherited from libventrilo3 / Mangler). See `Vendor/mangler` for upstream copyright.
