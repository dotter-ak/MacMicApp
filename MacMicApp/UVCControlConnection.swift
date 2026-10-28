import AVFoundation
import IOKit
import IOKit.usb
import CoreAudio

// UVC control transport, confined to the capture queue. Retains the exact
// USB service/interface until restore; no re-discovery after unplug/replug.
final class UVCControlConnection: BrightnessTransport, ExposureTransport, ImageControlTransport {
    private let device: AVCaptureDevice
    private var service: io_service_t = 0
    private var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    private var interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface300>?>?
    private var descriptors: UVCDescriptors?
    private var disconnected = false
    private(set) var whiteBalanceRequiresTemperatureCommit = false
    private(set) var usesYizhanExposureProtocol = false

    init(device: AVCaptureDevice) throws {
        self.device = device
        do { try connect() } catch { close(); throw error }
    }
    deinit { close() }

    private func close() {
        if let interface { _ = interface.pointee!.pointee.Release(interface); self.interface = nil }
        if let plugin { IODestroyPlugInInterface(plugin); self.plugin = nil }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }

    private func connect() throws {
        guard device.isConnected, UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeUSB,
              let identity = USBIdentity(cameraID: device.uniqueID) else {
            throw BrightnessError.invalid("Cannot identify the selected USB camera.")
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            throw BrightnessError.invalid("Cannot enumerate USB devices.")
        }
        defer { IOObjectRelease(iterator) }
        var matches: [io_service_t] = []
        defer { matches.forEach { IOObjectRelease($0) } }
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            func property(_ name: String) -> UInt32? {
                guard let value = IORegistryEntryCreateCFProperty(candidate, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                      value.uint64Value <= UInt32.max else { return nil }
                return UInt32(value.uint64Value)
            }
            if identity.matches(location: property("locationID"), vendor: property("idVendor"), product: property("idProduct")) {
                matches.append(candidate)
            } else { IOObjectRelease(candidate) }
        }
        guard matches.count == 1, let exact = matches.first else {
            throw BrightnessError.invalid("Selected camera has no unique USB match.")
        }
        IOObjectRetain(exact)
        service = exact
        let deviceType = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
        let pluginType = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
        let interfaceType = CFUUIDCreateFromString(nil, "396104F7-943D-4893-90F1-69BD6CF5C2EB" as CFString)!
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, deviceType, pluginType, &plugin, &score) == kIOReturnSuccess,
              let plugin else { throw BrightnessError.invalid("USB shared interface is unavailable.") }
        var raw: UnsafeMutableRawPointer?
        guard plugin.pointee!.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceType), &raw) == 0,
              let raw else { throw BrightnessError.invalid("USB interface query failed.") }
        interface = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface300>?.self)
        let usb = interface!
        var descriptor: IOUSBConfigurationDescriptorPtr?
        guard usb.pointee!.pointee.GetConfigurationDescriptorPtr(usb, 0, &descriptor) == kIOReturnSuccess,
              let descriptor else { throw BrightnessError.invalid("USB configuration unavailable.") }
        var active: UInt8 = 0
        guard usb.pointee!.pointee.GetConfiguration(usb, &active) == kIOReturnSuccess,
              active == descriptor.pointee.bConfigurationValue else { throw BrightnessError.invalid("USB configuration mismatch.") }
        let size = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
        guard size >= 9 else { throw BrightnessError.invalid("Invalid USB descriptor length.") }
        let parsed = try UVCDescriptors(configuration: Array(UnsafeRawBufferPointer(start: descriptor, count: size)))
        descriptors = parsed
        var release: UInt16 = 0
        let releaseStatus = usb.pointee!.pointee.GetDeviceReleaseNumber(usb, &release)
        whiteBalanceRequiresTemperatureCommit = identity.vendor == 0x0ac8 && identity.product == 0x3420
            && releaseStatus == kIOReturnSuccess && release == 0x0409
            && parsed.processing.id == 3 && parsed.processing.interface == 0
            && parsed.processing.supports(bit: UVCImageControl.autoWhiteBalance.bit)
            && parsed.processing.supports(bit: UVCImageControl.whiteBalance.bit)
        usesYizhanExposureProtocol = identity.vendor == 0x0ac8 && identity.product == 0x3420
            && releaseStatus == kIOReturnSuccess && release == 0x0409
            && parsed.camera.id == 1 && parsed.camera.interface == 0
            && parsed.camera.supports(bit: UVCExposureControl.mode.bit)
            && parsed.camera.supports(bit: UVCExposureControl.exposure.bit)
    }

    var supportsBrightness: Bool { descriptors?.processing.supports(bit: 0) == true }

    func supportsExposureControl(_ id: UVCExposureControl) -> Bool {
        let entity = id.usesCameraTerminal ? descriptors?.camera : descriptors?.processing
        return entity?.supports(bit: id.bit) == true
    }

    func get(_ request: UInt8) throws -> [UInt8] {
        guard request != 0x01 else { throw BrightnessError.invalid("GET cannot write brightness.") }
        return try transfer(request, payload: nil)
    }
    func set(_ bytes: [UInt8]) throws { _ = try transfer(0x01, payload: bytes) }

    func readExposure(_ id: UVCExposureControl, request: UInt8) throws -> [UInt8] {
        guard request != 1 else { throw CameraControlError.invalid("Read cannot write a control.") }
        return try transfer(request, payload: nil, exposure: id)
    }
    func writeExposure(_ id: UVCExposureControl, bytes: [UInt8]) throws {
        _ = try transfer(1, payload: bytes, exposure: id)
    }

    var imageControlVersion: UInt16 { descriptors?.version ?? 0 }
    func supportsImageControl(_ id: UVCImageControl) -> Bool {
        descriptors?.processing.supports(bit: id.bit) == true
    }
    func readImageControl(_ id: UVCImageControl, request: UInt8) throws -> [UInt8] {
        guard request != 1 else { throw CameraControlError.invalid("Read cannot write a control.") }
        return try transfer(request, payload: nil, image: id)
    }
    func writeImageControl(_ id: UVCImageControl, bytes: [UInt8]) throws {
        _ = try transfer(1, payload: bytes, image: id)
    }

    private func transfer(_ request: UInt8, payload: [UInt8]?, exposure: UVCExposureControl? = nil, image: UVCImageControl? = nil) throws -> [UInt8] {
        guard !disconnected, device.isConnected, let usb = interface, let descriptors else {
            disconnected = true
            throw BrightnessError.invalid("USB camera disconnected; no further commands will be sent.")
        }
        let entity = exposure?.usesCameraTerminal == true ? descriptors.camera : descriptors.processing
        guard entity.supports(bit: image?.bit ?? exposure?.bit ?? 0), [0x01,0x81,0x82,0x83,0x84,0x86,0x87].contains(request) else {
            throw CameraControlError.invalid("This camera does not advertise the requested control.")
        }
        let spec = (type: UInt8(request == 1 ? 0x21 : 0xa1), request: request,
                    value: UInt16(image?.selector ?? exposure?.selector ?? 2) << 8,
                    index: UInt16(entity.id) << 8 | UInt16(entity.interface),
                    length: UInt16(request == 0x86 ? 1 : (image?.width ?? exposure?.width ?? 2)), timeout: UInt32(500))
        var bytes = payload ?? [UInt8](repeating: 0, count: Int(spec.length))
        guard bytes.count == Int(spec.length) else { throw BrightnessError.invalid("Invalid control payload length.") }
        var transaction = IOUSBDevRequestTO()
        transaction.bmRequestType = spec.type
        transaction.bRequest = spec.request
        transaction.wValue = spec.value
        transaction.wIndex = spec.index
        transaction.wLength = spec.length
        transaction.noDataTimeout = spec.timeout
        transaction.completionTimeout = spec.timeout
        let started = ProcessInfo.processInfo.systemUptime
        let status = bytes.withUnsafeMutableBytes { data in
            transaction.pData = data.baseAddress
            return usb.pointee!.pointee.DeviceRequestTO(usb, &transaction)
        }
        #if DEBUG
        if HardwareProbe.isEnabled { HardwareProbe.emit([
            "event": image != nil ? "uvc-image-transfer" : exposure == nil ? "uvc-brightness-transfer" : "uvc-exposure-transfer", "request": String(format: "0x%02x", request),
            "type": String(format: "0x%02x", spec.type), "value": String(format: "0x%04x", spec.value),
            "index": String(format: "0x%04x", spec.index), "expectedBytes": String(spec.length),
            "bytes": String(transaction.wLenDone), "status": String(format: "0x%08x", UInt32(bitPattern: status)),
            "payload": bytes.prefix(min(bytes.count, Int(transaction.wLenDone))).map { String(format: "%02x", $0) }.joined(),
            "elapsedMilliseconds": String((ProcessInfo.processInfo.systemUptime - started) * 1000)
        ]) }
        #endif
        if status == kIOReturnNoDevice || status == kIOReturnNotAttached || status == kIOReturnOffline {
            disconnected = true
        }
        let allowShort = ((exposure != nil && exposure != .mode) || image?.width == 2) && request != 1 && request != 0x86
        guard status == kIOReturnSuccess, transaction.wLenDone > 0, transaction.wLenDone <= spec.length,
              allowShort || transaction.wLenDone == spec.length else {
            throw CameraControlError.invalid("Camera control request failed or returned an incomplete response.")
        }
        return Array(bytes.prefix(Int(transaction.wLenDone)))
    }
}
