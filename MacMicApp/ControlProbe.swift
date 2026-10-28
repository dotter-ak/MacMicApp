#if DEBUG
import AVFoundation

// Read-only capability audit on CaptureEngine's session queue, with live video.
// A readable mode enum is not evidence that this device supports its setter.
enum ControlProbe {
    static func snapshot(device: AVCaptureDevice, phase: String) -> ControlSnapshot {
        let exposureModes: [(String, AVCaptureDevice.ExposureMode)] = [
            ("locked", .locked), ("autoExpose", .autoExpose),
            ("continuousAutoExposure", .continuousAutoExposure), ("custom", .custom)
        ]
        let whiteBalanceModes: [(String, AVCaptureDevice.WhiteBalanceMode)] = [
            ("locked", .locked), ("autoWhiteBalance", .autoWhiteBalance),
            ("continuousAutoWhiteBalance", .continuousAutoWhiteBalance)
        ]
        let lockStatus: String
        do {
            try device.lockForConfiguration()
            device.unlockForConfiguration()
            lockStatus = "available"
        } catch {
            lockStatus = "error: \(error.localizedDescription)"
        }
        let recommendedBias = device.activeFormat.systemRecommendedExposureBiasRange
        return ControlSnapshot(event: "controls", phase: phase,
            exposureModes: Dictionary(uniqueKeysWithValues: exposureModes.map { ($0.0, device.isExposureModeSupported($0.1)) }),
            exposureModeRawValue: device.exposureMode.rawValue,
            exposureMode: exposureModes.first { $0.1 == device.exposureMode }?.0 ?? "unknown",
            adjustingExposure: device.isAdjustingExposure,
            exposurePointOfInterestSupported: device.isExposurePointOfInterestSupported,
            exposureRectOfInterestSupported: device.isExposureRectOfInterestSupported,
            whiteBalanceModes: Dictionary(uniqueKeysWithValues: whiteBalanceModes.map { ($0.0, device.isWhiteBalanceModeSupported($0.1)) }),
            whiteBalanceModeRawValue: device.whiteBalanceMode.rawValue,
            whiteBalanceMode: whiteBalanceModes.first { $0.1 == device.whiteBalanceMode }?.0 ?? "unknown",
            adjustingWhiteBalance: device.isAdjustingWhiteBalance,
            recommendedExposureBiasMin: recommendedBias?.lowerBound,
            recommendedExposureBiasMax: recommendedBias?.upperBound,
            configurationLock: lockStatus,
            writesPerformed: false)
    }
}

struct ControlSnapshot: Codable {
    let event: String
    let phase: String
    let exposureModes: [String: Bool]
    let exposureModeRawValue: Int
    let exposureMode: String
    let adjustingExposure: Bool
    let exposurePointOfInterestSupported: Bool
    let exposureRectOfInterestSupported: Bool
    let whiteBalanceModes: [String: Bool]
    let whiteBalanceModeRawValue: Int
    let whiteBalanceMode: String
    let adjustingWhiteBalance: Bool
    let recommendedExposureBiasMin: Float?
    let recommendedExposureBiasMax: Float?
    let configurationLock: String
    let writesPerformed: Bool
}
#endif
