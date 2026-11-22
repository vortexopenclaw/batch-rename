import SwiftUI
import AppKit

struct AppCommands: Commands {
    @ObservedObject var model: Model
    @ObservedObject var updater: AppUpdater
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.check() }.disabled(updater.busy || model.busy)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Files or Folders…") { model.choose() }.keyboardShortcut("o")
        }
        // Cmd+Z undoes text edits while a field is being edited or a sheet is open, otherwise the last batch.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { EditRouting.undo(model) }.keyboardShortcut("z")
            Button("Redo") { EditRouting.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            Button("Undo Last Batch") { model.undo() }
                .disabled(model.controlsLocked || !model.undoAvailable)
                .help(model.undoHelp)
        }
    }
}

@MainActor enum EditRouting {
    /// The key window's first responder is a field editor (a text field is being edited).
    static var editingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return responder.isFieldEditor
    }
    /// A sheet (such as History) is attached to the key window, or is the key window.
    static var sheetOpen: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return window.attachedSheet != nil || window.sheetParent != nil
    }
    static func undo(_ model: Model) {
        switch UndoRouting.undo(editingText: editingText, sheetOpen: sheetOpen, batchAvailable: model.undoAvailable, locked: model.controlsLocked) {
        case .text: NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case .batch: model.undo()
        case .none: NSSound.beep()
        }
    }
    static func redo() {
        switch UndoRouting.redo(editingText: editingText) {
        case .text: NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        case .batch, .none: NSSound.beep()
        }
    }
}
