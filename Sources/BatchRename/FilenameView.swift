import AppKit
import SwiftUI
import RenameCore

/// Native selectable, copyable, unwrapped text. Each cell can also be scrolled
/// manually; edits reveal the first affected segment without moving input focus.
struct FilenameView: NSViewRepresentable {
    let name: String
    let ranges: [NSRange]
    let deletion: Bool
    let operation: RenameOperation

    func makeNSView(context: Context) -> FilenameScrollView {
        let scroll = FilenameScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 30)
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: FilenameScrollView, context: Context) {
        let value = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        for range in ranges where range.length > 0 && NSMaxRange(range) <= value.length {
            value.addAttribute(.backgroundColor, value: NSColor.systemBlue.withAlphaComponent(0.25), range: range)
            if deletion { value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        let text = scroll.documentView as! NSTextView
        let reveal = RenamePresentation.revealRange(in: name, changes: ranges)
        if text.attributedString() != value || scroll.reveal != reveal || scroll.operation != operation {
            text.textStorage?.setAttributedString(value)
            text.toolTip = name
            text.setAccessibilityLabel(name)
            scroll.operation = operation
            scroll.reveal = reveal
            scroll.needsReveal = true
            scroll.needsLayout = true
        }
    }
}
final class FilenameScrollView: NSScrollView {
    var operation: RenameOperation?
    var reveal = NSRange(location: 0, length: 0)
    var needsReveal = true
    private var lastWidth: CGFloat = 0
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, let manager = text.layoutManager, let container = text.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        text.setFrameSize(NSSize(width: max(contentSize.width, ceil(used.width) + 4), height: max(26, contentSize.height)))
        if needsReveal || lastWidth != contentSize.width {
            needsReveal = false
            lastWidth = contentSize.width
            text.scrollRangeToVisible(reveal)
        }
    }
}
