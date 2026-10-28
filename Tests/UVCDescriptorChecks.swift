import Foundation

@main
struct UVCDescriptorChecks {
    static func main() throws {
        let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let rows = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let hex = rows.compactMap { $0["configurationHex"] as? String }.first!
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let descriptors = try UVCDescriptors(configuration: bytes)
        precondition(descriptors.version == 0x0100)
        precondition(descriptors.camera.interface == 0 && descriptors.camera.id == 1)
        precondition(descriptors.processing.id == 3)
        precondition(descriptors.camera.supports(bit: 1) && descriptors.camera.supports(bit: 3))
        precondition(descriptors.processing.supports(bit: 0) && descriptors.processing.supports(bit: 9))
        precondition(!descriptors.camera.supports(bit: 24) && !descriptors.camera.supports(bit: -1))
        func rejected(_ data: [UInt8]) {
            do { _ = try UVCDescriptors(configuration: data); preconditionFailure("Malformed descriptor accepted") }
            catch {}
        }
        rejected([])
        rejected(Array(bytes.dropLast()))
        var badLength = bytes; badLength[9] = 0; rejected(badLength)
        var truncatedLength = bytes; truncatedLength[bytes.count - 7] = 255; rejected(truncatedLength)
        var duplicate = bytes
        var cameraSize = bytes
        var wrongInterface = bytes
        var offset = 0
        while offset < bytes.count {
            if bytes[offset + 1] == 0x24 && bytes[offset + 2] == 5 {
                duplicate[offset + 3] = 1
            }
            if bytes[offset + 1] == 0x24 && bytes[offset + 2] == 2 && bytes[offset + 4] == 1 && bytes[offset + 5] == 2 {
                cameraSize[offset + 14] = 255
            }
            if bytes[offset + 1] == 4 && bytes[offset + 5] == 0x0e && bytes[offset + 6] == 1 {
                wrongInterface[offset + 6] = 2
            }
            offset += Int(bytes[offset])
        }
        rejected(duplicate)
        rejected(cameraSize)
        rejected(wrongInterface)
        print("PASS: actual Yizhan descriptors; truncation, zero/overflow length, duplicate entities, invalid control sizes and non-VC interface rejected")
    }
}
