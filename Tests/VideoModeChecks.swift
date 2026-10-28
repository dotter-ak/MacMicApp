import Foundation

@main
struct VideoModeChecks {
    static func main() {
        let hd = VideoResolution(width: 1920, height: 1080)
        let uhd = VideoResolution(width: 3840, height: 2160)
        let clock = 30.00003000003
        let formats = [
            VideoFormat(index: 2, resolution: hd, subtype: 123, rates: [VideoRateRange(min: clock, max: clock)]),
            VideoFormat(index: 8, resolution: hd, subtype: 0x34323076, rates: [VideoRateRange(min: clock, max: clock), VideoRateRange(min: 10, max: 10)]),
            VideoFormat(index: 9, resolution: uhd, subtype: 0x34323076, rates: [VideoRateRange(min: 5, max: 29.97)])
        ]
        let catalog = VideoModeCatalog(formats: formats)
        precondition(catalog.resolutions == [uhd, hd])
        precondition(catalog.canonicalRate(formatIndex: 8, measuredFPS: 30.000030000000002) == clock)
        precondition(catalog.supports(VideoMode(formatIndex: 8, fps: catalog.canonicalRate(formatIndex: 8, measuredFPS: 30.000030000000002))))
        precondition(catalog.canonicalRate(formatIndex: 9, measuredFPS: 12.345) == 12.345)
        precondition(catalog.preferred() == VideoMode(formatIndex: 8, fps: clock))
        precondition(catalog.rates(for: hd) == [clock, 10])
        precondition(catalog.resolve(resolution: hd, fps: 30)?.fps == clock)
        precondition(catalog.resolve(resolution: hd, fps: 15) == nil) // No invented rate inside a gap.
        precondition(catalog.resolve(resolution: uhd, fps: 29.5)?.fps == 29.5)
        precondition(catalog.preferred(resolution: uhd)?.fps == 29.97)
        for invalid in [Double.nan, .infinity, -1, 0, 60] {
            precondition(catalog.resolve(resolution: uhd, fps: invalid) == nil)
        }
        precondition(!catalog.supports(VideoMode(formatIndex: 99, fps: 10)))
        precondition(VideoMode.fpsLabel(clock) == "30" && VideoMode.fpsLabel(29.97) == "29.97")
        precondition(VideoModeCatalog(formats: []).preferred() == nil)
        let alternatives = VideoModeCatalog(formats: [
            VideoFormat(index: 0, resolution: hd, subtype: 0x34323076, rates: [VideoRateRange(min: 10, max: 30)]),
            VideoFormat(index: 1, resolution: hd, subtype: 0x32767579, rates: [VideoRateRange(min: 10, max: 10), VideoRateRange(min: 30, max: 30)])
        ])
        precondition(alternatives.selectableFormats.map(\.index) == [0, 1])
        precondition(alternatives.label(for: alternatives.formats[0]) != alternatives.label(for: alternatives.formats[1]))
        precondition(alternatives.resolve(resolution: hd, fps: 15, formatIndex: 1) == nil)
        precondition(alternatives.resolve(resolution: hd, fps: 30, formatIndex: 1)?.formatIndex == 1)
        precondition(alternatives.rates(for: hd, formatIndex: 1) == [30, 10])
        precondition(alternatives.preferred(formatIndex: 1, near: 30) == VideoMode(formatIndex: 1, fps: 30))
        precondition(alternatives.preferred(formatIndex: 1, near: 14) == VideoMode(formatIndex: 1, fps: 10))
        precondition(alternatives.preferred(formatIndex: 0, near: 12.345)?.fps == 12.345)
        precondition(alternatives.preferred(formatIndex: 99, near: 30) == nil)
        precondition(alternatives.resolve(resolution: uhd, fps: 30, formatIndex: 1) == nil)
        let duplicate = VideoModeCatalog(formats: [alternatives.formats[0], VideoFormat(index: 2, resolution: hd, subtype: 0x34323076, rates: [])])
        precondition(duplicate.label(for: duplicate.formats[0]) != duplicate.label(for: duplicate.formats[1]))
        precondition(duplicate.pixelFormatLabel(for: duplicate.formats[0]) != duplicate.pixelFormatLabel(for: duplicate.formats[1]))
        let splitSelectors = VideoModeCatalog(formats: alternatives.formats + [
            VideoFormat(index: 2, resolution: uhd, subtype: 0x34323076, rates: [VideoRateRange(min: 10, max: 30)]),
            VideoFormat(index: 3, resolution: uhd, subtype: 0x32767579, rates: [VideoRateRange(min: 10, max: 20)])
        ])
        // Changing resolution retains an explicit 2vuy selection, even if 420v
        // could keep 30 FPS. Custom rates survive when the target supports them.
        precondition(splitSelectors.preferred(resolution: uhd, preserving: VideoMode(formatIndex: 1, fps: 30)) == VideoMode(formatIndex: 3, fps: 20))
        precondition(splitSelectors.preferred(resolution: uhd, preserving: VideoMode(formatIndex: 0, fps: 12.345)) == VideoMode(formatIndex: 2, fps: 12.345))
        precondition(splitSelectors.preferred(resolution: hd, preserving: VideoMode(formatIndex: 1, fps: 30)) == VideoMode(formatIndex: 1, fps: 30))
        precondition(catalog.preferred(resolution: uhd, preserving: VideoMode(formatIndex: 2, fps: clock)) == VideoMode(formatIndex: 9, fps: 29.97))
        precondition(splitSelectors.preferred(resolution: VideoResolution(width: 1, height: 1), preserving: VideoMode(formatIndex: 0, fps: 30)) == nil)
        print("PASS: separate resolution/format choices preserve subtype and supported FPS, distinguish duplicates and reject missing resolutions")
        print("PASS: explicit pixel format, per-format FPS, no silent fallback, format switch preserves supported custom FPS")
        print("PASS: resolution deduplication, native format preference, exact clocks, fractional ranges, custom FPS and invalid combinations")
    }
}
