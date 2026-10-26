import Foundation
import AppKit
import CryptoKit
import RenameCore

guard ProcessInfo.processInfo.environment["BATCH_RENAME_ALLOW_GUI_LIFECYCLE"] == "1" else {
    fatalError("GUI lifecycle requires explicit opt-in through the harness")
}
let fm = FileManager.default
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_SCRATCH"] ?? ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("batch-rename-lifecycle-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
try UpdateInstaller.physical(root)
print("LIFECYCLE FIXTURES: \(root.path)")
func wait(_ seconds: Double, _ label: String = "lifecycle condition", _ condition: () -> Bool) throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    throw RenameError("Timed out waiting for \(label)")
}
func instances(_ app: URL) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path && !$0.isTerminated }
}
func stop(_ app: URL) throws {
    for process in instances(app) { process.terminate() }
    try wait(10) { instances(app).isEmpty }
}
func sign(_ app: URL) throws { try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path]) }
func writeJSON(_ value: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
func fixture(_ mode: String) throws {
    let dir = root.appendingPathComponent(mode)
    try fm.createDirectory(at: dir, withIntermediateDirectories: false)
    let app = dir.appendingPathComponent("Batch Rename.app", isDirectory: true)
    try fm.copyItem(at: URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATCH_RENAME_LIFECYCLE_APP"]!), to: app)
    defer { try? stop(app) }
    guard Bundle(url: app)?.bundleURL == app else { throw RenameError("Fixture app URL must retain directory semantics for install-plan identity") }
    let key = Curve25519.Signing.PrivateKey()
    let resources = app.appendingPathComponent("Contents/Resources")
    try writeJSON(["manifestURL": "https://example.invalid/manifest", "downloadURL": "https://example.invalid/download", "publicKey": key.publicKey.rawRepresentation.base64EncodedString()], resources.appendingPathComponent("UpdateConfiguration.json"))
    try writeJSON(["journal": dir.appendingPathComponent("journal/undo.json").path], resources.appendingPathComponent("LifecycleFixture.json"))
    if mode == "launch-failure" { try Data().write(to: resources.appendingPathComponent("FixtureLaunchFailure")) }
    try sign(app)
    try UpdateInstaller.run(app.appendingPathComponent("Contents/MacOS/BatchRename").path, ["--lifecycle-probe"])
    let candidate = dir.appendingPathComponent("candidate.app")
    try fm.copyItem(at: app, to: candidate)
    let info = candidate.appendingPathComponent("Contents/Info.plist")
    var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: Any]
    plist["CFBundleShortVersionString"] = "0.1.1"; plist["CFBundleVersion"] = "2"
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
    if mode == "startup-failure" {
        let bad = dir.appendingPathComponent("bad-journal.json")
        try Data("invalid journal".utf8).write(to: bad)
        try writeJSON(["journal": bad.path], candidate.appendingPathComponent("Contents/Resources/LifecycleFixture.json"))
    }
    try sign(candidate)
    let release = dir.appendingPathComponent("release")
    try UpdateInstaller.run("/usr/bin/env", ["python3", "scripts/release-update.py", candidate.path, release.path])
    var manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: release.appendingPathComponent("unsigned.json")))
    manifest.signature = try key.signature(for: manifest.signedBytes()).base64EncodedString()
    let transaction = dir.appendingPathComponent(".batch-rename-update-" + UUID().uuidString)
    try fm.createDirectory(at: transaction, withIntermediateDirectories: false)
    try fm.copyItem(at: release.appendingPathComponent(URL(fileURLWithPath: manifest.assetKey).lastPathComponent), to: transaction.appendingPathComponent("release.zip"))
    try UpdateInstaller.run("/usr/bin/open", ["-g", "-n", app.path])
    try wait(15) { instances(app).count == 1 && instances(app)[0].launchDate != nil }
    let parent = instances(app)[0]
    func report(_ pid: Int32) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("lifecycle-status/\(pid).json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    try wait(15, "fixture startup PID \(parent.processIdentifier); inspect \(dir.path)/lifecycle-status") {
        guard let status = report(parent.processIdentifier) else { return false }
        return ["ready", "view-appeared"].contains(status["phase"] as? String ?? "") &&
            status["healthy"] as? Bool == true && status["app"] as? String == app.path &&
            status["journal"] as? String == dir.appendingPathComponent("journal/undo.json").path &&
            fm.fileExists(atPath: dir.appendingPathComponent("journal/undo.json.lock").path)
    }
    if mode == "multiple-instances" {
        try UpdateInstaller.run("/usr/bin/open", ["-g", "-n", app.path])
        try wait(15) { instances(app).count == 2 }
        try wait(15, "second instance model initialization") {
            instances(app).filter { $0.processIdentifier != parent.processIdentifier }.contains {
                report($0.processIdentifier)?["healthy"] as? Bool == false
            }
        }
    }
    struct Plan: Codable { let original: URL; let transaction: URL; let manifest: UpdateManifest; let parent: Int32; let token: String; let parentLaunch: Date }
    let token = UUID().uuidString
    let plan = Plan(original: app, transaction: transaction, manifest: manifest, parent: parent.processIdentifier, token: token, parentLaunch: mode == "wrong-parent" ? parent.launchDate!.addingTimeInterval(1) : parent.launchDate!)
    let planURL = transaction.appendingPathComponent("plan.json")
    try JSONEncoder().encode(plan).write(to: planURL)
    let helper = Process(); helper.executableURL = app.appendingPathComponent("Contents/MacOS/BatchRename"); helper.arguments = ["--update-install", planURL.path]
    let log = dir.appendingPathComponent("helper.log")
    fm.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log); helper.standardOutput = output; helper.standardError = output
    try helper.run()
    defer { if helper.isRunning { helper.terminate() }; try? output.close() }
    try wait(20, "helper ready or exit; see \(log.path)") { fm.fileExists(atPath: transaction.appendingPathComponent("ready").path) || !helper.isRunning }
    if mode == "multiple-instances" || mode == "wrong-parent" {
        try wait(10) { !helper.isRunning }
        guard helper.terminationStatus != 0,
              !fm.fileExists(atPath: transaction.appendingPathComponent("ready").path),
              !fm.fileExists(atPath: transaction.appendingPathComponent("previous.app").path) else { throw RenameError("Unsafe helper authorization") }
        let reason = try String(contentsOf: log, encoding: .utf8)
        let expected = mode == "wrong-parent" ? "Parent identity could not be verified" : "Another instance of this app is running"
        guard reason.contains(expected) else { throw RenameError("Unexpected rejection; see \(log.path)") }
        print("PASS \(mode): helper refused before mutation")
        return
    }
    guard helper.isRunning else { throw RenameError("Helper refused fixture; see \(log.path)") }
    parent.terminate()
    try wait(25, "helper completion; see \(log.path)") { !helper.isRunning }
    if mode == "success" {
        guard helper.terminationStatus == 0, UpdateHealth.confirmed(at: transaction, token: token), fm.fileExists(atPath: transaction.appendingPathComponent("previous.app").path) else { throw RenameError("Success acknowledgment failed: \(log.path)") }
    } else {
        guard helper.terminationStatus != 0, fm.fileExists(atPath: transaction.appendingPathComponent("NEEDS-RECOVERY.txt").path), !UpdateHealth.confirmed(at: transaction, token: token) else { throw RenameError("Failure recovery notice missing: \(log.path)") }
        if mode == "launch-failure" {
            let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
            guard restored["CFBundleShortVersionString"] as? String == "0.1.0" else { throw RenameError("Original not restored") }
            try wait(10) { !instances(app).isEmpty }
        } else {
            guard fm.fileExists(atPath: transaction.appendingPathComponent("previous.app").path) else { throw RenameError("Startup failure lost backup") }
        }
    }
    if mode == "startup-failure" {
        try wait(10, "unhealthy candidate startup report") {
            instances(app).contains { report($0.processIdentifier)?["healthy"] as? Bool == false && report($0.processIdentifier)?["version"] as? String == "0.1.1" }
        }
    }
    print("PASS \(mode): helper exit \(helper.terminationStatus), isolated journal, background launch")
}
do {
    for mode in ["success", "launch-failure", "startup-failure", "multiple-instances", "wrong-parent"] { try fixture(mode) }
    print("PACKAGED LIFECYCLE PASSED")
} catch {
    fputs("PACKAGED LIFECYCLE BLOCKED OR FAILED: \(error.localizedDescription)\nFixtures retained: \(root.path)\n", stderr)
    exit(1)
}
