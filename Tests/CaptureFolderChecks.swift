import Foundation

@main
struct CaptureFolderChecks {
    @MainActor
    static func main() async throws {
        let suite = "MacMicApp.CaptureFolderChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("folder-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let settings = CaptureFolderPreferences(defaults: defaults)
        let initial = try await settings.resolve()
        precondition(settings.isDefault && initial.lastPathComponent == "MacMicApp Captures")
        try await settings.select(folder)
        let reloaded = CaptureFolderPreferences(defaults: UserDefaults(suiteName: suite)!)
        let restored = try await reloaded.resolve()
        precondition(!reloaded.isDefault && restored.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())

        defaults.set(Data("broken bookmark".utf8), forKey: "captureFolder.bookmark")
        let broken = CaptureFolderPreferences(defaults: defaults)
        precondition(!broken.isDefault && broken.path == folder.path)
        do {
            _ = try await broken.resolve()
            preconditionFailure("A broken bookmark must not silently fall back to Downloads")
        } catch {}
        broken.restoreDefault()
        let reset = try await CaptureFolderPreferences(defaults: defaults).resolve()
        precondition(reset == initial)
        settings.restoreDefault()
        let canceled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await settings.select(folder)
        }
        do { try await canceled.value; preconditionFailure("Canceled selection must not persist") }
        catch is CancellationError {}
        precondition(settings.isDefault && defaults.data(forKey: "captureFolder.bookmark") == nil)
        let nested = folder.appendingPathComponent("nested")
        try await CaptureFolderIO.shared.prepareDirectory(nested)
        precondition(FileManager.default.fileExists(atPath: nested.path))
        print("PASS: default folder, persistent custom bookmark, corrupt bookmark failure and reset")
    }
}
