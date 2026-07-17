# VentMac

A native macOS (Apple Silicon) client for legacy **Ventrilo 3** voice servers, with a real
system-wide push-to-talk key — the thing that never worked under Wine/Crossover.

VentMac is an independent, open-source client built on [Mangler](https://github.com/econnell/mangler)'s
`libventrilo3` protocol library. It exists because Mangler no longer builds or runs on modern
macOS, and running the Windows Ventrilo client under Wine can't bind a reliable global PTT key
while a game is focused.

> **Not affiliated with Ventrilo.** VentMac is an independent interoperability project. It is not
> affiliated with, sponsored by, or endorsed by LightSpeed Gaming LLC (the current owner of the
> Ventrilo trademark) or the former Flagship Industries, Inc. "Ventrilo" is a trademark of its
> respective owner and is used here only descriptively, to state compatibility. Use VentMac only
> to connect to servers you are authorized to use.

## Features

- Native SwiftUI app — no Wine, no Windows binaries
- Connects to Ventrilo 3.x servers (Speex codec)
- Channel tree with users and live talk indicators
- **Global push-to-talk** that works over fullscreen games:
  - Default: a keyboard hotkey (Carbon `RegisterEventHotKey`) — works everywhere, **no permissions required**
  - Optional: mouse side-buttons (CGEventTap) — needs Input Monitoring
- Selectable microphone and output device
- Server password stored in the macOS Keychain

## Requirements

- macOS 13+ (Apple Silicon)
- Xcode Command Line Tools (Swift 5.9+)
- `brew install speex speexdsp`

## Build

```sh
git clone https://github.com/johnnymiranda/ventmac.git
cd ventmac
brew install speex speexdsp
swift build                 # builds everything
swift run ventctl --help    # headless CLI client (smoke-testing / diagnostics)
Scripts/make-app.sh         # assembles + signs VentMac.app
open VentMac.app
```

Once packaged (see `docs/DISTRIBUTION.md`), the intended install path is a Homebrew cask:

```sh
brew install --cask johnnymiranda/tap/ventmac   # (planned)
```

## Targets

| Target | What |
|---|---|
| `CVentrilo3` | Vendored `libventrilo3` (protocol, crypto, Speex codec) |
| `VentCore` | Swift wrapper: event pump → `AsyncStream`, roster, audio, transmit, device enumeration |
| `ventctl` | CLI: `connect`, dump channel tree/codec, join, listen, spacebar PTT, `devices` |
| `VentMac` | SwiftUI app: connect UI, channel tree, talk indicators, global PTT, device pickers |

## Global PTT

Two tiers, chosen automatically by the kind of binding you set in Settings:

1. **Keyboard hotkey (default)** — real press/release events over fullscreen games, zero TCC permission.
2. **Mouse side-button** — via a listen-only `CGEventTap`; requires Input Monitoring
   (System Settings → Privacy & Security → Input Monitoring), which the app guides you to grant.

## Protocol notes

VentMac speaks the Ventrilo 3.x wire protocol via the vendored `libventrilo3`. The protocol was
originally reverse-engineered for interoperability by the Mangler project and by
[Luigi Auriemma](https://aluigi.altervista.org/) (packet encryption). This project reuses that
already-public work; the only additional reverse engineering was reading two interoperability
constants (a client version string and the current auth-server hostnames) needed to talk to
present-day 3.1.0 servers. See `docs/HANDSHAKE-FINDINGS.md` for the details.

## Attribution

- **Mangler / libventrilo3** — © 2009–2011 Eric Connell, GPL-3.0. VentMac vendors this library
  under `Vendor/mangler/` and `Sources/CVentrilo3/`.
- **Ventrilo packet crypto** — reverse-engineering by Luigi Auriemma.
- App icon and Swift/SwiftUI client code — this project.

## License

**GPL-3.0** — inherited from `libventrilo3`. See [`LICENSE`](LICENSE). The vendored upstream
license and copyright are retained under `Vendor/mangler/` (`COPYING`, `COPYING.LGPL`, `LICENSE`).
