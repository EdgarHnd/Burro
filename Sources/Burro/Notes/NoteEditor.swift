// The note editor: a native text view over the note's plain text. `- [ ] ` / `- [x] ` marks are
// hidden and drawn as checkboxes you can click; Return continues a list, Return on an empty item
// ends it, and ⌫ right after a mark removes it. Undo, find, spelling and copy are AppKit's own.
import AppKit
import SwiftUI

enum NoteEditorStyle {
    static var font: NSFont { .systemFont(ofSize: 15) }
    static let checkboxWidth: CGFloat = 26
    /// Butter gold, a little deeper in light mode so the rings read on a pale background.
    static var box: NSColor { NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.80, blue: 0.30, alpha: 1)
            : NSColor(srgbRed: 0.86, green: 0.60, blue: 0.08, alpha: 1)
    } }
    static var check: NSColor { NSColor(srgbRed: 0.16, green: 0.13, blue: 0.08, alpha: 1) }

    static var baseParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 6
        style.minimumLineHeight = 20
        return style
    }
    static var base: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraph]
    }

    /// Applies list and heading styling to the paragraphs in `range`.
    static func style(_ storage: NSTextStorage, in range: NSRange) {
        let string = storage.string as NSString
        let paragraphs = string.paragraphRange(for: range)
        storage.setAttributes(base, range: paragraphs)
        string.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            let (kind, prefix) = NoteText.lineKind(in: string, paragraph: paragraph)
            guard prefix > 0, paragraph.length >= prefix else { return }
            let mark = NSRange(location: paragraph.location, length: prefix)
            let rest = NSRange(location: paragraph.location + prefix, length: paragraph.length - prefix)
            switch kind {
            case .checklist(let done):
                let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                style.headIndent = checkboxWidth
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                // The mark stays in the text (so copy and undo are plain) but takes no room except
                // the checkbox's, which the layout manager draws in the kerned gap.
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 1), .foregroundColor: NSColor.clear], range: mark)
                storage.addAttribute(.kern, value: checkboxWidth - 2, range: NSRange(location: mark.location + prefix - 1, length: 1))
                if done, rest.length > 0 {
                    storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .foregroundColor: NSColor.secondaryLabelColor], range: rest)
                }
            case .bullet:
                let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                style.headIndent = 14
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: mark)
            case .heading(let level):
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 12)], range: mark)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: [22, 18, 16][min(level, 3) - 1], weight: .bold), range: rest)
            case .text:
                break
            }
        }
    }
}

/// Draws a checkbox in front of every checklist item.
final class ChecklistLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let string = storage.string as NSString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        string.enumerateSubstrings(in: string.paragraphRange(for: characters), options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            guard case .checklist(let done) = NoteText.lineKind(in: string, paragraph: paragraph).kind,
                  let rect = self.checkboxRect(paragraph: paragraph, origin: origin) else { return }
            Self.drawBox(in: rect, done: done)
        }
    }

    func checkboxRect(paragraph: NSRange, origin: NSPoint) -> NSRect? {
        guard paragraph.length >= 6, numberOfGlyphs > 0 else { return nil }
        let first = glyphIndexForCharacter(at: paragraph.location)
        guard first < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: first, effectiveRange: nil)
        let probe = glyphIndexForCharacter(at: paragraph.location + min(paragraph.length - 1, 6))
        let baseline = line.minY + location(forGlyphAt: min(probe, numberOfGlyphs - 1)).y
        let size: CGFloat = 16
        return NSRect(x: origin.x + line.minX + 1, y: origin.y + baseline - 13, width: size, height: size)
    }

    static func drawBox(in rect: NSRect, done: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
        NoteEditorStyle.box.set()
        if done {
            box.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 4.2, y: rect.minY + 8.3))
            check.line(to: NSPoint(x: rect.minX + 7, y: rect.minY + 11.2))
            check.line(to: NSPoint(x: rect.minX + 11.9, y: rect.minY + 5))
            check.lineWidth = 1.9
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NoteEditorStyle.check.setStroke()
            check.stroke()
        } else {
            box.lineWidth = 1.6
            box.stroke()
        }
    }
}

