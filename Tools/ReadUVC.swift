import Foundation
@main
struct ReadUVC {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let identity = USBIdentity(cameraID: CommandLine.arguments[1]) else {
            fatalError("Pass the exact packed USB identity 0xLOCATIONvvvvpppp")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for index in 1...3 {
            let record = UVCReadProbe.inspect(identity: identity, phase: "read-only-\(index)")
            print(String(decoding: try encoder.encode(record), as: UTF8.self))
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
