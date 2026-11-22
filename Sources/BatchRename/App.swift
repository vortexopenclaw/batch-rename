import SwiftUI
import AppKit
@preconcurrency import RenameCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created by `Launcher` before the app starts so cold-launch opens are never lost.
    static var model: Model? {
        didSet { if let model, model !== oldValue { openRequests.attach(model) } }
    }
    static var openRequests = OpenRequests()
    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppUpdater.fixtureJournal != nil {
            AppUpdater.reportFixture("ready")
            AppUpdater.acknowledge()
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Self.openRequests.receive(filenames.map { URL(fileURLWithPath: $0) }, model: Self.model)
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        switch model.requestQuit(onReady: { NSApp.reply(toApplicationShouldTerminate: true) }) {
        case .now: return .terminateNow
        case .later: return .terminateLater
        }
    }
}
struct BatchRenameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppDelegate.model ?? Model()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup("Batch Rename") {
            ContentView(model: model).onAppear {
                AppDelegate.model = model
                AppUpdater.acknowledge(); AppUpdater.showRecoveryNotice(); AppUpdater.reportFixture("view-appeared"); updater.checkAtStartup()
            }
        }
        .commands { AppCommands(model: model, updater: updater) }
    }
}

@main enum Launcher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify") {
            do { try Verification.run(); print("BUNDLED VERIFICATION PASSED"); exit(0) }
            catch { fputs("Verification failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--update-install" {
            do { try AppUpdater.install(CommandLine.arguments[2]); exit(0) }
            catch { AppUpdater.installFailed(CommandLine.arguments[2], error: error); exit(1) }
        }
        do {
            let journal = try AppUpdater.loadFixtureJournal()
            if CommandLine.arguments.contains("--lifecycle-probe") {
                guard let journal else { throw RenameError("Fixture resource was not recognized") }
                print("FIXTURE PROBE app=\(Bundle.main.bundleURL.path) journal=\(journal.path)")
                return
            }
            if let journal {
                AppUpdater.reportFixture("entered-main")
                AppDelegate.model = Model(journalURL: journal)
                AppUpdater.reportFixture("model-initialized")
            }
        } catch {
            fputs("Fixture configuration rejected: \(error)\n", stderr); exit(1)
        }
        // The model exists before any open-file events arrive (Dock drops, Open With).
        if AppDelegate.model == nil { AppDelegate.model = Model() }
        BatchRenameApp.main()
    }
}
