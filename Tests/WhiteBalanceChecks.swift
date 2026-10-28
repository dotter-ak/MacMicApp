import Foundation

private final class WhiteBalanceTransport: ImageControlTransport {
    var imageControlVersion: UInt16 = 0x0100
    var flicker: UInt32 = 2
    var whiteBalanceRequiresTemperatureCommit = true
    var cameraNeedsCommit = true
    var auto: UInt32 = 1
    var temperature: UInt32 = 2144
    var pendingOff = false
    var rejectTemperature = false
    var ignoreTemperature = false
    var minimum: UInt32 = 0
    var maximum: UInt32 = 8192
    var step: UInt32 = 1
    var info: UInt8 = 3
    var maximumAfterAutoWrite: UInt32?
    var requests: [(UVCImageControl, UInt8)] = []
    var writes: [(UVCImageControl, [UInt8])] = []

    func supportsImageControl(_ id: UVCImageControl) -> Bool {
        id == .autoWhiteBalance || id == .whiteBalance || id == .contrast || id == .antiFlicker
    }
    func readImageControl(_ id: UVCImageControl, request: UInt8) throws -> [UInt8] {
        requests.append((id, request))
        if request == 0x86 { return [info] }
        let value: UInt32
        switch request {
        case 0x81: value = id == .autoWhiteBalance ? auto : (id == .antiFlicker ? flicker : temperature)
        case 0x82: value = minimum
        case 0x83: value = maximum
        case 0x84: value = step
        default: throw CameraControlError.invalid("Unexpected request")
        }
        return try UVCUnsignedValue.encode(value, width: id.width)
    }
    func writeImageControl(_ id: UVCImageControl, bytes: [UInt8]) throws {
        writes.append((id, bytes))
        let value = try UVCUnsignedValue.decode(bytes, width: id.width, allowShort: false)
        if id == .antiFlicker {
            flicker = value
        } else if id == .autoWhiteBalance {
            if let maximumAfterAutoWrite { maximum = maximumAfterAutoWrite }
            if value == 0 && cameraNeedsCommit { pendingOff = true }
            else { auto = value; pendingOff = false }
        } else {
            if rejectTemperature { throw CameraControlError.invalid("Temperature SET failed") }
            if ignoreTemperature { return }
            temperature = value
            if pendingOff { auto = 0; pendingOff = false }
        }
    }
}

