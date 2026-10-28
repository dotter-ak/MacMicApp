import Foundation

@main
struct USBIdentityChecks {
    static func main() {
        let first = USBIdentity(cameraID: "0x021122000ac83420")!
        let second = USBIdentity(cameraID: "0x021123000ac83420")!
        precondition(first != second)
        precondition(first.matches(location: 0x02112200, vendor: 0x0ac8, product: 0x3420))
        precondition(!first.matches(location: second.location, vendor: second.vendor, product: second.product))
        precondition(!first.matches(location: nil, vendor: first.vendor, product: first.product))
        precondition(!first.matches(location: first.location, vendor: nil, product: first.product))
        precondition(!first.matches(location: first.location, vendor: first.vendor, product: nil))
        precondition(USBIdentity(cameraID: "0x21122000ac83420") == first)
        for invalid in ["", "H1612 Camera", "0ac83420", "0x0ac83420", "0x000000000ac83420", "0x0211220000003420", "0x021122000ac80000", "0xgg1122000ac83420", "0x1021122000ac83420f"] {
            precondition(USBIdentity(cameraID: invalid) == nil, invalid)
        }
        print("PASS: USB camera identity; same VID/PID at different locations; missing properties and malformed IDs rejected")
    }
}
