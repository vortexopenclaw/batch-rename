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
        static let unreadablePresets = "PresetsUnreadable"
    }
    var recentTexts: [String] {
        get { defaults.stringArray(forKey: Key.recent) ?? [] }
        nonmutating set { defaults.set(Array(newValue.prefix(Self.recentLimit)), forKey: Key.recent) }
    }
    /// Presets decode one at a time; entries this version cannot read are kept as stored.
    var presets: [Preset] {
        get { storedPresets().valid }
        nonmutating set {
            let stored = storedPresets()
            // Never overwrite data that is not a readable list; set it aside first.
            if !stored.readable, let data = defaults.data(forKey: Key.presets) { defaults.set(data, forKey: Key.unreadablePresets) }
            let items = newValue.compactMap { preset in
                (try? JSONEncoder().encode(preset)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            } + stored.unknown
            guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
            defaults.set(data, forKey: Key.presets)
        }
    }
    private func storedPresets() -> (valid: [Preset], unknown: [Any], readable: Bool) {
        guard let data = defaults.data(forKey: Key.presets) else { return ([], [], true) }
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return ([], [], false) }
        var valid: [Preset] = [], unknown: [Any] = []
        for item in items {
            if let json = try? JSONSerialization.data(withJSONObject: item, options: .fragmentsAllowed),
               let preset = try? JSONDecoder().decode(Preset.self, from: json) { valid.append(preset) } else { unknown.append(item) }
        }
        return (valid, unknown, true)
    }
    var companions: Bool {
        get { defaults.bool(forKey: Key.companions) }
        nonmutating set { defaults.set(newValue, forKey: Key.companions) }
    }
}
