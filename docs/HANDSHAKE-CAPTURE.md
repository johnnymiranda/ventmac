# Capturing the Ventrilo 3.1.0 login handshake (Windows + tshark)

> **Captured 2026-07-16 — results in [HANDSHAKE-FINDINGS.md](./HANDSHAKE-FINDINGS.md).**
> Short version: the phase-2 auth path is `syncN.ventrilo.com` on UDP/6100 (Mangler's
> exact packet, just aimed at dead hardcoded IPs). Automated via
> `Scripts/capture-handshake.ps1`.

**Goal:** record exactly what the official Windows Ventrilo client does when it logs
into `vent.example.com:6085`, so we can update VentMac's handshake. The old
Mangler code we vendored contacts four hardcoded Ventrilo license-server IPs from
~2010 (none answers this flow now), then stalls. We need to see what the *current*
client does instead.

## What we're hunting for (why these packets matter)

The vendored Mangler code models login as three phases. We know phase 1 works;
the capture must confirm whether the current Windows client connecting to this
3.1.0 server still uses phases 2–3 in this form.

1. **UDP status/version query** — client sends a `UDCL` packet to the server's UDP
   port; server replies with its name/OS/version **and a field at byte offset 56**
   that Mangler interprets as deciding whether a remote handshake is needed.
   *(VentMac gets this far; the capture must test Mangler's interpretation.)*
2. **Legacy UDP auth handshake** — Mangler contacts one or more **Ventrilo
   auth/license servers** and expects a **64-byte handshake key** (seeds the stream
   cipher) and a **16-byte handshake token** (proof, sent to the game server). This
   is the broken part. The official client may use a hostname, a different transport,
   or no external auth service at all; do not assume it is still UDP/6100.
3. **TCP login** — Mangler opens TCP to the game server and sends an encrypted auth
   message containing the 16-byte token + an auth-server index. Everything after is
   encrypted with keys derived from the 64-byte handshake key. The capture must
   confirm that the current client still does this.

The single most valuable thing in the capture is everything the official client does
between the UDP status reply and the game-server TCP login: DNS lookups, destination
host/port/transport, endpoint attempt order, full packet bytes, and observable
connection metadata. TLS/QUIC application payloads would remain opaque.

## Known VentMac baseline (2026-07-16)

- `vent.example.com` resolves through `host.example.com` to
  `203.0.113.10` from the Mac used for testing.
- The phase-1 query gets a 200-byte UDP reply immediately. Bytes 56–71 are
  `2f87c0acb717f33b6ffb860e11e9e76b`, not sixteen `D` bytes, so Mangler selects
  its remote-auth path.
- Mangler's correctly encoded type-5 probes to its four hardcoded UDP/6100
  endpoints received no replies during a five-second local test. That proves the
  endpoints are unusable for this path from this network; UDP silence alone does
  not prove the machines or addresses no longer exist.
- The current indefinite stall is local too: an unsigned timeout result falls
  through to blocking `recvfrom()`. A Windows capture is still required to learn
  the working protocol.

## Setup on the Windows machine

1. Install Wireshark (includes `tshark`): https://www.wireshark.org/download.html —
   accept the Npcap driver during install (needed to capture).
2. Configure the working Ventrilo **Windows client** for `vent.example.com` port
   `6085` and the server password, then exit it completely. Starting the process
   only after TShark is running gives us the best chance of seeing DNS and setup
   traffic. If acceptable on that machine, run `ipconfig /flushdns` just before
   capture so a cached auth hostname does not disappear from the trace.
3. Open a terminal (PowerShell or cmd) **as Administrator** — capturing needs it.
4. Find your capture interface name:
   ```
   tshark -D
   ```
   Note the number/name of the adapter carrying Ventrilo's route (Wi-Fi or Ethernet).
   A selected-interface capture can miss traffic routed through a VPN, loopback, or
   another adapter; capture each relevant interface if the route changes.

5. Close or pause browsers, game launchers, sync clients, and other noisy network
   applications. TShark captures system traffic, not just Ventrilo traffic.

## The capture (recommended: short and unfiltered on the selected interface)

Do not apply a capture filter on the first run. We do not know the auth hostname,
IP, port, or transport. The old filter dropped DNS and UDP/443 and allowed unknown
UDP but not unknown TCP, any of which could hide the modern auth flow. Limit the
capture by time instead; `-a duration:45` makes TShark stop automatically after
45 seconds.

1. Start the capture (replace `3` with your interface number from `tshark -D`).
   This writes a full, time-bounded pcap:
   ```
   tshark -i 3 -a duration:45 -w vent-login.pcapng
   ```
   - `-w vent-login.pcapng` preserves full packet bytes in pcapng format.
   - `-a duration:45` is a safety stop, not a traffic filter.
   - This can contain unrelated system traffic. Keep the window short and treat the
     file as sensitive.

2. **Leave it running.** Launch Ventrilo, then pause before clicking **Connect**.

3. In a second Administrator PowerShell window, record the exact client build and
   its PID-owned sockets before clicking **Connect**. Repeat the two `Get-Net*`
   commands once connected; a one-time snapshot can miss a short-lived auth socket.
   TCP rows include remote endpoints, while UDP rows identify the local port that
   can be correlated with the pcap:
   ```powershell
   $vent = Get-Process | Where-Object ProcessName -Like 'ventrilo*' | Select-Object -First 1
   if (-not $vent) { throw 'Ventrilo process not found' }
   $vent | Select-Object Id, ProcessName, Path
   (Get-Item $vent.Path).VersionInfo | Select-Object FileVersion, ProductVersion
   Get-FileHash $vent.Path -Algorithm SHA256
   Get-NetTCPConnection -OwningProcess $vent.Id -ErrorAction SilentlyContinue
   Get-NetUDPEndpoint -OwningProcess $vent.Id -ErrorAction SilentlyContinue
   ```

4. Click **Connect**. Wait until fully in a channel and let it sit for about 10
   seconds so the capture includes post-login traffic. Disconnect in Ventrilo, then
   stop TShark with **Ctrl-C** (or let the 45-second safety stop end it).

5. Sanity-check what you got:
   ```
   tshark -r vent-login.pcapng -q -z conv,udp
   tshark -r vent-login.pcapng -q -z conv,tcp
   ```
   Do not assume that a second UDP host must exist. A modern client could use TCP,
   TLS, QUIC, a same-host service, cached state, or no external service.

### Narrower fallback

If the broader selected-interface pcap is unacceptable, use the old narrower filter as a
fallback:

```
tshark -i 3 -a duration:45 -w vent-login-narrow.pcapng -f "host vent.example.com or udp"
```

This still captures **every UDP payload on the selected interface**, including
ordinary UDP DNS, and remains sensitive. It can miss TCP DNS, cannot expose DNS over
HTTPS, and **will miss TCP to any host other than the game server**. A negative result
from this narrower capture cannot rule out a TCP/TLS auth service.

## Quick views to hand back (fast path)

If you want to eyeball it before sending the whole file, these dumps are what I
need most:

- **All UDP exchanges with full hex** (includes the legacy auth candidate):
  ```
  tshark -r vent-login.pcapng -Y "udp" -x > vent-udp.txt
  ```
- **Just the conversation map** (who talked to whom, ports):
  ```
  tshark -r vent-login.pcapng -q -z conv,udp -z conv,tcp > vent-convos.txt
  ```
- **DNS names resolved during login:**
  ```
  tshark -r vent-login.pcapng -Y "dns.qry.name || dns.a || dns.aaaa" -T fields -e frame.time_relative -e dns.qry.name -e dns.a -e dns.aaaa > vent-dns.txt
  ```
- **TCP connection-attempt SYNs during login** (check direction; excludes marked
  retransmissions):
  ```
  tshark -r vent-login.pcapng -Y "tcp.flags.syn == 1 && tcp.flags.ack == 0 && !tcp.analysis.retransmission" -T fields -e frame.time_relative -e ip.src -e ipv6.src -e ip.dst -e ipv6.dst -e tcp.dstport > vent-tcp-opens.txt
  ```

## What to hand back

Easiest: **send me `vent-login.pcapng`** (the raw capture) — it preserves packet
ordering and lets me slice any candidate stream. `vent-udp.txt`, `vent-convos.txt`,
`vent-dns.txt`, and `vent-tcp-opens.txt` are useful metadata triage, not a complete
substitute; a TCP-based auth flow may require the raw pcap or a targeted TCP stream
dump. Assume credentials, session/key material, and unrelated application data may
be recoverable. Do not post captures or derived dumps publicly.

## When we're back together (session on Windows)

With the capture open we'll answer these before patching the handshake:

1. **Auth path** — whether a separate service exists and, if so, its DNS name,
   IP:port, transport, and attempt order. Prefer a hostname over another hardcoded IP.
2. **Field at offset 56** of the server's UDP status reply — whether the current
   client uses it the way Mangler assumes.
3. **Key/token model** — whether equivalent key and proof material still exists and,
   if it is observable or decryptable, whether Mangler's 64-byte key + 16-byte token
   sizes and format still match.
4. **Endpoint ordinal/index semantics** — Mangler's `vnum` changes UDP packet
   obfuscation, while a separate zero-based auth-server index is sent in the encrypted
   TCP login. A replacement IP:port alone is not enough unless both mappings still
   match.

If the capture confirms a compatible flow, the repair can stay targeted, but it is
broader than replacing an endpoint: use signed socket/syscall result types, make
timeout/failure propagation real, validate the reply, initialize/check handshake
outputs, add a total deadline, implement the captured auth mapping, rebuild, and re-run
`ventctl -h vent.example.com:6085 -u <username> -p '<server-password>'`.

If auth is protected by TLS, cached proprietary state, or a redesigned exchange, plan
on additional static/dynamic reverse engineering before patching.

Do not commit a real password. Note that `-p` also exposes it temporarily in shell
history and the process list; a future CLI improvement should read it from a prompt
or protected file descriptor instead.
