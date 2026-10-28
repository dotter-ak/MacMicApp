import Foundation
private final class Fake {
    var values: [UVCExposureControl: UInt32] = [.mode: 2, .exposure: 29999, .gain: 40]
    var writes: [UVCExposureControl] = []
    var failGain = false
    func read(_ id: UVCExposureControl, _ q: UInt8) throws -> [UInt8] {
        if q == 0x86 { return [3] }
        let value: UInt32
        switch q {
        case 0x81: value = values[id]!
        case 0x82: value = id == .exposure ? 156 : 30
        case 0x83: value = id == .exposure ? 40000 : 70
        default: value = 1
        }
        var bytes = try UVCUnsignedValue.encode(value, width: id.width)
        while bytes.count > 1 && bytes.last == 0 { bytes.removeLast() }
        return bytes
    }
    func write(_ id: UVCExposureControl, _ b: [UInt8]) throws {
        writes.append(id)
        values[id] = try UVCUnsignedValue.decode(b, width: id.width, allowShort: false)
        if failGain && writes.count == 3 { throw CameraControlError.invalid("Disconnected after SET") }
    }
}
private final class BackendTransport: ExposureTransport {
    var values: [UVCExposureControl: UInt32] = [.mode: 2, .exposure: 29999, .gain: 40]
    var requests: [(UVCExposureControl, UInt8)] = []
    var gainMaximum: UInt32 = 70
    var modeMaskAfterWrite: UInt32?
    var modeMask: UInt32 = 3
    var unsupported: Set<UVCExposureControl> = []
    func supportsExposureControl(_ id: UVCExposureControl) -> Bool { !unsupported.contains(id) }
    var writes: [UVCExposureControl] = []
    var ignoreWrites = false
    var delayReads = 0
    var pending: (UVCExposureControl, UInt32)?
    func readExposure(_ id: UVCExposureControl, request: UInt8) throws -> [UInt8] {
        requests.append((id, request))
        if request == 0x86 { return [3] }
        let value: UInt32
        if request == 0x81 {
            if let (control, number) = pending, id == control {
                if delayReads == 0 { values[id] = number; pending = nil } else { delayReads -= 1 }
            }
            value = values[id]!
        } else if id == .mode { value = modeMask }
        else if request == 0x82 { value = id == .exposure ? 156 : 30 }
        else if request == 0x83 { value = id == .exposure ? 40000 : gainMaximum }
        else { value = 1 }
        var bytes = try UVCUnsignedValue.encode(value, width: id.width)
        while bytes.count > 1 && bytes.last == 0 { bytes.removeLast() }
        return bytes
    }
    func writeExposure(_ id: UVCExposureControl, bytes: [UInt8]) throws {
        writes.append(id)
        if id == .mode, let modeMaskAfterWrite { modeMask = modeMaskAfterWrite }
        if !ignoreWrites { pending = (id, try UVCUnsignedValue.decode(bytes, width: id.width, allowShort: false)) }
    }
}

