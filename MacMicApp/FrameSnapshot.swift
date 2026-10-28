import AVFoundation
import CoreImage

struct ImageOrientation: Equatable, Sendable {
    var horizontalFlip = false
    var verticalFlip = false

    func transform(in extent: CGRect = .zero) -> CGAffineTransform {
        CGAffineTransform(a: horizontalFlip ? -1 : 1, b: 0, c: 0,
                          d: verticalFlip ? -1 : 1,
                          tx: horizontalFlip ? extent.minX + extent.maxX : 0,
                          ty: verticalFlip ? extent.minY + extent.maxY : 0)
    }
}

// Retaining a completed capture buffer keeps its pool storage alive. It is never
// mutated by this app. The delegate keeps one latest buffer; a save owns one more.
final class FrameSnapshot: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

enum FrameSaveError: LocalizedError {
    case noFrame, encoding
    var errorDescription: String? {
        switch self {
        case .noFrame: "A current frame is not available. Wait for live video and try again."
        case .encoding: "The camera frame could not be converted to PNG."
        }
    }
}

actor FramePNGEncoder {
    static let shared = FramePNGEncoder()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func save(_ frame: FrameSnapshot, in directory: URL, date: Date = Date(),
              orientation: ImageOrientation = .init()) throws -> URL {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try pngData(frame, orientation: orientation)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let name = "Microscope_" + formatter.string(from: date)
        var suffix = 0
        while true {
            let url = directory.appendingPathComponent(name + (suffix == 0 ? "" : "_\(suffix)") + ".png")
            do {
                // Exclusive creation prevents overwriting, even if another process
                // creates this name between choosing it and writing the PNG.
                try png.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                suffix += 1
            }
        }
    }

    private func pngData(_ frame: FrameSnapshot, orientation: ImageOrientation) throws -> Data {
        // Core Image reads the pixel buffer's color attachments and converts to
        // an explicitly tagged sRGB PNG at the original resolution. Apply the
        // orientation frozen at capture time without modifying the source buffer.
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let image = source.transformed(by: orientation.transform(in: source.extent))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let png = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace) else {
            throw FrameSaveError.encoding
        }
        return png
    }
}
