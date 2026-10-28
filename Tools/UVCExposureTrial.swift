import Foundation

#if DEBUG
enum UVCExposureTrial {
    static func run(read: (UVCExposureControl, UInt8) throws -> [UInt8],
                    write: (UVCExposureControl, [UInt8]) throws -> Void, changeMode: Bool = true) -> [String: String] {
        var result: [String: String] = [:]
        var originals: [UVCExposureControl: UInt32] = [:]
        var attempted: [UVCExposureControl] = []
        func number(_ id: UVCExposureControl, _ request: UInt8) throws -> UInt32 {
            try UVCUnsignedValue.decode(read(id, request), width: id.width, allowShort: id != .mode)
        }
        func set(_ id: UVCExposureControl, _ value: UInt32) throws {
            try write(id, UVCUnsignedValue.encode(value, width: id.width))
            Thread.sleep(forTimeInterval: 0.3)
            guard try number(id, 0x81) == value else { throw CameraControlError.invalid("Readback differs for \(id).") }
            Thread.sleep(forTimeInterval: 0.2)
            guard try number(id, 0x81) == value else { throw CameraControlError.invalid("Readback changed for \(id).") }
        }
        do {
            for id in UVCExposureControl.allCases {
                let info = try read(id, 0x86)
                guard info.count == 1, info[0] & 3 == 3, info[0] & 0x10 == 0 else { throw CameraControlError.invalid("Control cannot be tested synchronously.") }
                originals[id] = try number(id, 0x81)
                result["\(id).original"] = String(originals[id]!)
            }
            guard [1,2].contains(originals[.mode]!) else { throw CameraControlError.invalid("Trial only supports initial Manual or Auto.") }
            var targets: [UVCExposureControl: UInt32] = [:]
            for id in [UVCExposureControl.exposure, .gain] {
                let lower = try number(id, 0x82), upper = try number(id, 0x83), step = try number(id, 0x84), current = originals[id]!
                guard lower < upper, step > 0, step <= upper-lower, current >= lower, current <= upper, (current-lower) % step == 0 else {
                    throw CameraControlError.invalid("Invalid exposure/gain range.")
                }
                targets[id] = id == .exposure && current-lower >= step ? current-step : (upper-current >= step ? current+step : current-step)
            }
            if changeMode { attempted.append(.mode); try set(.mode, 1); result["manual"] = "confirmed" }
            for id in [UVCExposureControl.exposure, .gain] {
                attempted.append(id)
                do {
                    try set(id, targets[id]!)
                    result["\(id).target"] = String(targets[id]!)
                    result["\(id).write"] = "confirmed"
                } catch {
                    result["\(id).write"] = "FAILED: \(error.localizedDescription)"
                    result["trialError"] = error.localizedDescription
                }
            }
        } catch { result["trialError"] = error.localizedDescription }
        // Restore only attempted controls, in reverse order; mode last.
        for id in attempted.reversed() {
            do { try set(id, originals[id]!); result["\(id).restore"] = "confirmed" }
            catch { result["\(id).restore"] = "FAILED: \(error.localizedDescription)" }
        }
        return result
    }
}
#endif
