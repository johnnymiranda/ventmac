# Ventrilo 3.1.0 login handshake — reverse-engineering notes

These are the notes from making VentMac log into a present-day Ventrilo **3.1.0** server. "Mangler" throughout means the earlier open-source Ventrilo 3 client whose `libventrilo3` C code VentMac vendors ([econnell/mangler](https://github.com/econnell/mangler)); its protocol handling was correct for ~2010-era servers but needed several fixes for 3.1.0.

## Current status: solved

Login **fully works** against live 3.1.0 servers: UDP status → UDP auth handshake → key derivation → the 0x00/0x48 login exchange → the channel and user lists render. Getting there took four fixes, not one:

1. **Dead auth endpoints** — Mangler dialed four hardcoded ~2010 IPs; modern clients resolve `syncN.ventrilo.com` at runtime (this document's original finding).
2. **An unsigned-timeout hang** — a `(uint32_t)-1` compared `< 0` was dead code, so a timeout fell through to a blocking `recvfrom()`.
3. **The wrong handshake version string** — the `0x00` handshake sent `"3.0.0"`; a 3.1.0 server gates on this field and wants `"3.1.0"`.
4. **A dropped-event race** — events queued during login were discarded before the client started reading them.

The rest of this file is the chronological journal, kept for anyone extending the protocol work. The three fixes past the first were found after the initial capture; they're in the dated "Update" sections at the bottom.

> **Sensitive-data note:** this records protocol *structure* only (magic, types, lengths, hostnames, ports, non-secret status fields). Encrypted key/token bodies and the TCP login payload are **not** reproduced — they carry session key material. The raw `captures/*.pcapng` is gitignored and never committed.
>
> **Addresses:** `vent.example.com` / `host.example.com` / `203.0.113.10` are redacted placeholders for the test server. The `syncN.ventrilo.com` addresses (`192.99.245.77`, `51.83.97.34`) are **real, public Ventrilo auth infrastructure**.

## Original capture (the phase-2 endpoint finding)

Captured with the official Windows client + `Scripts/capture-handshake.ps1` (see [HANDSHAKE-CAPTURE.md](./HANDSHAKE-CAPTURE.md)). It confirmed Mangler's three-phase login model and showed that the modern client resolves `syncN.ventrilo.com` at runtime rather than using the dead hardcoded IPs — transport, port, packet magic, and packet type all still match Mangler.

### Capture metadata

| | |
|---|---|
| Date | 2026-07-16 |
| Capture host | Windows 11 |
| Tool | TShark/Wireshark **4.6.7**, Npcap |
| Client | Ventrilo **3.1.0.101**, SHA256 `83CC7D43270911EF754F2BD74E5AC78AC04193F6819DE76A1A6F5F3E402FFF77` |
| Server | `vent.example.com:6085` → `host.example.com` → **203.0.113.10** |
| Method | full unfiltered 45s pcap + 2s Ventrilo-socket poll (`Scripts/capture-handshake.ps1`) |

### Confirmed login flow (relative times)

| t (s) | Phase | Exchange | Result |
|---|---|---|---|
| 2.90 | **1 — UDP status** | `client → 203.0.113.10:6085` | reply received |
| 2.93–3.06 | DNS | resolve `sync5/6/7/8.ventrilo.com`, `proinfo.ventrilo.com` | see below |
| 3.08 | **2 — UDP auth** | `client → 192.99.245.77:6100` (sync5) **and** `→ 51.83.97.34:6100` (sync6) | **both replied** |
| 3.11 | **3 — TCP login** | `client → 203.0.113.10:6085` | 186 frames / 58 kB session |
| 13.2 | aside | `client → 192.99.245.77:5000` — one 78-byte datagram, no reply | `proinfo`, off critical path |

DNS results:

| host | A record |
|---|---|
| `sync5.ventrilo.com` | `192.99.245.77` |
| `sync6.ventrilo.com` | `51.83.97.34` |
| `sync7.ventrilo.com` | **no address** (empty answer) |
| `sync8.ventrilo.com` | **no address** (empty answer; client retried 3×) |
| `proinfo.ventrilo.com` | `192.99.245.77` |

The client queried all four `syncN` hosts and used the two that resolved. A robust client must resolve the set and use whichever answers — do not assume a fixed IP.

### Phase 1 — UDP status reply (offset-56 field confirmed)

Server reply on UDP/6085 is a `UDCL` type-4 status record. Decoded non-secret fields:

- **Offset 56, 16 bytes:** `2f 87 c0 ac b7 17 f3 3b 6f fb 86 0e 11 e9 e7 6b` — **not** sixteen `0x44` (`D`) bytes, so Mangler selects its remote-auth path, and the client did exactly that (it went on to contact sync5/sync6). **Mangler's offset-56 interpretation is correct.**
- Server name field: `…Example Server`
- OS field: `Linux-x86_64`
- Version field: `3.1.0`

### Phase 2 — UDP/6100 auth handshake (the original fix)

Outbound request to each sync server, UDP payload (16-byte header shown; body omitted):

```
00 00 00 00 | 55 44 43 4c | 00 05 | 00 84 | 01 00 00 00 | <116-byte obfuscated body>
             "UDCL"         type=5  len=132
```

Reply from each sync server:

```
00 00 00 00 | 55 44 43 4c | 00 06 | 00 6c | 01 00 00 00 | <92-byte encrypted body>
             "UDCL"         type=6  len=108
```

This is **exactly** Mangler's type-5 probe on UDP/6100 and its type-6 answer. Port (6100), magic (`UDCL`), and request/reply types (5 → 6) all match the vendored code. The 92-byte reply body is the right size to carry Mangler's expected **64-byte handshake key + 16-byte token** plus framing.

**Root cause of the original stall:** Mangler sends this correct packet to four dead hardcoded IPs, gets no reply, and falls through an unsigned-timeout bug into a blocking `recvfrom()`. The endpoints, not the packet, were the problem.

### The phase-2 fix

1. Replace the four hardcoded UDP/6100 IPs with **runtime DNS resolution of `sync5..sync8.ventrilo.com`**; probe the ones that resolve, use the first valid type-6 reply. Keep `proinfo.ventrilo.com` out of the auth path.
2. Use **signed** socket/syscall result types so a timeout can't fall through to a blocking `recvfrom()`.
3. Make timeout/failure propagation real; add a **total deadline** across the probes.
4. **Validate** the type-6 reply (magic, type, length) before deriving keys.

Reproduce with the repo's `ventctl` debug CLI: `ventctl -h <host>:<port> -u <username>` (it prompts for or reads the password; don't put real passwords on the command line).

---

## Update 2026-07-16 (late) — handshake fixed; new blocker = version gate

Applied the phase-2 fix (`ventrilo3_handshake.c`) and re-ran `ventctl`. **The handshake, crypto, and TCP login now all work.**

Changes made:
- `ventrilo3_auth[]` now holds `sync5..sync8.ventrilo.com` (vnum 5–8); a new `ventrilo3_resolve_auth()` DNS-resolves them at runtime; the send loop skips entries that don't resolve (sync7/8).
- Fixed the unsigned-timeout bug: `v3timeout()` returns `(uint32_t)-1`, so `if(v3timeout(...) < 0)` and `if(len < 0)` after `recvfrom` were dead code and fell through to a **blocking** `recvfrom()` — the real indefinite hang. Now checked as signed, plus a 6s total deadline on the auth loop.

Observed result (`V3_DEBUG=2`):
- `authserver index: 0 -> 0` — handshake returned cleanly (was: infinite hang).
- TCP login connected; server replied with a **68-byte type-0x06** packet that **decrypted perfectly** to: `Incompatible version. Server is running version 3.1.0`.
- Decrypting a clean app-level error proves the 64-byte key derivation, the auth-server index (0 accepted), and the stream cipher are all correct.

**Blocker at the time — client/proto version gate.** The 0x48 login carries `client_version[16]` (offset 40) and `proto_version[16]` (offset 104), originally `"3.0.5"` / `"3.0.0"`. Bumping those to `"3.1.0"` / `"3.1.0.101"` did **not** help — the server kept returning "Incompatible version". Resolved in the next update: the gated field is the `0x00` handshake version, not these.

---

## Update 2026-07-17 — auth solved: the version gate was the 0x00 handshake

Decrypted the official client's **first TCP message (0x00 handshake)** straight from the pcap — it uses the fixed `ventrilo_first_enc` key (no session key needed). Framing is `[2-byte BE length=84][84-byte first-enc body]`; `data[i] -= first[i%11] + (i%27)` with `first = AA 55 22 CC 69 7C 38 91 88 F5 E1`.

Result: **the 0x00 handshake version the real client sends is `"3.1.0"`** — the vendored code hardcoded `"3.0.0"` there (`libventrilo3_message.c`, `_v3_put_0x00`). *That* is the field a 3.1.0 server gates on, not the 0x48 client_version/proto_version. Salts in 0x00 are per-session random and don't matter.

Fix: `_v3_put_0x00` now sends `"3.1.0"`. Login authenticates: UDP handshake → key derivation → 0x00/0x48 → the server sends the channel list and user list, the 0x34 login-terminator re-scrambles the keys, and the connection stays stable.

---

## Update 2026-07-17 (later) — the last blocker: an event-queue init race

One symptom remained: after authenticating, the client received live data but never fired `V3_EVENT_LOGIN_COMPLETE`, so the UI never flipped to "connected".

Root cause: `v3_queue_event()` (`libventrilo3.c`) silently **drops** (frees) every event while `eventq_mutex == NULL`:
```c
if (eventq_mutex == NULL) { free(ev); /* "client does not appear to be listening yet" */ return true; }
```
That mutex is created lazily on the **first `v3_get_event()` call**. VentCore's feeder started the consumer (which calls `v3_get_event`) *after* `v3_login()` returned — so during login the mutex was NULL and every event queued during login, including `V3_EVENT_LOGIN_COMPLETE`, was discarded. `V3_DEBUG=3` showed 18 "does not appear to be listening" drops.

Fix (`Sources/VentCore/V3Client.swift`): call `v3_get_event(V3_NONBLOCK)` on the feeder **before** `v3_login()` to force `eventq_mutex` creation; login events then accumulate in the queue and the consumer drains them in order.

**Result — full working login:** status reaches `[100%] Login complete`, a user id is assigned, the server's default codec reads as Speex 32kHz, and the channel tree renders (lobby users plus nested channels). Speex is what this build decodes; GSM was never needed. The remaining work is exercising send/receive audio and global PTT live, which needs another person talking.
