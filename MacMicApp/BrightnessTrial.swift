import Foundation

#if DEBUG
final class BrightnessTrial {
    let transport: any BrightnessTransport
    private(set) var original: Int?
    private(set) var target: Int?
    private(set) var minimum: Int?
    private(set) var maximum: Int?
    private(set) var step: Int?
    private(set) var needsRestore = false
    private(set) var restoreAttempted = false
    private var started = false

    init(transport: any BrightnessTransport) { self.transport = transport }

    func begin(shouldContinue: () -> Bool = { true }) throws {
        guard !started else { throw BrightnessError.invalid("Brightness trial has already started.") }
        started = true
        func check() throws {
            guard shouldContinue() else { throw BrightnessError.invalid("Brightness trial cancelled before write.") }
        }
        func read(_ request: UInt8) throws -> Int {
            try check()
            return try BrightnessCodec.decode(transport.get(request))
        }
        try check()
        let info = try transport.get(0x86)
        // Require synchronous read/write, no auto-disable or auto-updating value.
        guard info.count == 1, info[0] & 0x03 == 0x03, info[0] & 0x1c == 0 else {
            throw BrightnessError.invalid("Brightness is not available for a synchronous read/write trial.")
        }
        let lower = try read(0x82), upper = try read(0x83), increment = try read(0x84)
        let baseline = try read(0x81)
        guard lower < upper, increment > 0, baseline >= lower, baseline <= upper,
              (baseline - lower) % increment == 0 else {
            throw BrightnessError.invalid("Invalid brightness range, step or initial value.")
        }
        let upSteps = min(5, (upper - baseline) / increment)
        let downSteps = min(5, (baseline - lower) / increment)
        guard max(upSteps, downSteps) > 0 else { throw BrightnessError.invalid("No distinct valid brightness value.") }
        let candidate = upSteps >= downSteps ? baseline + upSteps * increment : baseline - downSteps * increment
        original = baseline; target = candidate; minimum = lower; maximum = upper; step = increment
        // Do not overwrite another application's intervening change.
        guard try read(0x81) == baseline else { throw BrightnessError.invalid("Brightness changed before the trial write.") }
        try check()
        needsRestore = true // A failed SET may still have reached the device.
        try transport.set(BrightnessCodec.encode(candidate))
        guard try read(0x81) == candidate else { throw BrightnessError.invalid("Brightness write was not confirmed by readback.") }
    }

    func restore() throws {
        guard needsRestore else { return }
        guard !restoreAttempted, let original else {
            throw BrightnessError.invalid("Initial brightness restoration remains unconfirmed.")
        }
        restoreAttempted = true
        // Restoration is allowed after cancellation, on the SAME retained USB
        // connection. Never rediscover/reopen a device to perform this write.
        try transport.set(BrightnessCodec.encode(original))
        guard try BrightnessCodec.decode(transport.get(0x81)) == original else {
            throw BrightnessError.invalid("Initial brightness restoration was not confirmed.")
        }
        needsRestore = false
    }
}
#endif