@main struct WhiteBalanceChecks {
    static func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected failure") } catch {}
    }
    static func main() throws {
        let flickerTransport = WhiteBalanceTransport()
        let flickerBackend = ImageControlBackend(transport: flickerTransport)
        let flickerControl = try flickerBackend.read(.antiFlicker)
        precondition(flickerControl.value == .option(.antiFlicker(.hz60)))
        _ = try flickerBackend.write(.antiFlicker, value: .option(.antiFlicker(.hz50)))
        precondition(flickerTransport.writes.last?.1 == [1])
        rejects { _ = try flickerBackend.write(.antiFlicker, value: .option(.antiFlicker(.auto))) }
        rejects { _ = try flickerBackend.write(.antiFlicker, value: .option(.exposure(.auto))) }
        flickerTransport.imageControlVersion = 0x0150
        _ = try flickerBackend.write(.antiFlicker, value: .option(.antiFlicker(.auto)))
        precondition(flickerTransport.writes.last?.1 == [3])
        print("PASS: typed anti-flicker wire values, version-gated Auto and cross-control option rejection")
        let manualTransport = WhiteBalanceTransport()
        manualTransport.auto = 0
        let manualBackend = ImageControlBackend(transport: manualTransport)
        _ = try manualBackend.write(.whiteBalance, value: .number(3000))
        precondition(manualTransport.requests.count == 15 && manualTransport.writes.count == 1,
                     "WB: read Auto once per stage, not twice before SET")
        precondition(manualTransport.requests.filter { $0.0 == .autoWhiteBalance && $0.1 == 0x81 }.count == 3)
        manualTransport.requests.removeAll()
        _ = try manualBackend.read(.whiteBalance)
        precondition(manualTransport.requests.allSatisfy { $0.0 == .whiteBalance }, "A numeric snapshot needs no discarded Auto read")
        let interruptedByAuto = try manualBackend.beginWrite(.whiteBalance, value: .number(3200), shouldContinue: { true })
        guard case .pending(let confirmation) = interruptedByAuto else { preconditionFailure() }
        manualTransport.auto = 1
        rejects { for _ in 0..<8 { _ = try confirmation.poll() } }
        print("PASS: manual WB 18 → 16 USB requests and Auto changes still invalidate confirmation")
        // Measure complete backend operations, not a stand-alone cache helper.
        let measured = WhiteBalanceTransport()
        let measuredBackend = ImageControlBackend(transport: measured)
        let contrast = try measuredBackend.write(.contrast, value: .number(3000), shouldContinue: { true })
        precondition(contrast.value == .number(3000))
        precondition(measured.requests.count == 9 && measured.writes.count == 1,
                     "Contrast: 9 GET + 1 SET instead of 15 GET + 1 SET")
        for request: UInt8 in [0x82, 0x83, 0x84] {
            precondition(measured.requests.filter { $0.0 == .contrast && $0.1 == request }.count == 1)
        }
        for request: UInt8 in [0x81, 0x86] {
            precondition(measured.requests.filter { $0.0 == .contrast && $0.1 == request }.count == 3,
                         "Current value and access must be refreshed before and after SET")
        }
        measured.maximum = 2500; measured.temperature = 2000
        rejects { _ = try measuredBackend.write(.contrast, value: .number(2600), shouldContinue: { true }) }
        precondition(measured.writes.count == 1, "New command must use new limits")
        measured.maximum = 4000
        _ = try measuredBackend.write(.contrast, value: .number(2600), shouldContinue: { true })
        measured.info = 1
        rejects { _ = try measuredBackend.write(.contrast, value: .number(2700), shouldContinue: { true }) }
        precondition(measured.writes.count == 2, "Fresh read-only flags must prevent SET")
        measured.info = 3; measured.ignoreTemperature = true
        rejects { _ = try measuredBackend.write(.contrast, value: .number(2700), shouldContinue: { true }) }
        measured.maximum = 2650
        let failedWrites = measured.writes.count
        rejects { _ = try measuredBackend.write(.contrast, value: .number(2700), shouldContinue: { true }) }
        precondition(measured.writes.count == failedWrites, "Failed confirmation must discard capability cache")
        let transition = WhiteBalanceTransport()
        transition.maximumAfterAutoWrite = 9000
        let transitionBackend = ImageControlBackend(transport: transition)
        _ = try transitionBackend.write(.autoWhiteBalance, value: .toggle(false), shouldContinue: { true })
        precondition(transition.requests.filter { $0.0 == .whiteBalance && $0.1 == 0x83 }.count == 2,
                     "Auto switch must refresh capabilities after the paired writes")
        transition.maximum = 9500
        let refreshed = try transitionBackend.read(.whiteBalance)
        guard case .numeric(let refreshedRange) = refreshed.kind else { preconditionFailure() }
        precondition(refreshedRange.maximum == 9500, "Standalone reads must never reuse a write cache")
        print("PASS: contrast 16 → 10 USB requests; fresh limits, permissions, failed-write cleanup and Auto invalidation")
        let interrupted = WhiteBalanceTransport()
        let interruptedBackend = ImageControlBackend(transport: interrupted)
        var sessionCurrent = true
        guard case .pending(let pending) = try interruptedBackend.beginWrite(.contrast, value: .number(3000),
            shouldContinue: { sessionCurrent }) else { preconditionFailure("Expected deferred confirmation") }
        interrupted.maximum = 4000
        guard case .numeric(let duringWait) = try interruptedBackend.read(.contrast).kind else { preconditionFailure() }
        precondition(duringWait.maximum == 4000, "Standalone read during a wait must not use the command's cache")
        let readsBeforeCancel = interrupted.requests.count
        sessionCurrent = false
        rejects { _ = try pending.poll() }
        precondition(interrupted.requests.count == readsBeforeCancel, "Cancelled confirmation must not read USB")
        print("PASS: pending image write isolates its cache and cancellation performs no USB read")
        let transport = WhiteBalanceTransport()
        let backend = ImageControlBackend(transport: transport)
        rejects { _ = try backend.write(.whiteBalance, value: .number(5400), shouldContinue: { true }) }
        precondition(transport.writes.isEmpty) // Manual UI cannot bypass Auto.
        let off = try backend.write(.autoWhiteBalance, value: .toggle(false), shouldContinue: { true })
        precondition(off.value == .toggle(false))
        precondition(transport.writes.map(\.0) == [.autoWhiteBalance, .whiteBalance])
        precondition(transport.writes[0].1 == [0] && transport.writes[1].1 == [0x60, 0x08])
        let manual = try backend.write(.whiteBalance, value: .number(5400), shouldContinue: { true })
        precondition(manual.value == .number(5400))
        _ = try backend.write(.autoWhiteBalance, value: .toggle(true), shouldContinue: { true })
        precondition(transport.writes.last!.0 == .autoWhiteBalance && transport.writes.count == 4)
        _ = try backend.write(.autoWhiteBalance, value: .toggle(false), shouldContinue: { true })
        precondition(transport.writes.last!.1 == [0x18, 0x15]) // Fresh 5400, not initial 2144.

        for failed in [true, false] {
            let fake = WhiteBalanceTransport()
            fake.rejectTemperature = failed
            fake.ignoreTemperature = !failed
            let backend = ImageControlBackend(transport: fake)
            rejects { _ = try backend.write(.autoWhiteBalance, value: .toggle(false), shouldContinue: { true }) }
            precondition(fake.auto == 1)
        }
        let cancelled = WhiteBalanceTransport()
        let cancelledBackend = ImageControlBackend(transport: cancelled)
        rejects {
            _ = try cancelledBackend.write(.autoWhiteBalance, value: .toggle(false),
                                            shouldContinue: { cancelled.writes.isEmpty })
        }
        precondition(cancelled.writes.count == 1) // No second write after session invalidation.
        let invalid = WhiteBalanceTransport()
        invalid.temperature = 9000
        rejects {
            _ = try ImageControlBackend(transport: invalid)
                .write(.autoWhiteBalance, value: .toggle(false), shouldContinue: { true })
        }
        precondition(invalid.writes.isEmpty)

        let standard = WhiteBalanceTransport()
        standard.whiteBalanceRequiresTemperatureCommit = false
        standard.cameraNeedsCommit = false
        _ = try ImageControlBackend(transport: standard)
            .write(.autoWhiteBalance, value: .toggle(false), shouldContinue: { true })
        precondition(standard.writes.count == 1 && standard.temperature == 2144)
        print("PASS: paired WB commit, fresh temperature preservation, manual dependency, standard camera path, failed/ignored SET, cancellation and invalid temperature")
    }
}
