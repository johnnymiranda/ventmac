import XCTest
@testable import VentCore

final class AudioQueueTests: XCTestCase {
    func testPlaybackBudgetAndStaleCompletions() throws {
        let backlog = AudioBacklog(limit: 0.25)
        let old = try XCTUnwrap(backlog.reserve(0.2))
        XCTAssertNil(backlog.reserve(0.1))
        backlog.reset()
        let current = try XCTUnwrap(backlog.reserve(0.2))
        backlog.complete(0.2, generation: old)
        XCTAssertNil(backlog.reserve(0.1))
        backlog.complete(0.2, generation: current)
        XCTAssertNotNil(backlog.reserve(0.1))
        XCTAssertNil(backlog.reserve(.infinity))
        XCTAssertNil(backlog.reserve(0))
    }

    func testCaptureBacklogIsBoundedAndCopiesTapData() {
        let worker = DispatchQueue(label: "capture-test")
        let delivery = CaptureDelivery()
        let ready = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        worker.async { ready.signal(); resume.wait() }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        delivery.begin()
        let received = expectation(description: "bounded chunks")
        received.expectedFulfillmentCount = 2
        received.assertForOverFulfill = true
        var samples = [Float](repeating: 0.5, count: 100)
        for _ in 0..<10 {
            samples.withUnsafeBufferPointer { buffer in
                delivery.submit(samples: buffer.baseAddress!, count: buffer.count, rate: 1000, queue: worker) { pcm, _ in
                    pcm.withUnsafeBytes { bytes in
                        XCTAssertEqual(bytes.bindMemory(to: Int16.self)[0], 16383)
                    }
                    received.fulfill()
                }
            }
        }
        samples[0] = -1
        resume.signal()
        wait(for: [received], timeout: 2)
        worker.sync {}
    }

    func testStopDiscardsOldCaptureAcrossRestart() {
        let worker = DispatchQueue(label: "capture-restart-test")
        let delivery = CaptureDelivery()
        let ready = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        worker.async { ready.signal(); resume.wait() }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        let received = expectation(description: "new session only")
        received.assertForOverFulfill = true
        let samples = [Float](repeating: 0, count: 40)
        delivery.begin()
        samples.withUnsafeBufferPointer { buffer in
            delivery.submit(samples: buffer.baseAddress!, count: buffer.count, rate: 1000, queue: worker) { _, _ in
                XCTFail("Stopped session delivered stale audio")
            }
            delivery.stop()
            delivery.begin()
            delivery.submit(samples: buffer.baseAddress!, count: buffer.count, rate: 1000, queue: worker) { _, _ in
                received.fulfill()
            }
        }
        resume.signal()
        wait(for: [received], timeout: 2)
        worker.sync {}
    }

    func testVoxMuteClearsPrerollAndResetPreservesMute() {
        let gate = VoxGate()
        let loud = [Int16](repeating: 10000, count: 40).withUnsafeBytes { Data($0) }
        let quiet = Data(count: 80)
        XCTAssertEqual(gate.process(pcm: quiet, rate: 1000), .idle)
        if case .open(let chunks) = gate.process(pcm: loud, rate: 1000) {
            XCTAssertEqual(chunks.count, 2)
        } else { XCTFail("Expected gate to open") }
        gate.muted = true
        XCTAssertEqual(gate.process(pcm: loud, rate: 1000), .close)
        gate.reset()
        XCTAssertEqual(gate.process(pcm: loud, rate: 1000), .idle)
        gate.muted = false
        if case .open(let chunks) = gate.process(pcm: loud, rate: 1000) {
            XCTAssertEqual(chunks.count, 1)
        } else { XCTFail("Expected unmuted gate to reopen") }
    }
}
