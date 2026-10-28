import Foundation
import Observation

struct SavedCamera: Codable, Equatable {
    let id: String
    let name: String
    let kind: String
    init(_ device: CameraDevice) { id = device.id; name = device.name; kind = device.kind.rawValue }
    var isValid: Bool { !id.isEmpty && !name.isEmpty && CameraDevice.Kind(rawValue: kind) != nil }
    func matches(_ device: CameraDevice) -> Bool { id == device.id && name == device.name && kind == device.kind.rawValue }
}

// Disk access belongs to this actor, never to the UI actor. Pass immutable
// bookmark snapshots so a slow operation cannot change its destination midway.
struct CaptureFolderSelection: Sendable {
    let url: URL
    let bookmark: Data?
}

struct CaptureFolderResolution: Sendable {
    let url: URL
    let refreshedSelection: CaptureFolderSelection?
}

actor CaptureFolderIO {
    static let shared = CaptureFolderIO()

    func select(_ url: URL) throws -> CaptureFolderSelection {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.resolvingSymlinksInPath() == CaptureFolderPreferences.defaultURL.resolvingSymlinksInPath() {
            return CaptureFolderSelection(url: CaptureFolderPreferences.defaultURL, bookmark: nil)
        }
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        return CaptureFolderSelection(url: url, bookmark: data)
    }

    func resolve(_ bookmark: Data?) throws -> CaptureFolderResolution {
        guard let bookmark else {
            return CaptureFolderResolution(url: CaptureFolderPreferences.defaultURL, refreshedSelection: nil)
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return CaptureFolderResolution(url: url, refreshedSelection: stale ? try select(url) : nil)
    }

    func prepareDirectory(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// Folder authorization is separate from camera preferences. A failed bookmark
// must ask for a new selection, never silently save in a different folder.
@MainActor
@Observable
final class CaptureFolderPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let bookmarkKey = "captureFolder.bookmark"
    @ObservationIgnored private let pathKey = "captureFolder.path"
    private(set) var path: String
    private(set) var isDefault: Bool

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMicApp Captures", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let usesDefault = defaults.data(forKey: "captureFolder.bookmark") == nil
        isDefault = usesDefault
        path = usesDefault ? Self.defaultURL.path : (defaults.string(forKey: "captureFolder.path") ?? "Choose a capture folder")
    }

    func select(_ url: URL) async throws {
        try Task.checkCancellation()
        revision += 1
        let request = revision
        let selection = try await CaptureFolderIO.shared.select(url)
        try Task.checkCancellation()
        guard revision == request else { throw CancellationError() }
        apply(selection)
    }

    func restoreDefault() {
        revision += 1
        apply(CaptureFolderSelection(url: Self.defaultURL, bookmark: nil))
    }

    private func apply(_ selection: CaptureFolderSelection) {
        if let bookmark = selection.bookmark {
            defaults.set(bookmark, forKey: bookmarkKey)
            defaults.set(selection.url.path, forKey: pathKey)
        } else {
            defaults.removeObject(forKey: bookmarkKey)
            defaults.removeObject(forKey: pathKey)
        }
        path = selection.url.path
        isDefault = selection.bookmark == nil
    }

    func resolve() async throws -> URL {
        try Task.checkCancellation()
        let request = revision
        let result = try await CaptureFolderIO.shared.resolve(defaults.data(forKey: bookmarkKey))
        try Task.checkCancellation()
        // Return the requested destination, but never overwrite a newer choice
        // with a late bookmark refresh from an older operation.
        if revision == request {
            if let selection = result.refreshedSelection { apply(selection) }
            if path != result.url.path {
                path = result.url.path
                if !isDefault { defaults.set(path, forKey: pathKey) }
            }
        }
        return result.url
    }
}

// Catalog indices are session-local. Match only an unambiguous format signature.
struct SavedVideoMode: Codable, Equatable, Sendable {
    let resolution: VideoResolution
    let subtype: UInt32
    let rates: [VideoRateRange]
    let fps: Double

    init?(snapshot: CaptureSnapshot) {
        guard let format = snapshot.activeFormat else { return nil }
        resolution = format.resolution; subtype = format.subtype; rates = Self.sorted(format.rates); fps = snapshot.active.fps
        guard isValid, resolve(in: snapshot.catalog) != nil else { return nil }
    }
    var isValid: Bool {
        resolution.width > 0 && resolution.height > 0 && subtype != 0 && fps.isFinite && fps > 0
            && !rates.isEmpty && rates.allSatisfy { $0.min.isFinite && $0.min > 0 && $0.max.isFinite && $0.max >= $0.min }
            && rates.contains { $0.contains(fps) || abs($0.min - fps) < 0.0001 || abs($0.max - fps) < 0.0001 }
    }
    private static func sorted(_ rates: [VideoRateRange]) -> [VideoRateRange] {
        rates.sorted { $0.min == $1.min ? $0.max < $1.max : $0.min < $1.min }
    }
    func resolve(in catalog: VideoModeCatalog) -> VideoMode? {
        guard isValid else { return nil }
        let matches = catalog.formats.filter { format in
            guard format.resolution == resolution, format.subtype == subtype, format.rates.count == rates.count else { return false }
            return zip(Self.sorted(format.rates), Self.sorted(rates)).allSatisfy {
                abs($0.min - $1.min) < 0.000001 && abs($0.max - $1.max) < 0.000001
            }
        }
        guard matches.count == 1, let format = matches.first else { return nil }
        return catalog.resolve(resolution: resolution, fps: fps, formatIndex: format.index)
    }
}

@MainActor
final class CapturePreferences {
    static let shared = CapturePreferences()
    private struct Settings: Codable {
        var version = 1
        var hasSelection = false
        var camera: SavedCamera?
        var modes: [String: SavedVideoMode] = [:]
    }
    private let defaults: UserDefaults
    private let key = "capturePreferences.v1"
    private var settings = Settings()
    private(set) var loadWarning: String?
    var hasSelection: Bool { settings.hasSelection }
    var camera: SavedCamera? { settings.camera }
    var horizontalFlip: Bool { defaults.bool(forKey: "image.horizontalFlip") }
    var verticalFlip: Bool { defaults.bool(forKey: "image.verticalFlip") }

    func rememberOrientation(horizontal: Bool, vertical: Bool) {
        defaults.set(horizontal, forKey: "image.horizontalFlip")
        defaults.set(vertical, forKey: "image.verticalFlip")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: key) else { return }
        if let loaded = try? JSONDecoder().decode(Settings.self, from: data), loaded.version == 1,
           loaded.camera?.isValid ?? true, loaded.camera == nil || loaded.hasSelection {
            settings = loaded
            settings.modes = loaded.modes.filter { !$0.key.isEmpty && $0.value.isValid }
        } else {
            settings.hasSelection = true // Corruption must not start a different camera.
            loadWarning = "Saved camera settings could not be read. Choose a camera."
        }
    }
    func rememberCamera(_ device: CameraDevice?) {
        settings.hasSelection = true
        settings.camera = device.map(SavedCamera.init)
        loadWarning = nil
        persist()
    }
    func mode(for cameraID: String) -> SavedVideoMode? { settings.modes[cameraID] }
    @discardableResult
    func rememberMode(_ snapshot: CaptureSnapshot, cameraID: String) -> Bool {
        guard let saved = SavedVideoMode(snapshot: snapshot) else {
            settings.modes[cameraID] = nil
            persist()
            return false
        }
        settings.modes[cameraID] = saved
        persist()
        return true
    }
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(settings) else { return }
        if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
    }
}