final class NoteTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let paragraph = checkbox(at: point) { toggleCheckbox(paragraph); return }
        super.mouseDown(with: event)
    }

    func checkbox(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager as? ChecklistLayoutManager else { return nil }
        let string = self.string as NSString
        let paragraph = NoteText.paragraph(in: string, at: characterIndexForInsertion(at: point))
        guard case .checklist = NoteText.lineKind(in: string, paragraph: paragraph).kind,
              let rect = layout.checkboxRect(paragraph: paragraph, origin: textContainerOrigin),
              rect.insetBy(dx: -5, dy: -4).contains(point) else { return nil }
        return paragraph
    }

    func toggleCheckbox(_ paragraph: NSRange) {
        let mark = NSRange(location: paragraph.location + 3, length: 1)
        let done = (string as NSString).substring(with: mark) != " "
        replace(mark, with: done ? " " : "x")
    }

    /// An undoable edit, as if typed.
    func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    /// ⇧⌘L: the selected lines become checklist items, or plain text when they all are.
    func toggleChecklist() {
        let (text, selection) = NoteText.toggleChecklist(string, selection: selectedRange())
        replace(NSRange(location: 0, length: (string as NSString).length), with: text)
        setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length),
                                 length: min(selection.length, max(0, (text as NSString).length - selection.location))))
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }
}

/// SwiftUI host for the editor. The note's text loads when `noteID` changes; after that the
/// text view is the source of truth and reports edits through `onChange`.
struct NoteEditor: NSViewRepresentable {
    var noteID: UUID?
    var text: String
    var onChange: (String) -> Void
    var onEscape: () -> Void
    var register: (NoteTextView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = ChecklistLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = NoteTextView(frame: .zero, textContainer: container)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.typingAttributes = NoteEditorStyle.base
        view.insertionPointColor = NoteEditorStyle.box
        view.delegate = context.coordinator
        storage.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        register(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NoteTextView, context.coordinator.noteID != noteID else { return }
        context.coordinator.noteID = noteID
        view.string = text
        view.undoManager?.removeAllActions()
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.typingAttributes = NoteEditorStyle.base
        view.scrollRangeToVisible(view.selectedRange())
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: NoteEditor
        var noteID: UUID?
        init(_ parent: NoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onChange(view.string)
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            NoteEditorStyle.style(storage, in: range)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NSTextView)?.typingAttributes = NoteEditorStyle.base
        }

        /// Keeps the caret out of a hidden checklist mark.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            guard new.length == 0 else { return new }
            let string = textView.string as NSString
            let paragraph = NoteText.paragraph(in: string, at: new.location)
            let (kind, prefix) = NoteText.lineKind(in: string, paragraph: paragraph)
            guard case .checklist = kind, new.location < paragraph.location + prefix else { return new }
            let end = paragraph.location + prefix
            if new.location < old.location, old.location == end, paragraph.location > 0 {
                return NSRange(location: paragraph.location - 1, length: 0)
            }
            return NSRange(location: end, length: 0)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let view = textView as? NoteTextView else { return false }
            let string = view.string as NSString
            let selection = view.selectedRange()
            let paragraph = NoteText.paragraph(in: string, at: selection.location)
            let (kind, prefix) = NoteText.lineKind(in: string, paragraph: paragraph)
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard prefix > 0, kind != .text, selection.length == 0 else { return false }
                if case .heading = kind { return false }
                if paragraph.length <= prefix {
                    // Return on an empty item ends the list.
                    view.replace(paragraph, with: "")
                    return true
                }
                let next = kind == .bullet ? string.substring(with: NSRange(location: paragraph.location, length: prefix)) : NoteText.unchecked
                view.insertText("\n" + next, replacementRange: selection)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard prefix > 0, selection.length == 0, selection.location == paragraph.location + prefix else { return false }
                view.replace(NSRange(location: paragraph.location, length: prefix), with: "")
                return true
            default:
                return false
            }
        }
    }
}
