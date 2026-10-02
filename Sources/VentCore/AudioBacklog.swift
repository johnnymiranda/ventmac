import Foundation

/// A generation prevents completions from stopped audio affecting a new stream.
final class AudioBacklog {
    private let lock = NSLock()
    private let limit: Double
    private var pending: Double = 0
    private var generation: UInt64 = 0

    init(limit: Double) { self.limit = limit }

    func reserve(_ duration: Double) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard duration > 0, duration.isFinite, pending + duration <= limit + 0.000001 else { return nil }
        pending += duration
        return generation
    }

    func complete(_ duration: Double, generation token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return }
        pending = max(0, pending - duration)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        pending = 0
    }
}

/// Copies tap data only when there is room; conversion and delivery run off the tap.
final class CaptureDelivery {
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0
    private var pending: Double = 0
    private let limit = 0.2

    func begin() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        pending = 0
        active = true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        generation &+= 1
        pending = 0
    }

    func submit(samples: UnsafePointer<Float>, count: Int, rate: UInt32,
                queue: DispatchQueue, deliver: @escaping (Data, UInt32) -> Void) {
        guard count > 0, rate > 0, lock.try() else { return }
        let duration = Double(count) / Double(rate)
        guard active, pending + duration <= limit else { lock.unlock(); return }
        let token = generation
        pending += duration
        let floats = Data(bytes: samples, count: count * MemoryLayout<Float>.size)
        let submittedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        queue.async { [self] in
            lock.lock()
            let valid = active && token == generation
            lock.unlock()
            defer {
                lock.lock()
                if token == generation { pending = max(0, pending - duration) }
                lock.unlock()
            }
            guard valid, ProcessInfo.processInfo.systemUptime - submittedAt <= limit else { return }
            var pcm = Data(count: count * MemoryLayout<Int16>.size)
            floats.withUnsafeBytes { input in
                let samples = input.bindMemory(to: Float.self)
                pcm.withUnsafeMutableBytes { output in
                    let out = output.bindMemory(to: Int16.self)
                    for i in 0..<count {
                        let value = samples[i].isFinite ? max(-1, min(1, samples[i])) : 0
                        out[i] = Int16(value * 32767)
                    }
                }
            }
            deliver(pcm, rate)
        }
    }
}
