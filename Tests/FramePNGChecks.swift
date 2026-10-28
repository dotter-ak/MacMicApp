import AVFoundation
import ImageIO

@main struct FramePNGChecks {
    static func frame(format: OSType, quadrants: Bool = false) throws -> FrameSnapshot {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixel = buffer!
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        func level(_ x: Int, _ y: Int) -> UInt8 {
            quadrants ? (x < 16 ? (y < 8 ? 16 : 80) : (y < 8 ? 160 : 235)) : (x < 16 ? 16 : 235)
        }
        if CVPixelBufferIsPlanar(pixel) {
            let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
            let chroma = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<16 { for x in 0..<32 { luma[y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + x] = level(x, y) } }
            for y in 0..<8 { for x in 0..<32 { chroma[y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) + x] = 128 } }
        } else {
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<16 { for x in stride(from: 0, to: 32, by: 2) {
                let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 2
                bytes[offset] = 128; bytes[offset+2] = 128
                bytes[offset+1] = level(x, y); bytes[offset+3] = level(x + 1, y)
            } }
        }
        return FrameSnapshot(pixelBuffer: pixel)
    }

    static func decodedPixels(_ url: URL) -> [UInt8] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == 32 && image.height == 16)
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 16))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 2048))
    }

    static func checkFlips(in directory: URL, format: OSType) async throws {
        let frozen = try frame(format: format, quadrants: true)
        let baselineURL = try await FramePNGEncoder.shared.save(frozen, in: directory)
        let baseline = decodedPixels(baselineURL)
        for horizontal in [false, true] {
            for vertical in [false, true] {
                let orientation = ImageOrientation(horizontalFlip: horizontal, verticalFlip: vertical)
                let url = try await FramePNGEncoder.shared.save(frozen, in: directory, orientation: orientation)
                defer { try? FileManager.default.removeItem(at: url) }
                let pixels = decodedPixels(url)
                for y in 0..<16 { for x in 0..<32 { for c in 0..<4 {
                    let sourceX = horizontal ? 31 - x : x
                    let sourceY = vertical ? 15 - y : y
                    precondition(pixels[(y * 32 + x) * 4 + c] == baseline[(sourceY * 32 + sourceX) * 4 + c],
                                 "PNG must reflect each axis independently without cropping or changing pixels")
                } } }
            }
        }
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("png-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8] {
            try await checkFlips(in: directory, format: format)
            let frozen = try frame(format: format)
            let url = try await FramePNGEncoder.shared.save(frozen, in: directory)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(image.width == 32 && image.height == 16)
            precondition(image.colorSpace?.name == CGColorSpace.sRGB)
            let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 16))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            for c in 0..<3 {
                precondition(bytes[8 * 128 + 8 * 4 + c] < 5)
                precondition(bytes[8 * 128 + 24 * 4 + c] > 250)
            }
            do {
                _ = try await FramePNGEncoder.shared.save(frozen, in: url.appendingPathComponent("nested"))
                preconditionFailure("Invalid destination must fail")
            } catch {}
        }
        let captures = directory.appendingPathComponent("auto-capture-\(UUID().uuidString)/nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: captures.deletingLastPathComponent()) }
        let frozen = try frame(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let sameInstant = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await FramePNGEncoder.shared.save(frozen, in: captures, date: sameInstant)
        let original = try Data(contentsOf: first)
        let second = try await FramePNGEncoder.shared.save(frozen, in: captures, date: sameInstant)
        precondition(first != second, "Captures in the same millisecond must have distinct names")
        let unchanged = try Data(contentsOf: first)
        precondition(unchanged == original, "Never overwrite an earlier capture")
        precondition(CGImageSourceCreateWithURL(second as CFURL, nil) != nil)
        do {
            _ = try await FramePNGEncoder.shared.save(frozen, in: first)
            preconditionFailure("A file cannot be used as a capture directory")
        } catch {}
        print("PASS: PNG conversion, four flip combinations in 420v/2vuy, dimensions, sRGB, levels, automatic directory creation, name collisions and write errors")
    }
}
