import Foundation
@preconcurrency import RenameCore

/// A saved set of rename settings, applied in one click.
struct Preset: Codable, Equatable, Identifiable {
    var name: String
    var action: Action
    var scope: Scope
    var text: String
    var search: String
    var ignoreCase: Bool
    /// `Occurrences` raw value. Unknown values fall back to all occurrences.
    var occurrences: String
    var skipExistingSuffix: Bool
    var sequenceStart: Int
    var id: String { name }
    init(name: String, operation: RenameOperation) {
        self.name = name
        action = operation.action; scope = operation.scope; text = operation.text; search = operation.search
        ignoreCase = operation.ignoreCase; occurrences = operation.occurrences.rawValue
        skipExistingSuffix = operation.skipExistingSuffix; sequenceStart = operation.sequenceStart
    }
    var operation: RenameOperation {
        var op = RenameOperation()
        op.action = action; op.scope = scope; op.text = text; op.search = search
        op.ignoreCase = ignoreCase; op.occurrences = Occurrences(rawValue: occurrences) ?? .all
        op.skipExistingSuffix = skipExistingSuffix; op.sequenceStart = sequenceStart
        return op
    }
}

/// Persisted app preferences. Tests inject a private `UserDefaults` suite.
struct SettingsStore {
    static let recentLimit = 10
    let defaults: UserDefaults
    private enum Key {
        static let recent = "RecentTexts", presets = "Presets", companions = "IncludeCompanionFiles"
    }
    var recentTexts: [String] {
        get { defaults.stringArray(forKey: Key.recent) ?? [] }
        nonmutating set { defaults.set(Array(newValue.prefix(Self.recentLimit)), forKey: Key.recent) }
    }
    var presets: [Preset] {
        get { defaults.data(forKey: Key.presets).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? [] }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.presets) }
    }
    var companions: Bool {
        get { defaults.bool(forKey: Key.companions) }
        nonmutating set { defaults.set(newValue, forKey: Key.companions) }
    }
}
