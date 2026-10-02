# VentMac 0.4.0

Test prerelease: the app is Developer ID signed but is not notarized. Apple notarization is pending a developer-account agreement update. The Homebrew stable release remains 0.3.0.

Audio stability and responsiveness improvements:

- Move PCM conversion, voice effects, VOX processing, and transmission off the microphone tap onto a shared serial worker.
- Bound capture backlog to 200 ms and discard stale queued audio after stopping or restarting capture.
- Serialize VOX sensitivity, mute, and gate transitions with audio processing; order PTT/VOX start and stop operations on the same worker.
- Reset per-speaker playback backlog above 250 ms to keep delayed audio from accumulating.
- Detach playback nodes on disconnect and user departure.
- Cache channel-tree rows until roster data changes, preserving live talk indicators.
- Replace per-event roster snapshots with the affected user's previous channel.
- Make C event enqueue constant-time and protect dequeue/clear operations with the queue mutex.
- Build bundled codecs from checksum-pinned sources for macOS 13 instead of inheriting newer Homebrew bottle deployment targets.

Validation: Swift regression tests for roster caching, audio queue bounds and restart behavior, playback accounting, and VOX mute/pre-roll; C queue stress test for FIFO order, concurrent enqueue/dequeue, and clear/reuse.

```sh
swift test
bash Scripts/test-protocol-queue.sh
```

For hands-on testing: try rapid PTT presses, switching between PTT and VOX, changing VOX sensitivity and mute while speaking, enabling the deep-voice effect, reconnecting, and switching audio devices. Live server/audio behavior remains to be verified.
