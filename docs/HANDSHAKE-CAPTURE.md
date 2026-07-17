# Capturing the Ventrilo 3.1.0 login handshake (Windows + tshark)

> **Method record.** This is the packet-capture procedure used to reverse-engineer VentMac's 3.1.0 login; the results are in [HANDSHAKE-FINDINGS.md](./HANDSHAKE-FINDINGS.md). It's kept as a reusable recipe for anyone re-capturing the protocol against a different server or client version. The one-command path is `Scripts/capture-handshake.ps1`; the manual walkthrough below is what that script automates, and a fallback if you'd rather run the steps by hand.

"Mangler" below means the earlier open-source Ventrilo 3 client whose `libventrilo3` C code VentMac vendors ([econnell/mangler](https://github.com/econnell/mangler)).

## Why capture (what the packets tell you)

Ventrilo 3 login has three phases. VentMac's phase 1 already worked; the capture existed to learn phases 2–3 as a present-day 3.1.0 server performs them, since Mangler's hardcoded ~2010 auth endpoints are dead. What each phase involves:

1. **UDP status/version query** — the client sends a `UDCL` packet to the server's UDP port; the server replies with its name/OS/version **and a field at byte offset 56** that Mangler reads to decide whether a remote handshake is needed.
2. **UDP auth handshake** — Mangler contacts one or more **Ventrilo auth servers** and expects a **64-byte handshake key** (seeds the stream cipher) and a **16-byte token** (proof, sent to the game server). This was the broken part. Don't assume the transport — a modern client could use a hostname, a different port, TLS, or no external service.
3. **TCP login** — the client opens TCP to the game server and sends an encrypted auth message containing the token + an auth-server index; everything after is encrypted with keys derived from the 64-byte key.

The most valuable part of a capture is everything between the UDP status reply and the TCP login: DNS lookups, destination host/port/transport, endpoint attempt order, and full packet bytes. TLS/QUIC application payloads stay opaque.

## Setup (Windows)

1. Install Wireshark (includes `tshark`): https://www.wireshark.org/download.html — accept the Npcap driver during install (needed to capture).
2. Configure the working Ventrilo **Windows client** for the target `host:port` and the server password, then exit it completely. Starting the client only after TShark is running captures DNS and setup traffic. `ipconfig /flushdns` just before capture keeps a cached auth hostname from disappearing from the trace.
3. Open a terminal (PowerShell or cmd) **as Administrator** — capturing needs it.
4. Find the capture interface:
   ```
   tshark -D
   ```
Note the adapter carrying the route (Wi-Fi or Ethernet). A selected-interface capture can miss traffic routed through a VPN, loopback, or another adapter; capture each relevant interface if the route changes.
5. Close or pause browsers, game launchers, and sync clients — TShark captures all system traffic, not just Ventrilo's.

## The capture (short and unfiltered on the selected interface)

Don't apply a capture filter on the first run — the auth hostname, IP, port, and transport are unknown, and a filter can hide the modern auth flow. Bound the capture by time instead.

1. Start it (replace `3` with the interface number from `tshark -D`):
   ```
   tshark -i 3 -a duration:45 -w vent-login.pcapng
   ```
`-a duration:45` is a safety stop, not a filter. The pcap may contain unrelated system traffic — keep the window short and treat the file as sensitive.
2. **Leave it running.** Launch Ventrilo, then pause before clicking **Connect**.
3. In a second Administrator PowerShell window, record the client build and its PID-owned sockets before and after connecting (a one-time snapshot can miss a short-lived auth socket):
   ```powershell
   $vent = Get-Process | Where-Object ProcessName -Like 'ventrilo*' | Select-Object -First 1
   if (-not $vent) { throw 'Ventrilo process not found' }
   $vent | Select-Object Id, ProcessName, Path
   (Get-Item $vent.Path).VersionInfo | Select-Object FileVersion, ProductVersion
   Get-FileHash $vent.Path -Algorithm SHA256
   Get-NetTCPConnection -OwningProcess $vent.Id -ErrorAction SilentlyContinue
   Get-NetUDPEndpoint -OwningProcess $vent.Id -ErrorAction SilentlyContinue
   ```
4. Click **Connect**, wait until fully in a channel, and let it sit ~10 seconds so the capture includes post-login traffic. Disconnect, then stop TShark with **Ctrl-C** (or let the 45-second stop end it).
5. Sanity-check:
   ```
   tshark -r vent-login.pcapng -q -z conv,udp
   tshark -r vent-login.pcapng -q -z conv,tcp
   ```
Don't assume a second UDP host must exist — a modern client could use TCP, TLS, QUIC, a same-host service, or cached state.

### Narrower fallback

If a full-interface pcap is unacceptable, a narrower filter still captures every UDP payload plus the game server's TCP, but **misses TCP to any other host** (so it can't rule out a TCP/TLS auth service):

```
tshark -i 3 -a duration:45 -w vent-login-narrow.pcapng -f "host <server> or udp"
```

## Useful outputs to extract

```
# All UDP exchanges with full hex (includes the auth candidate)
tshark -r vent-login.pcapng -Y "udp" -x > vent-udp.txt
# Conversation map (who talked to whom, ports)
tshark -r vent-login.pcapng -q -z conv,udp -z conv,tcp > vent-convos.txt
# DNS names resolved during login
tshark -r vent-login.pcapng -Y "dns.qry.name || dns.a || dns.aaaa" -T fields -e frame.time_relative -e dns.qry.name -e dns.a -e dns.aaaa > vent-dns.txt
# TCP connection-attempt SYNs during login
tshark -r vent-login.pcapng -Y "tcp.flags.syn == 1 && tcp.flags.ack == 0 && !tcp.analysis.retransmission" -T fields -e frame.time_relative -e ip.src -e ip.dst -e tcp.dstport > vent-tcp-opens.txt
```

The raw `vent-login.pcapng` preserves packet ordering and lets you slice any candidate stream; the text dumps are metadata triage, not a substitute (a TCP-based auth flow may need the raw pcap). A capture may contain credentials and session/key material — keep it local and never commit or post it publicly.

## What to determine from a capture

These are the questions a capture needs to answer before patching the handshake — see [HANDSHAKE-FINDINGS.md](./HANDSHAKE-FINDINGS.md) for how they resolved for 3.1.0:

1. **Auth path** — whether a separate service exists and, if so, its DNS name, IP:port, transport, and attempt order. Prefer a hostname over another hardcoded IP.
2. **Offset-56 field** of the UDP status reply — whether the current client uses it the way Mangler assumes.
3. **Key/token model** — whether equivalent key and proof material still exists and whether Mangler's 64-byte key + 16-byte token sizes and format still match.
4. **Endpoint index semantics** — Mangler's `vnum` changes UDP packet obfuscation, while a separate zero-based auth-server index is sent in the encrypted TCP login. A replacement IP:port alone isn't enough unless both mappings still match.

A compatible flow keeps the fix targeted (new endpoint resolution, signed timeout checks, reply validation, a total deadline). Auth behind TLS or a redesigned exchange would need more static/dynamic reverse engineering. Never put a real password on a command line — `-p` exposes it in shell history and the process list.
