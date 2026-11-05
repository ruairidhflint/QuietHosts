import AppKit
import SwiftUI

/// A native search field that forwards navigation keys to the result list:
/// ↑/↓ move the selection, Return (or Space on a selected row) acts on it, and
/// Esc clears the field (or closes the popover when already empty).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Changing this value moves keyboard focus into the field.
    var focusToken: Int
    var hasSelection: Bool
    var onMove: (Int) -> Void
    var onActivate: () -> Void
    var onEscapeWhenEmpty: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        (field.cell as? NSSearchFieldCell)?.maximumRecents = 0
        field.setAccessibilityLabel("Search domains")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var lastFocusToken = -1

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            var value = field.stringValue
            // Space acts on the selected row (hostnames never contain spaces).
            if value.hasSuffix(" ") && parent.hasSelection {
                value.removeLast()
                field.stringValue = value
                parent.onActivate()
            }
            if parent.text != value { parent.text = value }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onActivate(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.text.isEmpty { parent.onEscapeWhenEmpty() } else { parent.text = "" }
                return true
            default:
                return false
            }
        }
    }
}
