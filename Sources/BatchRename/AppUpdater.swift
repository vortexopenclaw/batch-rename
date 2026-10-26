import Foundation
import AppKit
import Darwin
import CryptoKit
import RenameCore

private struct InstallPlan: Codable {
    let original: URL
    let transaction: URL
    let manifest: UpdateManifest
    let parent: Int32
    let token: String
    let parentLaunch: Date
}

@MainActor final class AppUpdater: ObservableObject {
    @Published var busy = false
    private(set) var checkedAtStartup = false
    func checkAtStartup() {
        guard !checkedAtStartup else { return }
        checkedAtStartup = true
        check(automatic: true)
    }
    private func waitForIdle() async throws {
        while AppDelegate.model?.busy == true {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard AppDelegate.model?.startupHealthy == true else { throw RenameError("Updates require a healthy rename engine. Resolve the startup error first.") }
    }
    func check(automatic: Bool = false) {
        guard !busy else { return }
        busy = true
        Task {
            var installationModel: Model?
            defer { installationModel?.endInstallation(); busy = false }
            do {
                let config = try UpdateConfiguration.load()
                let fetcher = UpdateFetcher()
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: await fetcher.fetch(config.manifestURL, limit: 65536))
                let os = ProcessInfo.processInfo.operatingSystemVersion
                try UpdatePolicy.validate(manifest, trust: config.trust, currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", allowCurrent: true)
                try await waitForIdle()
                if manifest.version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    guard !automatic else { return }
                    let alert = NSAlert(); alert.messageText = "Batch Rename is up to date"; alert.runModal(); return
                }
                let alert = NSAlert(); alert.messageText = "Install Batch Rename \(manifest.version)?"
                alert.informativeText = "The app will quit and reopen. Your current app will be retained in a backup beside it."
                alert.addButton(withTitle: "Install and Restart"); alert.addButton(withTitle: "Later")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard let model = AppDelegate.model, model.beginInstallation() else { throw RenameError("Wait for the current file operation to finish, then check again.") }
                installationModel = model
                let data = try await fetcher.fetch(manifest.downloadURL, limit: 256 * 1024 * 1024)
                try UpdatePolicy.validateArchive(data, manifest: manifest)
                guard AppDelegate.model?.busy != true else { throw RenameError("Wait for the current file operation to finish, then check again.") }
                let original = Bundle.main.bundleURL
                try UpdateInstaller.physical(original)
                guard original.pathExtension == "app", !original.path.contains("/AppTranslocation/") else { throw RenameError("Move the app to a writable installation folder before updating.") }
                let transaction = original.deletingLastPathComponent().appendingPathComponent(".batch-rename-update-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try data.write(to: transaction.appendingPathComponent("release.zip"), options: .withoutOverwriting)
                try UpdateArchive.extract(data, to: transaction.appendingPathComponent("stage"))
                try UpdateInstaller.validateBundle(transaction.appendingPathComponent("stage/Batch Rename.app"), manifest: manifest)
                guard let parentLaunch = NSRunningApplication.current.launchDate else { throw RenameError("Cannot establish parent identity; original retained.") }
                try Self.requireOnlyInstance(original, allowed: [getpid()])
                let plan = InstallPlan(original: original, transaction: transaction, manifest: manifest, parent: getpid(), token: UUID().uuidString, parentLaunch: parentLaunch)
                let planURL = transaction.appendingPathComponent("plan.json")
                try JSONEncoder().encode(plan).write(to: planURL, options: .withoutOverwriting)
                let process = Process(); process.executableURL = Bundle.main.executableURL; process.arguments = ["--update-install", planURL.path]
                try process.run()
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: transaction.appendingPathComponent("ready").path) { break }
                    guard process.isRunning else { throw RenameError("Update helper could not validate this app. Original retained.") }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard FileManager.default.fileExists(atPath: transaction.appendingPathComponent("ready").path) else {
                    process.terminate(); throw RenameError("Update helper did not become ready. Original retained.")
                }
                NSApplication.shared.terminate(nil)
            } catch {
                // Startup failures are silent; failures after accepting installation are actionable.
                guard !automatic || installationModel != nil else { return }
                while AppDelegate.model?.busy == true { try? await Task.sleep(nanoseconds: 100_000_000) }
                let alert = NSAlert(); alert.messageText = "Update not installed"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
    }
    // Invalid fixture configuration must never fall back to the user's undo history.
    nonisolated static func loadFixtureJournal(bundle: Bundle = .main) throws -> URL? {
        guard let resource = bundle.url(forResource: "LifecycleFixture", withExtension: "json") else { return nil }
        let app = bundle.bundleURL
        guard let scratch = ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"],
              app.path.hasPrefix(URL(fileURLWithPath: scratch).standardizedFileURL.path + "/") else { throw RenameError("Fixture app is outside physical scratch") }
        try UpdateInstaller.physical(app)
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: resource))
        guard let path = values["journal"] else { throw RenameError("Missing fixture journal") }
        let journal = URL(fileURLWithPath: path)
        let parent = app.deletingLastPathComponent().standardizedFileURL.path
        guard journal.standardizedFileURL.path.hasPrefix(parent + "/") else { throw RenameError("Fixture journal escapes fixture directory") }
        // Resolve each existing ancestor too: Foundation can leave a nonexistent leaf unresolved.
        var ancestor = journal
        while ancestor.path != "/" {
            // Inspect only inode metadata. Foundation's attributesOfItem also reads
            // extended attributes, which can block startup on external volumes.
            var metadata = stat()
            if lstat(ancestor.path, &metadata) == 0 {
                guard metadata.st_mode & UInt16(S_IFMT) != UInt16(S_IFLNK) else { throw RenameError("Fixture journal contains a symbolic link") }
            } else if errno != ENOENT {
                throw RenameError("Cannot inspect fixture journal ancestor")
            }
            try UpdateInstaller.physical(ancestor)
            ancestor.deleteLastPathComponent()
        }
        return journal
    }
    nonisolated static var fixtureJournal: URL? { try? loadFixtureJournal() }

