import Foundation

private final class DelayedImageTransport: ImageControlTransport {
    let imageControlVersion: UInt16 = 0x0150
    var writes = 0
    var confirmations = 0
    private var value: UInt32 = 50
    private var target: UInt32?

    func supportsImageControl(_ id: UVCImageControl) -> Bool { id == .contrast }
    func readImageControl(_ id: UVCImageControl, request: UInt8) throws -> [UInt8] {
        precondition(id == .contrast)
        if request == 0x86 { return [3] }
        let raw: UInt32
        switch request {
        case 0x81:
            if let target {
                confirmations += 1
                if confirmations >= 3 { value = target }
            }
            raw = value
        case 0x82: raw = 0
        case 0x83: raw = 100
        case 0x84: raw = 1
        default: preconditionFailure("Unexpected request")
        }
        return try UVCUnsignedValue.encode(raw, width: 2)
    }
    func writeImageControl(_ id: UVCImageControl, bytes: [UInt8]) throws {
        precondition(id == .contrast)
        writes += 1
        target = try UVCUnsignedValue.decode(bytes, width: 2, allowShort: false)
    }
}

// Mutable test state, like the production scheduler, belongs only to queue.
private final class QueueChecks: @unchecked Sendable {
    private let queue = DispatchQueue(label: "control-queue-checks")
    private lazy var commands = CameraControlQueue(queue: queue)
    private var events: [String] = []
    private var oldPolls = 0
    private var newPolls = 0
    private var current = true
    private var timeoutPolls = 0

    private var control: CameraControl {
        CameraControl(id: .contrast, title: "Contrast",
                      kind: .numeric(CameraControlRange(minimum: 0, maximum: 100, step: 1)),
                      unit: .device, access: .writable, dependency: nil,
                      value: .number(75), initial: .number(50))
    }

    func checkOrdering() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                let transport = DelayedImageTransport()
                let backend = ImageControlBackend(transport: transport)
                let started = ProcessInfo.processInfo.systemUptime
                commands.enqueue(isCurrent: { true }, begin: {
                    try backend.beginWrite(.contrast, value: .number(75), shouldContinue: { true })
                }, report: { result in
                    guard case .success(let setting) = result else { preconditionFailure("Write failed") }
                    precondition(setting.value == .number(75) && transport.confirmations == 4)
                    precondition(ProcessInfo.processInfo.systemUptime - started >= 0.4)
                    self.events.append("confirmed")
                })
                // The write returns after SET, before even the first confirmation.
                precondition(transport.writes == 1 && transport.confirmations == 0)
                precondition(!commands.isIdle, "Telemetry must not interleave with confirmation")
                commands.enqueue(isCurrent: { true }, begin: {
                    precondition(transport.confirmations == 4)
                    self.events.append("next command")
                    return .complete(try backend.read(.contrast))
                }, report: { result in
                    guard case .success = result else { preconditionFailure("Read failed") }
                    precondition(self.events == ["capture queue free", "confirmed", "next command"])
                    done.resume()
                })
                queue.async { self.events.append("capture queue free") }
            }
        }
        print("PASS: real image backend waits without blocking capture work; control commands remain ordered")
    }

    func checkCancellation() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                commands.enqueue(isCurrent: { true }, begin: {
                    .pending(CameraControlConfirmation(failureMessage: "old timeout") {
                        self.oldPolls += 1
                        // Simulate mode change/teardown between confirmation reads.
                        self.queue.async {
                            self.commands.cancelAll()
                            precondition(self.commands.isIdle)
                            self.commands.enqueue(isCurrent: { true }, begin: {
                                .pending(CameraControlConfirmation(failureMessage: "new timeout") {
                                    self.newPolls += 1
                                    return self.newPolls == 2 ? self.control : nil
                                })
                            }, report: { result in
                                guard case .success = result else { preconditionFailure("New session failed") }
                                precondition(self.oldPolls == 1 && self.newPolls == 2)
                                // Also exercise enqueue from a completion callback.
                                self.commands.enqueue(isCurrent: { true }, begin: {
                                    .complete(self.control)
                                }, report: { _ in done.resume() })
                            })
                        }
                        return nil
                    })
                }, report: { _ in preconditionFailure("Cancelled write reported a result") })
                commands.enqueue(isCurrent: { true }, begin: {
                    preconditionFailure("Cancelled pending command was sent")
                }, report: { _ in preconditionFailure("Cancelled command reported a result") })
            }
        }
        print("PASS: cancellation drops pending work and stale timers cannot poll a new session")
    }

    func checkStaleRevision() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                commands.enqueue(isCurrent: { self.current }, begin: {
                    .pending(CameraControlConfirmation(failureMessage: "stale") {
                        preconditionFailure("Stale confirmation reached the transport")
                    })
                }, report: { _ in preconditionFailure("Stale result reported") })
                commands.enqueue(isCurrent: { self.current }, begin: {
                    preconditionFailure("Stale queued command was sent")
                }, report: { _ in preconditionFailure("Stale queued result reported") })
                current = false
                commands.enqueue(isCurrent: { true }, begin: { .complete(self.control) }, report: { _ in done.resume() })
            }
        }
        print("PASS: changed revision cancels confirmation before USB I/O and skips stale queued commands")
    }

    func checkFailures() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                events.removeAll()
                commands.enqueue(isCurrent: { true }, begin: {
                    .pending(CameraControlConfirmation(failureMessage: "confirmation timeout") {
                        self.timeoutPolls += 1
                        return nil
                    })
                }, report: { result in
                    guard case .failure(let error) = result else { preconditionFailure("Timeout accepted") }
                    precondition(error.localizedDescription == "confirmation timeout" && self.timeoutPolls == 8)
                    self.events.append("timeout")
                })
                commands.enqueue(isCurrent: { true }, begin: {
                    throw CameraControlError.invalid("SET failed")
                }, report: { result in
                    guard case .failure = result else { preconditionFailure("SET failure accepted") }
                    self.events.append("SET failure")
                })
                commands.enqueue(isCurrent: { true }, begin: {
                    .pending(CameraControlConfirmation(failureMessage: "unused") {
                        throw CameraControlError.invalid("Read failed")
                    })
                }, report: { result in
                    guard case .failure = result else { preconditionFailure("Read failure accepted") }
                    self.events.append("read failure")
                })
                commands.enqueue(isCurrent: { true }, begin: { .complete(self.control) }, report: { _ in
                    precondition(self.events == ["timeout", "SET failure", "read failure"])
                    done.resume()
                })
            }
        }
        print("PASS: eight-read timeout and SET/read failures release the next command exactly once")
    }
}

@main
private struct CameraControlQueueChecks {
    static func main() async {
        let checks = QueueChecks()
        await checks.checkOrdering()
        await checks.checkCancellation()
        await checks.checkStaleRevision()
        await checks.checkFailures()
    }
}
