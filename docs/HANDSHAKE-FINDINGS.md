# Ventrilo 3.1.0 login handshake — capture results (2026-07-16)

Results of the capture described in [HANDSHAKE-CAPTURE.md](./HANDSHAKE-CAPTURE.md).
The capture is **complete and decisive**: it confirms Mangler's three-phase login
model and shows that the *only* thing broken in the vendored code is the phase-2
endpoint list — Mangler dials four hardcoded ~2010 IPs; the modern client resolves
`syncN.ventrilo.com` at runtime. Transport, port, packet magic, and packet type all
still match Mangler.

> **Sensitive-data note:** this document records protocol *structure* only (magic,
> types, lengths, hostnames, ports, non-secret status fields). The encrypted phase-2
> key/token bodies and the TCP login payload are **not** reproduced here — they carry
> session key material. The raw `captures/*.pcapng` stays local and gitignored; it is
> not in this repo. See "Handing the pcap to the Mac" below.

## Capture metadata

| | |
|---|---|
| Date | 2026-07-16 23:30:39 local |
| Capture host | Windows 11, `192.168.1.21`, iface **Ethernet** (Realtek 2.5GbE) |
| Tool | TShark/Wireshark **4.6.7**, Npcap |
| Client | Ventrilo **3.1.0.101**, SHA256 `83CC7D43270911EF754F2BD74E5AC78AC04193F6819DE76A1A6F5F3E402FFF77` |
| Server | `vent.example.com:6085` → `host.example.com` → **203.0.113.10** |
| Method | full unfiltered 45s pcap + 2s Ventrilo-socket poll (`Scripts/capture-handshake.ps1`) |

## Confirmed login flow (relative times)

| t (s) | Phase | Exchange | Result |
|---|---|---|---|
| 2.90 | **1 — UDP status** | `192.168.1.21:64993 → 203.0.113.10:6085` | reply received |
| 2.93–3.06 | DNS | resolve `sync5/6/7/8.ventrilo.com`, `proinfo.ventrilo.com` | see below |
| 3.08 | **2 — UDP auth** | `:64993 → 192.99.245.77:6100` (sync5) **and** `→ 51.83.97.34:6100` (sync6) | **both replied** |
| 3.11 | **3 — TCP login** | `:53399 → 203.0.113.10:6085` | 186 frames / 58 kB session |
| 13.2 | aside | `:62191 → 192.99.245.77:5000` — one 78-byte datagram, no reply | `proinfo`, off critical path |

DNS results:

| host | A record |
|---|---|
| `sync5.ventrilo.com` | `192.99.245.77` |
| `sync6.ventrilo.com` | `51.83.97.34` |
| `sync7.ventrilo.com` | **no address** (empty answer) |
| `sync8.ventrilo.com` | **no address** (empty answer; client retried 3×) |
| `proinfo.ventrilo.com` | `192.99.245.77` |

The client queried all four `syncN` hosts and used the two that resolved. A robust
client must resolve the set and use whichever answer — do not assume a fixed IP.

## Phase 1 — UDP status reply (offset-56 field confirmed)

Server reply on UDP/6085 is a `UDCL` type-4 status record. Decoded non-secret fields:

- **Offset 56, 16 bytes:** `2f 87 c0 ac b7 17 f3 3b 6f fb 86 0e 11 e9 e7 6b`
  — byte-for-byte the baseline in HANDSHAKE-CAPTURE.md. It is **not** sixteen `0x44`
  (`D`) bytes, so Mangler selects its remote-auth path — and the client did exactly
  that (it went on to contact sync5/sync6). **Mangler's offset-56 interpretation is
  correct.**
- Server name field: `…Example Server`
- OS field: `Linux-x86_64`
- Version field: `3.1.0`

## Phase 2 — UDP/6100 auth handshake (this is the fix)

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

This is **exactly** Mangler's "correctly encoded type-5 probe on UDP/6100" and its
type-6 answer. Port (6100), magic (`UDCL`), and request/reply types (5 → 6) all match
the vendored code. The 92-byte reply body is the right size to carry Mangler's
expected **64-byte handshake key + 16-byte token** plus framing.

**Root cause of the stall:** Mangler sends this correct packet to four dead hardcoded
IPs, gets no reply, and (per HANDSHAKE-CAPTURE.md) falls through an unsigned-timeout
bug into a blocking `recvfrom()`. The endpoints, not the packet, are the problem.

## Answers to HANDSHAKE-CAPTURE.md's four questions

1. **Auth path** — ✅ Separate service exists: `syncN.ventrilo.com` (N=5..8),
   **UDP/6100**, `UDCL` type-5 → type-6. Prefer the hostnames (resolve at runtime;
   only sync5+sync6 are live here). Both live servers are hit near-simultaneously.
2. **Offset-56 field** — ✅ Confirmed; Mangler's interpretation matches the live client.
3. **Key/token model** — ✅ Structurally consistent (92-byte body ⊇ 64+16). Exact
   layout still needs the type-6 body decrypted to confirm — see open items.
4. **Endpoint ordinal/index** — ⚠️ Client used two servers (sync5, sync6). The
   zero-based auth-server index sent in the encrypted TCP login must map to one of
   them; correlating that requires decrypting the TCP login — see open items.

## Proposed VentMac fix (targeted; follows the doc's repair checklist)

1. Replace the four hardcoded UDP/6100 IPs with **runtime DNS resolution of
   `sync5..sync8.ventrilo.com`**; probe the ones that resolve, use the first/valid
   type-6 reply. Keep `proinfo.ventrilo.com` out of the auth path.
