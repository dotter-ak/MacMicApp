#if DEBUG
import AVFoundation
import IOKit
import IOKit.usb
import IOUSBHost
import CoreAudio

// Diagnostic only. Never seizes, captures, resets or reconfigures the USB device.
// Called solely on CaptureEngine's serial queue while its video session runs.
enum UVCReadProbe {
    static func inspect(device: AVCaptureDevice, phase: String) -> [String: String] {
        guard UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeUSB,
              let identity = USBIdentity(cameraID: device.uniqueID) else {
            return ["event": "uvc-read", "phase": phase, "status": "unrecognized-camera-id", "writesPerformed": "false"]
        }
        return inspect(identity: identity, phase: phase)
    }

    // Read-only CLI entry point for an explicitly supplied, exact USB identity.
    static func inspect(identity: USBIdentity, phase: String) -> [String: String] {
        var report = ["event": "uvc-read", "phase": phase, "writesPerformed": "false",
                      "transport": "IOUSBHostDevice", "openOptions": "none"]
        var iterator: io_iterator_t = 0
        let matchingStatus = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard matchingStatus == KERN_SUCCESS else {
            report["status"] = "registry-error"
            report["errorCode"] = String(matchingStatus)
            return report
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [io_service_t] = []
        defer { candidates.forEach { IOObjectRelease($0) } }
        while case let service = IOIteratorNext(iterator), service != 0 {
            func property(_ name: String) -> UInt32? {
                guard let value = IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return nil }
                let number = value.uint64Value
                return number <= UInt32.max ? UInt32(number) : nil
            }
            if identity.matches(location: property("locationID"), vendor: property("idVendor"), product: property("idProduct")) {
                candidates.append(service)
            } else { IOObjectRelease(service) }
        }
        report["exactMatches"] = String(candidates.count)
        guard candidates.count == 1, let service = candidates.first else {
            report["status"] = "missing-or-ambiguous-device"
            return report
        }
        report["mapping"] = "exact location+vendor+product encoded in AVFoundation USB ID"
        do {
            let host = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { host.destroy() }
            report["status"] = "opened"
            if let descriptor = host.configurationDescriptor {
                let size = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
                guard size >= 9, size <= 65535 else {
                    report["status"] = "invalid-configuration-length"
                    return report
                }
                let data = UnsafeRawBufferPointer(start: descriptor, count: size)
                report["configurationHex"] = data.map { String(format: "%02x", $0) }.joined()
            } else { report["status"] = "configuration-unavailable" }
        } catch {
            let failure = error as NSError
            report["status"] = "open-error"
            report["errorDomain"] = failure.domain
            report["errorCode"] = String(failure.code)
            report["errorHex"] = String(format: "0x%08x", UInt32(truncatingIfNeeded: failure.code))
            report["errorDescription"] = failure.localizedDescription
        }
        report.merge(inspectSharedInterface(service: service)) { _, new in new }
        return report
    }

