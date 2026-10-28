import Foundation

private final class FakeBrightness: BrightnessTransport {
    var current = 60
    var minimum = 0
    var maximum = 100
    var step = 2
    var info: [UInt8] = [3]
    var shortCurrent = false
    var ignoreWrites = false
    var disconnectOnWrite = false
    var connected = true
    var changeBeforeWrite = false
    var reads = 0
    var writes: [Int] = []

    func get(_ request: UInt8) throws -> [UInt8] {
        guard connected else { throw BrightnessError.invalid("disconnected") }
        if request == 0x86 { return info }
        let value: Int
        switch request {
        case 0x81:
            reads += 1
            if changeBeforeWrite && reads == 2 { current += step }
            if shortCurrent { return [60] }
            value = current
        case 0x82: value = minimum
        case 0x83: value = maximum
        case 0x84: value = step
        default: throw BrightnessError.invalid("unexpected request")
        }
        return try BrightnessCodec.encode(value)
    }
    func set(_ bytes: [UInt8]) throws {
        guard connected else { throw BrightnessError.invalid("disconnected") }
        let value = try BrightnessCodec.decode(bytes)
        writes.append(value)
        if !ignoreWrites { current = value }
        if disconnectOnWrite { connected = false; throw BrightnessError.invalid("disconnected after SET") }
    }
}

@main
struct BrightnessTrialChecks {
    static func rejects(_ block: () throws -> Void) {
        do { try block(); preconditionFailure("Expected failure") } catch {}
    }
    static func main() throws {
        for value in [-32768, -1, 0, 60, 70, 32767] {
            let decoded = try BrightnessCodec.decode(BrightnessCodec.encode(value))
            precondition(decoded == value)
        }
        let negativeBytes = try BrightnessCodec.encode(-1)
        let positiveBytes = try BrightnessCodec.encode(70)
        precondition(negativeBytes == [255, 255])
        precondition(positiveBytes == [0x46, 0])
        rejects { _ = try BrightnessCodec.decode([60]) }
        rejects { _ = try BrightnessCodec.encode(32768) }
        let manual = FakeBrightness()
        let setting = try BrightnessSetting.read(from: manual)
        precondition(setting.value == 60 && setting.initial == 60 && manual.writes.isEmpty)
        rejects { _ = try setting.applying(61, to: manual) }
        rejects { _ = try setting.applying(102, to: manual) }
        precondition(manual.writes.isEmpty)
        let changed = try setting.applying(80, to: manual)
        precondition(changed.value == 80 && changed.initial == 60)
        let restored = try changed.applying(changed.initial, to: manual)
        precondition(restored.value == 60 && manual.writes == [80, 60])
        manual.ignoreWrites = true
        rejects { _ = try setting.applying(80, to: manual) }
        let normal = FakeBrightness(), trial = BrightnessTrial(transport: FakeBrightness())
        let success = BrightnessTrial(transport: normal)
        try success.begin()
        precondition(success.original == 60 && success.target == 70 && normal.current == 70 && success.needsRestore)
        try success.restore()
        try success.restore()
        precondition(normal.writes == [70,60] && normal.current == 60 && !success.needsRestore)
        rejects { try success.begin() }
        try trial.restore() // Cancellation before the first write is a no-op.
        for configure in [
            { (f: FakeBrightness) in f.info = [1] },
            { (f: FakeBrightness) in f.info = [7] },
            { (f: FakeBrightness) in f.info = [11] },
            { (f: FakeBrightness) in f.info = [19] },
            { (f: FakeBrightness) in f.shortCurrent = true },
            { (f: FakeBrightness) in f.step = 0 },
            { (f: FakeBrightness) in f.current = 61 },
            { (f: FakeBrightness) in f.changeBeforeWrite = true }
        ] {
            let f = FakeBrightness(); configure(f)
            let t = BrightnessTrial(transport: f)
            rejects { try t.begin() }
            try t.restore()
            precondition(f.writes.isEmpty)
        }
        let top = FakeBrightness(); top.current = 100
        let down = BrightnessTrial(transport: top); try down.begin()
        precondition(down.target == 90); try down.restore()
        let signed = FakeBrightness(); signed.minimum = -100; signed.maximum = 100; signed.current = -60
        let negative = BrightnessTrial(transport: signed); try negative.begin(); try negative.restore()
        precondition(signed.writes == [-50,-60])
        let cancelled = FakeBrightness(); let cancelTrial = BrightnessTrial(transport: cancelled)
        var checks = 0
        rejects { try cancelTrial.begin { checks += 1; return checks < 7 } }
        precondition(cancelled.writes.isEmpty)
        let ignored = FakeBrightness(); ignored.ignoreWrites = true
        let ignoredTrial = BrightnessTrial(transport: ignored)
        rejects { try ignoredTrial.begin() }; try ignoredTrial.restore()
        precondition(ignored.writes == [70,60] && !ignoredTrial.needsRestore)
        let unplugged = FakeBrightness(); unplugged.disconnectOnWrite = true
        let lost = BrightnessTrial(transport: unplugged)
        rejects { try lost.begin() }; rejects { try lost.restore() }
        precondition(lost.needsRestore && unplugged.writes == [70])
        unplugged.connected = true; unplugged.disconnectOnWrite = false
        rejects { try lost.restore() } // No automatic retry against a reconnected device.
        precondition(unplugged.writes == [70])
        print("PASS: signed bytes, bounds/steps, readback, restore, cancellation, concurrent change, short replies and disconnect after SET")
    }
}
