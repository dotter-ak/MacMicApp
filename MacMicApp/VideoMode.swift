import Foundation

struct VideoResolution: Hashable, Sendable, Codable {
    let width: Int32
    let height: Int32
    var label: String { "\(width) × \(height)" }
}

struct VideoRateRange: Equatable, Sendable, Codable {
    let min: Double
    let max: Double
    func contains(_ fps: Double) -> Bool { fps.isFinite && fps > 0 && fps >= min && fps <= max }
}

struct VideoFormat: Equatable, Identifiable, Sendable {
    let index: Int
    let resolution: VideoResolution
    let subtype: UInt32
    let rates: [VideoRateRange]
    var id: Int { index }
    var pixelFormatLabel: String {
        switch subtype {
        case 0x34323076: "YUV 4:2:0 (420v)"
        case 0x32767579: "YUV 4:2:2 (2vuy)"
        default:
            String(bytes: [24, 16, 8, 0].map { UInt8((subtype >> $0) & 255) }, encoding: .ascii)
                ?? String(format: "0x%08x", subtype)
        }
    }
    var shortPixelFormatLabel: String {
        switch subtype {
        case 0x34323076: "4:2:0"
        case 0x32767579: "4:2:2"
        default: pixelFormatLabel
        }
    }
}

struct VideoMode: Equatable, Sendable {
    let formatIndex: Int
    let fps: Double
    static func fpsLabel(_ fps: Double) -> String {
        // Hide clock rounding (30.000030), but retain fractional rates (29.97).
        let display = abs(fps - fps.rounded()) < 0.0001 ? fps.rounded() : fps
        return display.formatted(.number.precision(.fractionLength(0...6)).locale(Locale(identifier: "en_US")))
    }
}

struct CaptureSnapshot: Equatable, Sendable {
    let formats: [VideoFormat]
    let active: VideoMode
    var catalog: VideoModeCatalog { VideoModeCatalog(formats: formats) }
    var activeFormat: VideoFormat? { formats.first { $0.index == active.formatIndex } }
    var resolution: VideoResolution? { activeFormat?.resolution }
}

struct VideoModeCatalog: Sendable {
    let formats: [VideoFormat]
    var resolutions: [VideoResolution] {
        Set(formats.map(\.resolution)).sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.height > $1.height
        }
    }

    var selectableFormats: [VideoFormat] {
        formats.sorted {
            if $0.resolution.width != $1.resolution.width { return $0.resolution.width > $1.resolution.width }
            if $0.resolution.height != $1.resolution.height { return $0.resolution.height > $1.resolution.height }
            return $0.index < $1.index
        }
    }

    func label(for format: VideoFormat) -> String {
        "\(format.resolution.label) · \(pixelFormatLabel(for: format))"
    }

    func pixelFormatLabel(for format: VideoFormat) -> String {
        let duplicate = formats.filter { $0.resolution == format.resolution && $0.subtype == format.subtype }.count > 1
        return format.pixelFormatLabel + (duplicate ? " · #\(format.index + 1)" : "")
    }

    func preferred(resolution: VideoResolution, preserving mode: VideoMode) -> VideoMode? {
        if let current = formats.first(where: { $0.index == mode.formatIndex }) {
            if current.resolution == resolution, supports(mode) { return mode }
            let matches = formats.filter { $0.resolution == resolution && $0.subtype == current.subtype }
                .compactMap { preferred(formatIndex: $0.index, near: mode.fps) }
                .sorted {
                    let a = abs($0.fps - mode.fps), b = abs($1.fps - mode.fps)
                    return a != b ? a < b : $0.formatIndex < $1.formatIndex
                }
            if let match = matches.first { return match }
        }
        return preferred(resolution: resolution, near: mode.fps)
    }

    func preferred(formatIndex: Int, near fps: Double) -> VideoMode? {
        guard let format = formats.first(where: { $0.index == formatIndex }) else { return nil }
        // Keep arbitrary supported FPS exactly; otherwise choose the closest
        // offered rate within this format, never a different pixel format.
        if let exact = resolve(resolution: format.resolution, fps: fps, formatIndex: formatIndex) { return exact }
        guard let rate = rates(for: format.resolution, formatIndex: formatIndex).min(by: { abs($0 - fps) < abs($1 - fps) }) else { return nil }
        return resolve(resolution: format.resolution, fps: rate, formatIndex: formatIndex)
    }

    func canonicalRate(formatIndex: Int, measuredFPS: Double) -> Double {
        // Reciprocating CMTime can differ from AVFrameRateRange by a few ulps.
        let endpoints = formats.first { $0.index == formatIndex }?.rates.flatMap { [$0.min, $0.max] } ?? []
        return endpoints.first { abs($0 - measuredFPS) < 0.000001 } ?? measuredFPS
    }

    func supports(_ mode: VideoMode) -> Bool {
        formats.contains { $0.index == mode.formatIndex && $0.rates.contains { $0.contains(mode.fps) } }
    }

    func rates(for resolution: VideoResolution, formatIndex: Int? = nil) -> [Double] {
        var values = Set<Double>()
        for format in formats where format.resolution == resolution && (formatIndex == nil || format.index == formatIndex) {
            for range in format.rates where range.min > 0 && range.max.isFinite && range.max >= range.min {
                values.insert(range.min)
                values.insert(range.max)
                // Endpoints retain exact device clocks. Interior choices cover
                // common rates; resolve also accepts any valid custom FPS.
                for fps in [5.0, 10, 15, 24, 25, 29.97, 30, 50, 59.94, 60, 120] where range.contains(fps) {
                    if abs(fps - range.min) > 0.001 && abs(fps - range.max) > 0.001 { values.insert(fps) }
                }
            }
        }
        return values.sorted(by: >)
    }

    func resolve(resolution: VideoResolution, fps: Double, formatIndex: Int? = nil) -> VideoMode? {
        guard fps.isFinite, fps > 0 else { return nil }
        func acceptedRate(_ format: VideoFormat) -> Double? {
            if format.rates.contains(where: { $0.contains(fps) }) { return fps }
            // Accept a displayed whole-number clock (30) as its exact device
            // endpoint (30.000030), without filling real unsupported gaps.
            return format.rates.flatMap { [$0.min, $0.max] }.first { abs($0 - fps) < 0.0001 }
        }
        let candidates = formats.filter { $0.resolution == resolution && (formatIndex == nil || $0.index == formatIndex) && acceptedRate($0) != nil }
        // Preserve the previously verified default only when no format was explicitly chosen.
        let chosen = candidates.sorted {
            let a = $0.subtype == 0x34323076, b = $1.subtype == 0x34323076 // 420v
            return a != b ? a : $0.index < $1.index
        }.first
        return chosen.flatMap { format in acceptedRate(format).map { VideoMode(formatIndex: format.index, fps: $0) } }
    }

    func preferred(resolution: VideoResolution? = nil, near fps: Double = 30) -> VideoMode? {
        let target = resolution ?? resolutions.first { $0.width == 1920 && $0.height == 1080 }
            ?? resolutions.filter { $0.width <= 1920 && $0.height <= 1080 }.first ?? resolutions.last
        guard let target, let rate = rates(for: target).min(by: { abs($0 - fps) < abs($1 - fps) }) else { return nil }
        return resolve(resolution: target, fps: rate)
    }
}