    // Documented IOUSBLib access without USBDeviceOpen/USBDeviceOpenSeize.
    // Keep this diagnostic fallback isolated from the normal capture path.
    private static func inspectSharedInterface(service: io_service_t) -> [String: String] {
        var result = ["sharedTransport": "IOUSBDeviceInterface300", "sharedOpenCalled": "false"]
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        // UUID constants from IOUSBLib.h / IOCFPlugIn.h; C macros are not
        // imported by Swift. These identify system interfaces, not hardware.
        let deviceType = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
        let pluginType = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
        let interfaceType = CFUUIDCreateFromString(nil, "396104F7-943D-4893-90F1-69BD6CF5C2EB" as CFString)!
        let status = IOCreatePlugInInterfaceForService(service, deviceType, pluginType, &plugin, &score)
        guard status == kIOReturnSuccess, let plugin else {
            result["sharedStatus"] = "plugin-error"
            result["sharedErrorHex"] = String(format: "0x%08x", UInt32(bitPattern: status))
            return result
        }
        defer { IODestroyPlugInInterface(plugin) }
        var rawInterface: UnsafeMutableRawPointer?
        let query = plugin.pointee!.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceType), &rawInterface)
        guard query == 0, let rawInterface else {
            result["sharedStatus"] = "query-interface-error"
            result["sharedErrorHex"] = String(format: "0x%08x", UInt32(bitPattern: query))
            return result
        }
        let interface = rawInterface.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface300>?.self)
        defer { _ = interface.pointee!.pointee.Release(interface) }
        var configuration: IOUSBConfigurationDescriptorPtr?
        let descriptorStatus = interface.pointee!.pointee.GetConfigurationDescriptorPtr(interface, 0, &configuration)
        guard descriptorStatus == kIOReturnSuccess, let configuration else {
            result["sharedStatus"] = "configuration-error"
            result["sharedErrorHex"] = String(format: "0x%08x", UInt32(bitPattern: descriptorStatus))
            return result
        }
        let size = Int(UInt16(littleEndian: configuration.pointee.wTotalLength))
        guard size >= 9 else { result["sharedStatus"] = "invalid-configuration-length"; return result }
        var selectedConfiguration: UInt8 = 0
        let selectedStatus = interface.pointee!.pointee.GetConfiguration(interface, &selectedConfiguration)
        guard selectedStatus == kIOReturnSuccess, selectedConfiguration == configuration.pointee.bConfigurationValue else {
            result["sharedStatus"] = "configuration-mismatch"
            return result
        }
        let bytes = Array(UnsafeRawBufferPointer(start: configuration, count: size))
        result["configurationHex"] = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            let descriptors = try UVCDescriptors(configuration: bytes)
            result["uvcVersionHex"] = String(format: "0x%04x", descriptors.version)
            result["controlInterface"] = String(descriptors.camera.interface)
            result["cameraTerminalID"] = String(descriptors.camera.id)
            result["processingUnitID"] = String(descriptors.processing.id)
            result["cameraControlsHex"] = descriptors.camera.controls.map { String(format: "%02x", $0) }.joined()
            result["processingControlsHex"] = descriptors.processing.controls.map { String(format: "%02x", $0) }.joined()
            let controls: [(String, UVCEntity, Int, UInt8, Int, Bool)] = [
                ("autoExposureMode", descriptors.camera, 1, 2, 1, false),
                ("exposureAbsolute", descriptors.camera, 3, 4, 4, false),
                ("brightness", descriptors.processing, 0, 2, 2, true),
                ("gain", descriptors.processing, 9, 4, 2, false),
                ("autoWhiteBalance", descriptors.processing, 12, 0x0b, 1, false),
                ("whiteBalanceTemperature", descriptors.processing, 6, 0x0a, 2, false),
                ("autoWhiteBalanceComponent", descriptors.processing, 13, 0x0d, 1, false),
                ("whiteBalanceComponent", descriptors.processing, 7, 0x0c, 4, false)
            ]
            for (name, entity, bit, selector, width, signed) in controls {
                guard entity.supports(bit: bit) else { result[name + ".status"] = "not-advertised"; continue }
                func read(_ request: UInt8, width: Int) -> [UInt8]? {
                    var buffer = [UInt8](repeating: 0xa5, count: width)
                    var transaction = IOUSBDevRequestTO()
                    transaction.bmRequestType = 0xa1 // IN, class, interface; read only.
                    transaction.bRequest = request
                    transaction.wValue = UInt16(selector) << 8
                    transaction.wIndex = UInt16(entity.id) << 8 | UInt16(entity.interface)
                    transaction.wLength = UInt16(width)
                    transaction.noDataTimeout = 500
                    transaction.completionTimeout = 500
                    let status = buffer.withUnsafeMutableBytes { data in
                        transaction.pData = data.baseAddress
                        return interface.pointee!.pointee.DeviceRequestTO(interface, &transaction)
                    }
                    let key = name + "." + String(format: "%02x", request)
                    result[key + ".status"] = String(format: "0x%08x", UInt32(bitPattern: status))
                    result[key + ".bytes"] = String(transaction.wLenDone)
                    result[key + ".expectedBytes"] = String(width)
                    if status == kIOReturnSuccess {
                        result[key + ".rawHex"] = buffer.prefix(min(width, Int(transaction.wLenDone))).map { String(format: "%02x", $0) }.joined()
                    }
                    guard status == kIOReturnSuccess, transaction.wLenDone == width else { return nil }
                    result[key + ".hex"] = buffer.map { String(format: "%02x", $0) }.joined()
                    return buffer
                }
                guard let info = read(0x86, width: 1) else { result[name + ".status"] = "info-error"; continue }
                result[name + ".canRead"] = String(info[0] & 1 != 0)
                result[name + ".canWriteAdvertised"] = String(info[0] & 2 != 0)
                result[name + ".disabledByAuto"] = String(info[0] & 4 != 0)
                guard info[0] & 1 != 0 else { result[name + ".status"] = "get-not-supported"; continue }
                let requests: [UInt8] = name.hasPrefix("autoWhiteBalance") ? [0x81, 0x87]
                    : name == "autoExposureMode" ? [0x81, 0x84, 0x87] : [0x81, 0x82, 0x83, 0x84, 0x87]
                for request in requests {
                    if let response = read(request, width: width) {
                        let unsigned = response.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
                        let value = signed ? Int64(Int16(bitPattern: UInt16(unsigned))) : Int64(unsigned)
                        result[name + "." + String(format: "%02x", request) + ".value"] = String(value)
                    }
                }
                result[name + ".status"] = result[name + ".81.value"] == nil ? "current-read-error" : "current-read"
            }
            result["sharedStatus"] = "controls-inspected"
        } catch {
            result["sharedStatus"] = "descriptor-parse-error"
            result["descriptorError"] = String(describing: error)
        }
        return result
    }

}

#endif
