import QuietHostsCore
import SwiftUI

/// The per-domain control: shows the current state and, on hover, the action
/// a click will take ("Blocked" → "Allow"). Fixed width so rows never jump.
struct StateBadge: View {
    let state: DomainState
    var pending: AppModel.Pending = .none
    let action: () -> Void

    @State private var hovering = false

    private var showsAction: Bool { hovering && pending != .applying }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if pending == .applying {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else if pending == .notApplied && !showsAction {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(symbolTint)
                }
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(textTint)
            .frame(width: 78, height: 22)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(Text(stateLabel))
        .accessibilityHint(Text(actionLabel))
    }

    /// Blocked is the normal state, so it stays neutral; exceptions are the
    /// thing worth noticing and get colour. Hover previews the action.
    private var displayed: DomainState { showsAction ? (state == .blocked ? .allowed : .blocked) : state }

    private var symbolTint: Color {
        switch displayed {
        case .blocked: .red
        case .allowed: .green
        case .inactive, .unrestricted: .secondary
        }
    }

    private var textTint: Color {
        switch displayed {
        case .blocked: showsAction ? .red : Color.primary.opacity(0.8)
        case .allowed: .green
        case .inactive, .unrestricted: .secondary
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        switch displayed {
        case .blocked:
            shape.fill(showsAction ? Color.red.opacity(0.14) : Color.primary.opacity(0.07))
        case .allowed:
            shape.fill(Color.green.opacity(showsAction ? 0.2 : 0.14))
        case .inactive, .unrestricted:
            shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        }
    }

    private var label: String { showsAction ? actionLabel : stateLabel }

    private var stateLabel: String {
        switch state {
        case .blocked: "Blocked"
        case .allowed: "Allowed"
        case .inactive: "List off"
        case .unrestricted: "Not blocked"
        }
    }

    private var actionLabel: String { state == .blocked ? "Allow" : "Block" }

    private var symbol: String {
        if showsAction { return state == .blocked ? "checkmark" : "nosign" }
        switch state {
        case .blocked: return "nosign"
        case .allowed: return "checkmark"
        case .inactive, .unrestricted: return "minus"
        }
    }

    private var helpText: String {
        if pending == .notApplied { return "This change hasn’t reached the hosts file yet" }
        return switch state {
        case .blocked: "Click to allow this site"
        case .allowed: "Allowed by your exception. Click to block it again"
        case .inactive: "Only in lists that are turned off. Click to block it anyway"
        case .unrestricted: "Click to block this site"
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// A compact, quiet callout used for setup and problems.
struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if let message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) { actions() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

extension Banner where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, message: String?) {
        self.init(symbol: symbol, tint: tint, title: title, message: message) { EmptyView() }
    }
}

/// Small-caps section label in the style of macOS sidebars.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// Renders a domain with the matched part emphasised.
struct HighlightedDomain: View {
    let domain: String
    let range: Range<Int>?

    var body: some View {
        Text(attributed)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var attributed: AttributedString {
        var s = AttributedString(domain)
        s.foregroundColor = .secondary
        guard let range, range.upperBound <= domain.utf8.count else {
            s.foregroundColor = .primary
            return s
        }
        let start = s.index(s.startIndex, offsetByCharacters: range.lowerBound)
        let end = s.index(s.startIndex, offsetByCharacters: range.upperBound)
        s[start..<end].foregroundColor = .primary
        s[start..<end].font = .system(size: 13, weight: .semibold)
        // Keep the rest of the hostname readable, only slightly quieter.
        s[s.startIndex..<start].foregroundColor = Color.primary.opacity(0.75)
        s[end..<s.endIndex].foregroundColor = Color.primary.opacity(0.75)
        return s
    }
}

extension Date {
    var relativeDescription: String {
        if Date().timeIntervalSince(self) < 60 { return "just now" }
        return formatted(.relative(presentation: .named))
    }
}
