import AppKit
import QuietHostsCore
import SwiftUI

/// Lazily rendered search results with keyboard selection.
struct SearchResultsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let rows = model.rows
        Group {
            if model.isLoadingLists && model.index.count == 0 {
                placeholder(symbol: nil, title: "Loading lists…", message: nil)
            } else if rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                                rowView(row, selected: model.selection == offset)
                                    .id(row.id)
                                    .onTapGesture { model.selection = offset }
                            }
                            footer
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selection) { _, new in
                        guard let new, rows.indices.contains(new) else { return }
                        proxy.scrollTo(rows[new].id)
                    }
                }
            }
        }
        .frame(height: 312)
    }

    @ViewBuilder
    private func rowView(_ row: AppModel.SearchRow, selected: Bool) -> some View {
        switch row {
        case .add(let host):
            AddRow(host: host, selected: selected) { model.addWebsite(host) }
        case .hit(let hit):
            ResultRow(model: model, hit: hit, selected: selected)
        }
    }

    @ViewBuilder private var footer: some View {
        let o = model.outcome
        if o.hits.isEmpty, let host = o.hostnameQuery {
            VStack(spacing: 4) {
                Text(verbatim: "\(host) isn’t in any list or rule.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Press Return or click above to block it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 70)
            .padding(.horizontal, 24)
        } else if o.total > o.hits.count {
            Text("Showing \(o.hits.count.formatted()) of \(o.total.formatted()) matches. Keep typing to narrow the list.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
        } else if o.hits.count > 6 {
            Text("\(o.total.formatted()) matches")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if Hostname.normalize(searchQuery: model.query) == nil {
            placeholder(symbol: "character.cursor.ibeam", title: "Not a domain name",
                        message: "Search with letters, numbers, dots and hyphens.")
        } else if model.index.count == 0 && model.rules.blocked.isEmpty {
            placeholder(symbol: "tray", title: "No lists downloaded yet",
                        message: "Turn on a blocklist to search its domains.")
        } else {
            placeholder(symbol: "magnifyingglass", title: "No blocked domains match “\(model.query)”",
                        message: "Nothing in your lists or rules contains this text.")
        }
    }

    private func placeholder(symbol: String?, title: String, message: String?) -> some View {
        VStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SelectionBackground: View {
    let selected: Bool
    let hovering: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.045 : 0))
            .padding(.horizontal, 6)
    }
}

private struct AddRow: View {
    let host: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Block \(host)")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Hostname.wwwTwin(of: host).map { "Also blocks \($0)" } ?? "Not in any enabled list")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SelectionBackground(selected: selected, hovering: hovering))
        .onHover { hovering = $0 }
    }
}

private struct ResultRow: View {
    @Bindable var model: AppModel
    let hit: SearchHit
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let state = model.state(of: hit)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HighlightedDomain(domain: hit.domain, range: hit.matchRange)
                detailLine(state)
            }
            Spacer(minLength: 8)
            StateBadge(state: state, pending: model.pending(hit.domain)) {
                model.toggle(hit.domain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .background(SelectionBackground(selected: selected, hovering: hovering))
        .onHover { hovering = $0 }
        .contextMenu { menu(state) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: state == .blocked ? "Allow" : "Block") { model.toggle(hit.domain) }
    }

    @ViewBuilder
    private func detailLine(_ state: DomainState) -> some View {
        if let check = model.resolverChecks[hit.domain] {
            HStack(spacing: 4) {
                if let check {
                    Image(systemName: check == .blocked ? "checkmark.shield" : "network")
                    Text(check.summary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Checking system resolver…")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text(sourceText(state))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func sourceText(_ state: DomainState) -> String {
        let names = model.sourceNames(for: hit.domain, mask: hit.sourceMask)
        var text = names.joined(separator: " · ")
        if state == .inactive {
            let off = model.disabledSourceNames(for: hit.sourceMask)
            if !off.isEmpty && model.rules.blocked[hit.domain]?.enabled != false { text += " (off)" }
            else if model.rules.blocked[hit.domain]?.enabled == false { text += " (turned off)" }
        }
        return text
    }

    @ViewBuilder
    private func menu(_ state: DomainState) -> some View {
        if state == .blocked {
            Button("Allow \(hit.domain)") { model.allow(hit.domain) }
            let subs = model.blockedSubdomainCount(of: hit.domain)
            if subs > 0 {
                Button("Allow with \(subs) Known Subdomain\(subs == 1 ? "" : "s")") {
                    model.allow(hit.domain, includingSubdomains: true)
                }
            }
        } else {
            Button("Block \(hit.domain)") { model.block(hit.domain) }
        }
        Divider()
        Button("Check in System Resolver") { model.checkResolution(hit.domain) }
        Button("Copy Domain") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hit.domain, forType: .string)
        }
        if model.rules.blocked[hit.domain] != nil {
            Divider()
            Button("Remove from My Blocked Sites") { model.removeWebsite(hit.domain) }
        }
    }
}

// MARK: Add website

struct AddWebsiteView: View {
    @Bindable var model: AppModel
    @State private var input = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Block a Website")
                .font(.system(size: 13, weight: .semibold))
            TextField("example.com or a link", text: $input)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: input) { error = nil }
            Group {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(hint)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.addingWebsite = false }
                    .keyboardShortcut(.cancelAction)
                Button("Block", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var hint: String {
        if case .success(let host) = Hostname.normalize(userInput: input), let twin = Hostname.wwwTwin(of: host) {
            return "Blocks \(host) and \(twin). Other subdomains, such as m.\(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host), need to be added separately."
        }
        return "Type a domain or paste a link. QuietHosts blocks the name and its www. form; the hosts file can’t block every subdomain automatically."
    }

    private func submit() {
        switch model.addWebsite(input) {
        case .success(let host):
            model.addingWebsite = false
            model.query = host
            input = ""
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}