private final class YizhanTransport: ExposureTransport {
    var usesYizhanExposureProtocol: Bool { true }
    var mode: UInt32 = 2
    var exposure: UInt32 = 24992
    var pendingManual = false
    var failExposure = false
    var ignoreExposure = false
    var unstable = false
    var reads = 0
    var requests: [(UVCExposureControl, UInt8)] = []
    var writes: [(UVCExposureControl, UInt32)] = []
    func readExposure(_ id: UVCExposureControl, request: UInt8) throws -> [UInt8] {
        requests.append((id, request))
        if request == 0x86 { return [3] }
        let value: UInt32
        switch request {
        case 0x81:
            if id == .mode { value = mode }
            else if id == .exposure {
                reads += 1
                value = exposure + (unstable ? UInt32(reads % 2) : 0)
            } else { value = 40 }
        case 0x82: value = id == .exposure ? 156 : 30
        case 0x83: value = id == .exposure ? 40000 : 70
        default: value = id == .mode ? 0 : 1
        }
        var bytes = try UVCUnsignedValue.encode(value, width: id.width)
        while bytes.count > 1 && bytes.last == 0 { bytes.removeLast() }
        return bytes
    }
    func writeExposure(_ id: UVCExposureControl, bytes: [UInt8]) throws {
        let value = try UVCUnsignedValue.decode(bytes, width: id.width, allowShort: false)
        writes.append((id, value))
        if id == .mode {
            if value == 4 { pendingManual = true }
            else { mode = value; pendingManual = false }
        } else if id == .exposure {
            if failExposure { throw CameraControlError.invalid("Exposure SET failed") }
            if ignoreExposure { return }
            exposure = [156:149, 157:149, 625:623, 20000:19999][value] ?? value
            if pendingManual { mode = 4; pendingManual = false }
        }
    }
}
@main struct ExposureChecks {
    static func rejects(_ f: () throws -> Void) { do { try f(); preconditionFailure() } catch {} }
    static func main() throws {
        let unsupported = BackendTransport()
        unsupported.unsupported = [.mode, .exposure, .gain]
        let unavailableBackend = ExposureControlBackend(transport: unsupported)
        for id in [CameraControlID.autoExposure, .exposure, .gain] {
            let control = try unavailableBackend.read(id)
            precondition(control == .unavailable(id))
            rejects { _ = try unavailableBackend.write(id, value: .number(100)) }
        }
        let noTelemetry = try unavailableBackend.readAutomaticExposure()
        precondition(noTelemetry == nil && unsupported.requests.isEmpty && unsupported.writes.isEmpty)
        let efficient = YizhanTransport()
        let efficientBackend = ExposureControlBackend(transport: efficient)
        _ = try efficientBackend.write(.autoExposure, value: .option(.exposure(.shutterPriority)))
        precondition(efficient.requests.count == 20 && efficient.writes.count == 2,
                     "Auto Off: one fresh mode read per stage; paired writes unchanged")
        efficient.requests.removeAll(); efficient.writes.removeAll()
        _ = try efficientBackend.write(.exposure, value: .number(5000))
        precondition(efficient.requests.count == 20 && efficient.writes.count == 2)
        precondition(efficient.requests.filter { $0.0 == .mode && $0.1 == 0x81 }.count == 3,
                     "Mode remains freshly checked before writing and at each confirmation")
        print("PASS: unsupported exposure controls perform no USB requests; Yizhan writes 28 → 22 requests")
        let telemetry = BackendTransport()
        let telemetryBackend = ExposureControlBackend(transport: telemetry)
        let reading = try telemetryBackend.readAutomaticExposure()
        precondition(reading?.unit == .seconds && abs(reading!.value - 2.9999) < 1e-8)
        precondition(telemetry.requests.count == 2 && telemetry.requests.allSatisfy { $0.1 == 0x81 })
        precondition(telemetry.writes.isEmpty)
        telemetry.values[.mode] = 1
        let manualReading = try telemetryBackend.readAutomaticExposure()
        precondition(manualReading == nil)

        let live = YizhanTransport()
        let liveBackend = ExposureControlBackend(transport: live)
        _ = try liveBackend.read(.exposure) // The UI's old snapshot must not be used.
        live.exposure = 16666
        let liveReading = try liveBackend.readAutomaticExposure()
        precondition(liveReading == AutomaticExposureReading(value: 16666, unit: .device))
        _ = try liveBackend.write(.autoExposure, value: .option(.exposure(.shutterPriority)))
        precondition(live.mode == 4 && live.exposure == 16666)
        let frozenReading = try liveBackend.readAutomaticExposure()
        precondition(frozenReading == nil)
        let rounded = YizhanTransport()
        rounded.exposure = 20000 // Firmware changes a repeated SET to 19999.
        let roundedBackend = ExposureControlBackend(transport: rounded)
        let roundedManual = try roundedBackend.write(.autoExposure, value: .option(.exposure(.shutterPriority)))
        let synced = try roundedBackend.read(.exposure)
        precondition(roundedManual.value == .option(.exposure(.shutterPriority)) && synced.value == .number(19999),
                     "Auto Off must accept stable camera rounding and synchronize the manual value")
        print("PASS: lightweight Auto reads, raw Yizhan units, fresh Auto-off value and synchronization after camera rounding")
        let short = try UVCUnsignedValue.decode([0x2f,0x75,0], width: 4, allowShort: true)
        precondition(short == 29999)
        rejects { _ = try UVCUnsignedValue.decode([], width: 4, allowShort: true) }
        rejects { _ = try UVCUnsignedValue.decode([1,2,3], width: 2, allowShort: true) }
        rejects { _ = try UVCUnsignedValue.decode([40], width: 2, allowShort: false) }
        rejects { _ = try UVCUnsignedValue.encode(256, width: 1) }
        for failure in [false,true] {
            let fake = Fake(); fake.failGain = failure
            let report = UVCExposureTrial.run(read: fake.read, write: fake.write)
            precondition(fake.values == [.mode: 2, .exposure: 29999, .gain: 40])
            precondition(fake.writes == [.mode,.exposure,.gain,.gain,.exposure,.mode])
            precondition(report["mode.restore"] == "confirmed" && report["exposure.restore"] == "confirmed")
            precondition((report["trialError"] != nil) == failure)
        }
        let measured = BackendTransport()
        let measuredBackend = ExposureControlBackend(transport: measured)
        _ = try measuredBackend.write(.gain, value: .number(41), shouldContinue: { true })
        precondition(measured.requests.count == 9 && measured.writes.count == 1,
                     "Gain: 9 GET + 1 SET instead of 15 GET + 1 SET")
        measured.gainMaximum = 45
        rejects { _ = try measuredBackend.write(.gain, value: .number(46), shouldContinue: { true }) }
        precondition(measured.writes.count == 1)
        measured.modeMaskAfterWrite = 1
        let changedMode = try measuredBackend.write(.autoExposure, value: .option(.exposure(.manual)), shouldContinue: { true })
        precondition(changedMode.kind == .options([.exposure(.manual)]), "Read capabilities again after changing mode")
        precondition(measured.requests.filter { $0.0 == .mode && $0.1 == 0x84 }.count == 2)
        measured.gainMaximum = 50
        let freshGain = try measuredBackend.read(.gain)
        guard case .numeric(let freshRange) = freshGain.kind else { preconditionFailure() }
        precondition(freshRange.maximum == 50)
        print("PASS: gain 16 → 10 USB requests; new command, standalone read and mode switch refresh capabilities")
        let interrupted = BackendTransport()
        let interruptedBackend = ExposureControlBackend(transport: interrupted)
        var sessionCurrent = true
        guard case .pending(let pending) = try interruptedBackend.beginWrite(.gain, value: .number(41),
            shouldContinue: { sessionCurrent }) else { preconditionFailure("Expected deferred confirmation") }
        let readsBeforeCancel = interrupted.requests.count
        sessionCurrent = false
        rejects { _ = try pending.poll() }
        precondition(interrupted.requests.count == readsBeforeCancel, "Cancelled confirmation must not read USB")
        interrupted.gainMaximum = 55
        guard case .numeric(let afterCancel) = try interruptedBackend.read(.gain).kind else { preconditionFailure() }
        precondition(afterCancel.maximum == 55, "Cancellation must not leave a capability cache on the backend")
        print("PASS: cancelled exposure confirmation performs no USB read and releases its capability cache")
        let transport = BackendTransport()
        let backend = ExposureControlBackend(transport: transport)
        let mode = try backend.read(.autoExposure)
        precondition(mode.value == .option(.exposure(.auto)) && mode.access == .writable)
        let exposure = try backend.read(.exposure)
        precondition(exposure.unit == .seconds && abs(exposure.value.number! - 2.9999) < 1e-8)
        rejects { _ = try backend.write(.exposure, value: .number(0.02), shouldContinue: { true }) }
        precondition(transport.writes.isEmpty) // Auto disallows manual exposure, even with stale UI.
        let manual = try backend.write(.autoExposure, value: .option(.exposure(.manual)), shouldContinue: { true })
        precondition(manual.value == .option(.exposure(.manual)))
        let applied = try backend.write(.exposure, value: .number(0.02), shouldContinue: { true })
        precondition(applied.value == .number(0.02) && transport.values[.exposure] == 200)
        rejects { _ = try backend.write(.exposure, value: .number(0.02001), shouldContinue: { true }) }
        rejects { _ = try backend.write(.gain, value: .number(71), shouldContinue: { true }) }
        let count = transport.writes.count
        rejects { _ = try backend.write(.gain, value: .number(41), shouldContinue: { false }) }
        precondition(transport.writes.count == count)
        transport.delayReads = 2
        let gain = try backend.write(.gain, value: .number(41), shouldContinue: { true })
        precondition(gain.value == .number(41) && gain.initial == .number(40))
        transport.ignoreWrites = true
        rejects { _ = try backend.write(.gain, value: .number(42), shouldContinue: { true }) }
        transport.modeMask = 0
        let invalid = try backend.read(.autoExposure)
        precondition(invalid.access != .writable)
        rejects { _ = try backend.write(.autoExposure, value: .option(.exposure(.auto)), shouldContinue: { true }) }
        rejects { _ = try backend.write(.exposure, value: .number(0.03), shouldContinue: { true }) }
        let yizhan = YizhanTransport()
        let compatible = ExposureControlBackend(transport: yizhan)
        let yizhanMode = try compatible.read(.autoExposure)
        precondition(yizhanMode.kind == .options([.exposure(.auto), .exposure(.shutterPriority)]))
        precondition(yizhanMode.automaticTarget(enabled: false) == .option(.exposure(.shutterPriority)))
        let native = try compatible.read(.exposure)
        precondition(native.unit == .device && native.value == .number(24992) && native.reportedValue == .number(24992))
        rejects { _ = try compatible.write(.exposure, value: .number(625), shouldContinue: { true }) }
        precondition(yizhan.writes.isEmpty)
        let manualMode = try compatible.write(.autoExposure, value: .option(.exposure(.shutterPriority)), shouldContinue: { true })
        precondition(manualMode.value == .option(.exposure(.shutterPriority)) && yizhan.exposure == 24992)
        precondition(yizhan.writes.map(\.0) == [.mode, .exposure])
        for (request, expected) in [(20000,19999), (625,623), (156,149), (157,149)] {
            let actual = try compatible.write(.exposure, value: .number(Double(request)), shouldContinue: { true })
            precondition(actual.reportedValue == .number(Double(expected)))
            precondition(actual.value == .number(Double(max(156, expected))))
            precondition(actual.kind.accepts(actual.value)) // Slider stays in advertised input range.
            precondition(yizhan.writes.suffix(2).map(\.0) == [.mode, .exposure])
        }
        rejects { _ = try compatible.write(.exposure, value: .number(149), shouldContinue: { true }) }
        rejects { _ = try compatible.write(.exposure, value: .number(40001), shouldContinue: { true }) }
        yizhan.ignoreExposure = true
        let unchanged = try compatible.write(.exposure, value: .number(5000), shouldContinue: { true })
        precondition(unchanged.reportedValue == .number(149) && unchanged.value != .number(5000))
        rejects { _ = try compatible.write(.exposure, value: native.initial, shouldContinue: { true }) }
        yizhan.ignoreExposure = false
        _ = try compatible.write(.exposure, value: native.initial, shouldContinue: { true })
        precondition(yizhan.exposure == 24992)
        _ = try compatible.write(.autoExposure, value: .option(.exposure(.auto)), shouldContinue: { true })
        precondition(yizhan.mode == 2 && yizhan.writes.last!.0 == .mode)
        yizhan.failExposure = true
        rejects { _ = try compatible.write(.autoExposure, value: .option(.exposure(.shutterPriority)), shouldContinue: { true }) }
        precondition(yizhan.mode == 2)
        yizhan.failExposure = false
        _ = try compatible.write(.autoExposure, value: .option(.exposure(.shutterPriority)), shouldContinue: { true })
        yizhan.unstable = true
        rejects { _ = try compatible.write(.exposure, value: .number(10000), shouldContinue: { true }) }
        let cancelled = YizhanTransport()
        rejects {
            _ = try ExposureControlBackend(transport: cancelled)
                .write(.autoExposure, value: .option(.exposure(.shutterPriority)), shouldContinue: { cancelled.writes.isEmpty })
        }
        precondition(cancelled.writes.count == 1 && cancelled.mode == 2)
        print("PASS: Yizhan 02/04, paired writes, stable raw readback, input bounds, below-MIN reporting, restore verification, failures and cancellation")
        print("PASS: exposure backend units, fresh Auto dependency, zero capability mask, delayed readback, readback timeout, bounds and cancellation")
        print("PASS: bounded unsigned short replies, exact output encoding, exposure/gain cycle and reverse restoration after failed SET")
    }
}
