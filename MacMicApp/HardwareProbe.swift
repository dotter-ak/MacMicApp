#if DEBUG
import AVFoundation
import Darwin

// Opt-in developer diagnostics. No image data or device identifiers are saved.
// Configuration/restoration belongs to CaptureEngine's queue. Frame statistics
// belong exclusively to sampleQueue, including the final report.
final class HardwareProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static var isEnabled: Bool { CommandLine.arguments.contains("--hardware-probe") }
    static var measuresUIModes: Bool { isEnabled && CommandLine.arguments.contains("--probe-ui-modes") }
    private let sampleQueue: DispatchQueue
    private var requestedAt: Double
    private var lockedDevice: AVCaptureDevice?
    private var originalFormat: AVCaptureDevice.Format?
    private var originalMin = CMTime.invalid
    private var originalMax = CMTime.invalid
    private var originalPreset: AVCaptureSession.Preset?
    private var firstArrival: Double?
    private var frames = FrameTiming()
    private var dropped = 0
    private var sampleFormats = Set<String>()
    private var finished = false
    private var cpuStart = 0.0
    private var measurementStart = 0.0

    init(requestedAt: Double, sampleQueue: DispatchQueue) {
        self.requestedAt = requestedAt
        self.sampleQueue = sampleQueue
    }

    // Must be called before startRunning, on the session queue.
    func configure(session: AVCaptureSession, device: AVCaptureDevice) throws {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let expectedName = value("--probe-camera"), device.localizedName == expectedName else {
            throw ProbeError.invalid("Probe requires --probe-camera matching the selected camera.")
        }
        if Self.measuresUIModes && (args.contains("--probe-format") || args.contains("--probe-fps")) {
            throw ProbeError.invalid("UI mode measurement cannot override the mode with probe arguments.")
        }
        var requested: (AVCaptureDevice.Format, CMTime)?
        if args.contains("--probe-format") || args.contains("--probe-fps") {
            guard let index = value("--probe-format").flatMap(Int.init), device.formats.indices.contains(index),
                  let fps = value("--probe-fps").flatMap(Double.init), fps.isFinite, fps > 0,
                  let range = device.formats[index].videoSupportedFrameRateRanges.first(where: {
                      fps >= $0.minFrameRate && fps <= $0.maxFrameRate
                  }) else { throw ProbeError.invalid("Invalid probe format index or FPS.") }
            let duration = fps == range.maxFrameRate ? range.minFrameDuration
                : fps == range.minFrameRate ? range.maxFrameDuration
                : CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000_000)
            requested = (device.formats[index], duration)
        }
        Self.emit(ProbeCatalog(event: "catalog", camera: device.localizedName,
                               formats: device.formats.enumerated().map { FormatInfo(index: $0.offset, format: $0.element) },
                               active: Self.active(device), preset: session.sessionPreset.rawValue))
        originalFormat = device.activeFormat
        originalMin = device.activeVideoMinFrameDuration
        originalMax = device.activeVideoMaxFrameDuration
        originalPreset = session.sessionPreset
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // On macOS the session may renegotiate during commit/start. Keep the
        // configuration lock through startup, then release it immediately.
        if let (format, duration) = requested {
            try device.lockForConfiguration()
            lockedDevice = device
            device.activeFormat = format
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    // Fence old callbacks before reconfiguration and measure from this request.
    func prepareForModeChange() {
        sampleQueue.sync {
            finished = true
            requestedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    func started(device: AVCaptureDevice, session: AVCaptureSession) {
        if Self.measuresUIModes {
            sampleQueue.sync {
                firstArrival = nil
                frames = FrameTiming()
                dropped = 0
                sampleFormats.removeAll()
                finished = false
                cpuStart = 0
                measurementStart = 0
            }
        }
        Self.emit(ProbeStatus(event: "started", active: Self.active(device), preset: session.sessionPreset.rawValue))
        lockedDevice?.unlockForConfiguration()
        lockedDevice = nil
        Self.emit(ControlProbe.snapshot(device: device, phase: "started"))
        if CommandLine.arguments.contains("--probe-uvc") {
            Self.emit(UVCReadProbe.inspect(device: device, phase: "started"))
        }
    }

    // Called by the session queue 22 seconds after startRunning returns.
    func finish(device: AVCaptureDevice, session: AVCaptureSession) {
        let active = Self.active(device)
        let preset = session.sessionPreset.rawValue
        Self.emit(ControlProbe.snapshot(device: device, phase: "finished"))
        if CommandLine.arguments.contains("--probe-uvc") {
            Self.emit(UVCReadProbe.inspect(device: device, phase: "finished"))
        }
        sampleQueue.async { [self] in
            guard !finished else { return }
            finished = true
            let duration = measurementStart > 0 ? ProcessInfo.processInfo.systemUptime - measurementStart : 0
            var usage = rusage()
            let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
            let report = ProbeResult(event: "result", active: active, preset: preset,
                firstFrameMilliseconds: firstArrival.map { ($0 - requestedAt) * 1000 },
                measuredSeconds: duration, frames: frames.count, fpsByPTS: frames.fps,
                fpsByArrival: frames.arrivalFPS, maximumPTSGapMilliseconds: frames.maxGap * 1000,
                p95PTSGapMilliseconds: frames.p95Gap * 1000, invalidTimestamps: frames.invalidCount,
                deliveredFormats: sampleFormats.sorted(), droppedCallbacks: dropped,
                cpuPercentOneCore: duration > 0 ? (Self.cpuSeconds() - cpuStart) / duration * 100 : nil,
                processPeakRSSMiB: usageOK ? Double(usage.ru_maxrss) / 1_048_576 : nil)
            Self.emit(report)
        }
    }

    // Session has stopped. Restore the pre-probe configuration; the shared output belongs to CaptureEngine.
    func restore(session: AVCaptureSession) {
        lockedDevice?.unlockForConfiguration()
        lockedDevice = nil
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device, let originalFormat {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.activeFormat = originalFormat
                device.activeVideoMinFrameDuration = originalMin
                device.activeVideoMaxFrameDuration = originalMax
                if let originalPreset, session.canSetSessionPreset(originalPreset) {
                    session.sessionPreset = originalPreset
                }
            } catch {
                Self.emit(["event": "restore-error", "message": error.localizedDescription])
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if firstArrival == nil { firstArrival = now }
        guard now - (firstArrival ?? now) >= 2 else { return }
        if measurementStart == 0 {
            measurementStart = now
            cpuStart = Self.cpuSeconds()
        }
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let size = CMVideoFormatDescriptionGetDimensions(description)
            sampleFormats.insert("\(size.width)x\(size.height) \(Self.fourCC(CMFormatDescriptionGetMediaSubType(description)))")
        }
        frames.add(pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, arrival: now)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !finished, measurementStart > 0 { dropped += 1 }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }, encoding: .ascii) ?? String(value)
    }

    private static func active(_ device: AVCaptureDevice) -> ActiveInfo {
        ActiveInfo(format: FormatInfo(index: device.formats.firstIndex(of: device.activeFormat) ?? -1, format: device.activeFormat),
                   minFrameDuration: device.activeVideoMinFrameDuration.seconds,
                   maxFrameDuration: device.activeVideoMaxFrameDuration.seconds)
    }

    static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if var data = try? encoder.encode(value) {
            data.append(10)
            FileHandle.standardOutput.write(data)
        }
    }
}

