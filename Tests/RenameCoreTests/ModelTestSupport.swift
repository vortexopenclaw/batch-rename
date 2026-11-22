#if DIRECT_UI_TESTS
import XCTest
import Foundation

/// Waits until the model has no file operation in flight and its preview is validated.
@MainActor func waitForIdle(_ model: Model?, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if model?.isIdle ?? true { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Model did not become idle", file: file, line: line)
}

extension XCTestCase {
    /// A private defaults suite, removed when the test ends.
    func scratchDefaults() -> UserDefaults {
        let name = "BatchRenameTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    @MainActor func makeModel(_ journal: URL, defaults: UserDefaults? = nil) -> Model {
        Model(journalURL: journal, defaults: defaults ?? scratchDefaults())
    }
}
#endif