    static func reportFixture(_ phase: String) {
        guard let journal = fixtureJournal else { return }
        do {
            let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("lifecycle-status")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch { /* The directory may already exist. The report write below still must succeed. */ }
        do {
            let report: [String: Any] = ["pid": Int(getpid()), "phase": phase,
                "app": Bundle.main.bundleURL.path, "journal": journal.path,
                "healthy": AppDelegate.model?.startupHealthy == true,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
            let target = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("lifecycle-status/\(getpid()).json")
            try JSONSerialization.data(withJSONObject: report, options: .sortedKeys).write(to: target, options: .atomic)
        } catch { fputs("Fixture report failed (\(phase)): \(error)\n", stderr) }
    }
    nonisolated static func requireOnlyInstance(_ original: URL, allowed: Set<pid_t>) throws {
        // LaunchServices omits direct executable launches. Inspect same-user processes too,
        // and fail closed when process visibility is incomplete.
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard bytes > 0 else { throw RenameError("Cannot inspect running app instances. Original retained.") }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 128)
        let capacity = pids.count * MemoryLayout<pid_t>.size
        let used = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32(capacity)) }
        guard used > 0, used < capacity else { throw RenameError("Running process list is uncertain. Original retained.") }
        let executable = original.appendingPathComponent("Contents/MacOS/BatchRename").path
        for pid in pids.prefix(Int(used) / MemoryLayout<pid_t>.size) where pid > 0 && !allowed.contains(pid) {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if result <= 0 {
                if kill(pid, 0) != 0 && errno == ESRCH { continue }
                throw RenameError("Cannot verify all running processes. Quit other instances and retry. Original retained.")
            }
            guard String(cString: buffer) != executable else { throw RenameError("Another instance of this app is running. Quit all instances and retry. Original retained.") }
        }
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == original.standardizedFileURL {
            guard allowed.contains(app.processIdentifier) else { throw RenameError("Another instance of this app is running. Quit all instances and retry. Original retained.") }
        }
    }
    nonisolated static func install(_ path: String) throws {
        let plan = try JSONDecoder().decode(InstallPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard plan.original == Bundle.main.bundleURL, plan.transaction.deletingLastPathComponent() == plan.original.deletingLastPathComponent(), plan.transaction.lastPathComponent.hasPrefix(".batch-rename-update-") else { throw RenameError("Invalid install plan") }
        try UpdateInstaller.physical(plan.transaction)
        guard plan.parent > 1, plan.parent != getpid(), UUID(uuidString: plan.token) != nil,
              let parent = NSRunningApplication(processIdentifier: plan.parent),
              parent.bundleURL == plan.original, parent.executableURL == Bundle.main.executableURL,
              parent.launchDate == plan.parentLaunch, !parent.isTerminated else { throw RenameError("Parent identity could not be verified. Original retained.") }
        try requireOnlyInstance(plan.original, allowed: [plan.parent, getpid()])
        let config = try UpdateConfiguration.load()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        try UpdatePolicy.validate(plan.manifest, trust: config.trust, currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        try UpdatePolicy.validateArchive(Data(contentsOf: plan.transaction.appendingPathComponent("release.zip")), manifest: plan.manifest)
        // Re-extract authenticated bytes in the helper, never trust an earlier staged directory.
        let stage = plan.transaction.appendingPathComponent("install")
        try UpdateArchive.extract(Data(contentsOf: plan.transaction.appendingPathComponent("release.zip")), to: stage)
        let app = stage.appendingPathComponent("Batch Rename.app")
        try UpdateInstaller.validateBundle(app, manifest: plan.manifest)
        try Data(plan.token.utf8).write(to: plan.transaction.appendingPathComponent("ready"), options: .withoutOverwriting)
        for _ in 0..<120 {
            if kill(plan.parent, 0) != 0 && errno == ESRCH { break }
            guard let live = NSRunningApplication(processIdentifier: plan.parent), live.launchDate == plan.parentLaunch,
                  live.bundleURL == plan.original else { throw RenameError("Parent identity changed or became uncertain. Original retained.") }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard kill(plan.parent, 0) != 0 && errno == ESRCH else { throw RenameError("App did not exit; original retained") }
        try requireOnlyInstance(plan.original, allowed: [getpid()])
        let backup = plan.transaction.appendingPathComponent("previous.app")
        // Record the original executable and metadata before moving it.
        try UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", plan.original.path])
        let originalCode = try Data(contentsOf: plan.original.appendingPathComponent("Contents/MacOS/BatchRename"))
        try Data(SHA256.hash(data: originalCode)).write(to: plan.transaction.appendingPathComponent("original-code.sha256"), options: .withoutOverwriting)
        let originalInfo = try Data(contentsOf: plan.original.appendingPathComponent("Contents/Info.plist"))
        try originalInfo.write(to: plan.transaction.appendingPathComponent("original-info.plist"), options: .withoutOverwriting)
        let fixtureLaunchFailure = fixtureJournal != nil && FileManager.default.fileExists(atPath: plan.original.appendingPathComponent("Contents/Resources/FixtureLaunchFailure").path)
        try UpdateInstaller.replace(original: plan.original, staged: app, backup: backup) {
            if fixtureLaunchFailure {
                try UpdateInstaller.run("/usr/bin/open", ["-g", plan.transaction.appendingPathComponent("missing-fixture.app").path])
                throw RenameError("Fixture launch unexpectedly succeeded")
            }
            try UpdateInstaller.run("/usr/bin/open", ["-g", "-n", plan.original.path, "--args", "--update-health", path, plan.token])
        }
        for _ in 0..<(fixtureJournal == nil ? 120 : 12) {
            if UpdateHealth.confirmed(at: plan.transaction, token: plan.token) { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // open success is not startup success. Leave both versions available rather than racing a live app.
        throw RenameError("Startup was not acknowledged. Quit the updated app and recover the previous version from \(backup.path).")
    }
    nonisolated private static func validatedPlan(_ path: String) -> InstallPlan? {
        guard let plan = try? JSONDecoder().decode(InstallPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path))),
              plan.original == Bundle.main.bundleURL,
              plan.transaction.deletingLastPathComponent() == plan.original.deletingLastPathComponent(),
              plan.transaction.lastPathComponent.hasPrefix(".batch-rename-update-"),
              (try? UpdateInstaller.physical(plan.transaction)) != nil else { return nil }
        return plan
    }
    @MainActor static func installFailed(_ path: String, error: Error) {
        var detail = error.localizedDescription
        if let plan = validatedPlan(path) {
            detail += "\n\nYour update files are retained at \(plan.transaction.path). If previous.app exists, quit all Batch Rename windows before moving it back to \(plan.original.path)."
            try? Data(detail.utf8).write(to: plan.transaction.appendingPathComponent("NEEDS-RECOVERY.txt"), options: .atomic)
            // replace() restores on launch failure. Only reopen a verified original, never the candidate or helper arguments.
            if let expected = try? Data(contentsOf: plan.transaction.appendingPathComponent("original-info.plist")),
               let actual = try? Data(contentsOf: plan.original.appendingPathComponent("Contents/Info.plist")), expected == actual,
               let expectedCode = try? Data(contentsOf: plan.transaction.appendingPathComponent("original-code.sha256")),
               let actualCode = try? Data(contentsOf: plan.original.appendingPathComponent("Contents/MacOS/BatchRename")),
               expectedCode == Data(SHA256.hash(data: actualCode)),
               (try? requireOnlyInstance(plan.original, allowed: [getpid()])) != nil,
               (try? UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", plan.original.path])) != nil {
                try? UpdateInstaller.run("/usr/bin/open", ["-g", plan.original.path])
            }
        }
        fputs("Update install failed: \(detail)\n", stderr)
        // Fixture runs persist the same notice without presenting a modal dialog or stealing focus.
        if fixtureJournal != nil { return }
        let alert = NSAlert(); alert.messageText = "Update needs attention"; alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if validatedPlan(path) != nil { alert.addButton(withTitle: "Show Recovery Files") }
        if alert.runModal() == .alertSecondButtonReturn, let plan = validatedPlan(path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: plan.transaction.path)
        }
    }
    private static var showedRecovery = false
    static func showRecoveryNotice() {
        guard !showedRecovery else { return }; showedRecovery = true
        let original = Bundle.main.bundleURL
        guard let directories = try? FileManager.default.contentsOfDirectory(at: original.deletingLastPathComponent(), includingPropertiesForKeys: nil) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix(".batch-rename-update-") {
            guard let plan = validatedPlan(directory.appendingPathComponent("plan.json").path),
                  let notice = try? String(contentsOf: plan.transaction.appendingPathComponent("NEEDS-RECOVERY.txt"), encoding: .utf8) else { continue }
            AppDelegate.model?.message = "Update recovery needed. " + notice
            if fixtureJournal == nil {
                let alert = NSAlert(); alert.messageText = "Previous update needs attention"; alert.informativeText = notice
                alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Show Recovery Files")
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path) }
            }
        }
    }
    static func acknowledge() {
        let args = CommandLine.arguments
        guard args.count == 4, args[1] == "--update-health", AppDelegate.model?.startupHealthy == true else { return }
        do {
            let plan = try JSONDecoder().decode(InstallPlan.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            guard plan.original == Bundle.main.bundleURL, plan.token == args[3], plan.manifest.version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  plan.transaction.deletingLastPathComponent() == plan.original.deletingLastPathComponent() else { return }
            try UpdateInstaller.physical(plan.transaction)
            try UpdateInstaller.validateBundle(plan.original, manifest: plan.manifest)
            try UpdateHealth.acknowledge(at: plan.transaction, token: args[3], expectedToken: plan.token, healthy: true)
        } catch { /* No acknowledgment means the backup remains available for recovery. */ }
    }
}