2. Use **signed** socket/syscall result types so a timeout can't fall through to a
   blocking `recvfrom()`.
3. Make timeout/failure propagation real; add a **total deadline** across the probes.
4. **Validate** the type-6 reply (magic, type, length) before deriving keys.
5. Initialize/check handshake outputs (64-byte key, 16-byte token).
6. Rebuild and re-run:
   `ventctl -h vent.example.com:6085 -u <username> -p '<server-password>'`
   (don't commit a real password; `-p` also exposes it in shell history / process list
   — a future CLI change should read it from a prompt or fd).

## Open items (need the pcap on the Mac)

- **Decrypt the type-6 reply body** to confirm the exact 64-byte key + 16-byte token
  offsets/layout.
- **Correlate the auth-server index** in the TCP login to sync5 vs sync6 (Mangler's
  `vnum` obfuscation vs the zero-based index in the encrypted TCP message).

## Handing the pcap to the Mac

The raw capture is **not** on GitHub (gitignored, sensitive). To continue the decrypt
work on the Mac, copy it over a trusted channel — e.g. Tailscale:

```
# on the Mac
scp john@<windows-tailscale-host>:'C:/Users/John/code/ventmac/captures/vent-login-20260716-233039.pcapng' ./captures/
```

Triage dumps (`vent-udp`, `vent-convos`, `vent-dns`, `vent-tcp-opens`, `vent-snapshot`)
live alongside it in `captures/` and are equally sensitive.

---

## Update 2026-07-16 (late) — handshake fixed on the Mac; new blocker = version gate

Applied the phase-2 fix (`ventrilo3_handshake.c`) and re-ran `ventctl` against
`vent.example.com:6085`. **The handshake, crypto, and TCP login now all work.**

Changes made:
- `ventrilo3_auth[]` now holds `sync5..sync8.ventrilo.com` (vnum 5–8); a new
  `ventrilo3_resolve_auth()` DNS-resolves them at runtime; the send loop skips
  entries that don't resolve (sync7/8).
- Fixed the unsigned-timeout bug: `v3timeout()` returns `(uint32_t)-1`, so
  `if(v3timeout(...) < 0)` and `if(len < 0)` after `recvfrom` were dead code and
  fell through to a **blocking** `recvfrom()` — the real indefinite hang. Now
  checked as signed, plus a 6s total deadline on the auth loop.

Observed result (V3_DEBUG=2):
- `authserver index: 0 -> 0` — handshake returned cleanly (was: infinite hang).
- TCP login connected; server replied with a **68-byte type-0x06** packet that
  **decrypted perfectly** to: `Incompatible version. Server is running version 3.1.0`.
- Decrypting a clean app-level error proves the 64-byte key derivation, the
  auth-server index (0 accepted), and the stream cipher are all correct.

**Remaining blocker — client/proto version gate.** The 0x48 login carries
`client_version[16]` (offset 40) and `proto_version[16]` (offset 104), originally
`"3.0.5"` / `"3.0.0"`. Tried `"3.1.0"` and `"3.1.0.101"` for the client version and
`"3.1.0"` for proto — wire dump confirms the bytes go out correctly — and the server
**still** returns the same "Incompatible version" 0x06. So it validates an exact value
we can't guess from the error string.

**Next (needs the pcap on the Mac):** decrypt the official client's 0x48 login in
`vent-login-*.pcapng` and read the literal `client_version` / `proto_version` bytes it
sends; set them in `libventrilo3_message.h`. Decryption needs that session's 64-byte
handshake key (derivable from the captured type-6 reply body + the sync server IP/vnum).
Bring the pcap over (scp/Tailscale, see above) and this is a short exercise.

---

## Update 2026-07-17 — AUTH SOLVED: the version gate was the 0x00 handshake

Decrypted the official client's **first TCP message (0x00 handshake)** straight from
the pcap — it uses the fixed `ventrilo_first_enc` key (no session key needed). Framing
is `[2-byte BE length=84][84-byte first-enc body]`; `data[i] -= first[i%11] + (i%27)`
with `first = AA 55 22 CC 69 7C 38 91 88 F5 E1`.

Result: **the 0x00 handshake version the real client sends is `"3.1.0"`** — our vendored
code hardcoded `"3.0.0"` there (libventrilo3_message.c `_v3_put_0x00`). *That* is the
field the 3.1.0 server gates on, NOT the 0x48 client_version/proto_version (which is why
bumping those did nothing). Salts in 0x00 are per-session random — irrelevant to us.

Fix: `_v3_put_0x00` now sends `"3.1.0"`. **Login now authenticates against the live
vent.example.com server:** UDP handshake → key derivation → 0x00/0x48 → server sends the
channel list (channel "dadlock") and user list (3 users online), 0x34 login-terminator
re-scrambles the keys, connection stays stable (no disconnect). The whole hard blocker is
gone.

### Remaining (small, next session): LOGIN_COMPLETE doesn't fire
After the `do{...}while(type != 0x34)` login loop in `v3_login` receives and processes
0x34 (keys re-scramble, "packet processed"), the post-loop block that sends 0x5c/0x46 and
queues `V3_EVENT_LOGIN_COMPLETE` never runs — TCP receives just continue. So ventctl/the
app never flip to the "connected" UI state or render the tree, despite receiving live
data. Suspect the feeder/consumer threading around `v3_login`'s blocking loop, or a
3.1.0 post-0x34 finalization difference. This is the only thing between "authenticated"
and "usable". Debug with `V3_DEBUG=2`; the session transcript is reproducible against the
live server.