private enum ProbeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { text } else { nil } }
}

private struct FormatInfo: Codable, Sendable {
    let index: Int
    let width: Int32
    let height: Int32
    let subtype: String
    let ranges: [RateRange]
    init(index: Int, format: AVCaptureDevice.Format) {
        self.index = index
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        width = dimensions.width
        height = dimensions.height
        subtype = HardwareProbe.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        ranges = format.videoSupportedFrameRateRanges.map { RateRange(min: $0.minFrameRate, max: $0.maxFrameRate) }
    }
}
private struct RateRange: Codable, Sendable { let min: Double; let max: Double }
private struct ActiveInfo: Codable, Sendable {
    let format: FormatInfo
    let minFrameDuration: Double
    let maxFrameDuration: Double
}
private struct ProbeCatalog: Codable {
    let event: String; let camera: String; let formats: [FormatInfo]; let active: ActiveInfo; let preset: String
}
private struct ProbeStatus: Codable { let event: String; let active: ActiveInfo; let preset: String }
private struct ProbeResult: Codable {
    let event: String; let active: ActiveInfo; let preset: String
    let firstFrameMilliseconds: Double?
    let measuredSeconds: Double; let frames: Int; let fpsByPTS: Double?; let fpsByArrival: Double?
    let maximumPTSGapMilliseconds: Double; let p95PTSGapMilliseconds: Double; let invalidTimestamps: Int
    let deliveredFormats: [String]; let droppedCallbacks: Int
    let cpuPercentOneCore: Double?; let processPeakRSSMiB: Double?
}
#endif
