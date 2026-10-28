import Foundation

struct UVCEntity: Equatable {
    let interface: UInt8
    let id: UInt8
    let kind: String
    let controls: [UInt8]
    func supports(bit: Int) -> Bool {
        bit >= 0 && bit / 8 < controls.count && (controls[bit / 8] & (1 << (bit % 8))) != 0
    }
}

struct UVCDescriptors {
    let version: UInt16
    let camera: UVCEntity
    let processing: UVCEntity

    init(configuration bytes: [UInt8]) throws {
        guard bytes.count >= 9, bytes[0] == 9, bytes[1] == 2,
              Int(bytes[2]) | (Int(bytes[3]) << 8) == bytes.count else { throw ParseError.invalid }
        var offset = 0
        var controlInterface: UInt8?
        var interfaces = Set<UInt8>()
        var cameras: [UVCEntity] = []
        var processors: [UVCEntity] = []
        var versions: [UInt16] = []
        var ids = Set<UInt8>()
        while offset < bytes.count {
            guard offset + 2 <= bytes.count else { throw ParseError.invalid }
            let length = Int(bytes[offset])
            guard length >= 2, length <= bytes.count - offset else { throw ParseError.invalid }
            let d = Array(bytes[offset..<(offset + length)])
            if d[1] == 4 {
                guard d.count >= 9 else { throw ParseError.invalid }
                controlInterface = d[3] == 0 && d[5] == 0x0e && d[6] == 1 ? d[2] : nil
                if let controlInterface { interfaces.insert(controlInterface) }
            } else if d[1] == 0x24, let controlInterface {
                guard d.count >= 3 else { throw ParseError.invalid }
                if d[2] == 1 {
                    guard d.count >= 12 else { throw ParseError.invalid }
                    versions.append(UInt16(d[3]) | UInt16(d[4]) << 8)
                } else if d[2] == 2 {
                    guard d.count >= 8 else { throw ParseError.invalid }
                    if d[4] == 1 && d[5] == 2 {
                        guard d.count >= 15, d.count >= 15 + Int(d[14]) else { throw ParseError.invalid }
                        cameras.append(UVCEntity(interface: controlInterface, id: d[3], kind: "camera", controls: Array(d[15..<(15 + Int(d[14]))])))
                    }
                } else if d[2] == 5 {
                    guard d.count >= 9, d.count >= 9 + Int(d[7]) else { throw ParseError.invalid }
                    processors.append(UVCEntity(interface: controlInterface, id: d[3], kind: "processing", controls: Array(d[8..<(8 + Int(d[7]))])))
                }
                // All entity subtypes share bUnitID/bTerminalID at byte 3.
                if (2...6).contains(d[2]) {
                    guard d.count >= 4, d[3] != 0, ids.insert(d[3]).inserted else { throw ParseError.invalid }
                }
            }
            offset += length
        }
        // Intentionally reject compound/ambiguous camera topologies in this probe.
        guard interfaces.count == 1, versions.count == 1, cameras.count == 1, processors.count == 1,
              cameras[0].interface == processors[0].interface else { throw ParseError.ambiguous }
        version = versions[0]
        camera = cameras[0]
        processing = processors[0]
    }

    enum ParseError: Error { case invalid, ambiguous }
}

// Only the observed packed USB camera-ID form is accepted. No name-only or
// VID/PID-only fallback. Unknown ID formats are intentionally not supported.
struct USBIdentity: Equatable {
    let location: UInt32
    let vendor: UInt32
    let product: UInt32

    init?(cameraID: String) {
        guard cameraID.hasPrefix("0x"), (3...18).contains(cameraID.count),
              let packed = UInt64(cameraID.dropFirst(2), radix: 16) else { return nil }
        location = UInt32(packed >> 32)
        vendor = UInt32((packed >> 16) & 0xffff)
        product = UInt32(packed & 0xffff)
        guard location != 0, vendor != 0, product != 0 else { return nil }
    }

    func matches(location: UInt32?, vendor: UInt32?, product: UInt32?) -> Bool {
        location == self.location && vendor == self.vendor && product == self.product
    }
}
