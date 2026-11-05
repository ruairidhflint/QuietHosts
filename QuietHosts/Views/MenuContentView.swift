import QuietHostsCore
import SwiftUI

enum ManageTab: Hashable {
    case lists, sites, exceptions, general
}

/// Actions the popover asks its host (the app delegate) to perform.
struct MenuActions {
    var openManage: (ManageTab) -> Void = { _ in }
    var close: () -> Void = {}
    var quit: () -> Void = {}
}

struct MenuContentView: View {
    @Bindable var model: AppModel
    var focusToken: Int
    var actions: MenuActions

    @State private var localFocusToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            NoticeArea(model: model, actions: actions)

            if model.addingWebsite {
                Divider()
                AddWebsiteView(model: model)
            } else {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                Divider()
                if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    BlocklistSection(model: model, actions: actions)
                } else {
                    SearchResultsView(model: model)
                }
            }

            Divider()
            FooterView(model: model, actions: actions)
        }
        .frame(width: 360)
        .background {
            // ⌘F focuses search from anywhere in the popover.
            Button("") {
                model.addingWebsite = false
                localFocusToken += 1
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
    }

    private var searchField: some View {
        SearchField(
            text: $model.query,
            placeholder: "Search \(model.index.count > 0 ? model.index.count.formatted() + " " : "")domains",
            focusToken: focusToken + localFocusToken,
            hasSelection: model.selection != nil,
            onMove: { model.moveSelection($0) },
            onActivate: { model.activateSelection() },
            onEscapeWhenEmpty: actions.close
        )
        .frame(height: 28)
        .overlay(alignment: .trailing) {
            if model.query.isEmpty {
                Text("⌘F")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: Header

private struct HeaderView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: BrandMark.image(size: 24))
                .renderingMode(.template)
                .foregroundStyle(model.settings.protectionEnabled ? BrandMark.teal : Color.secondary)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("QuietHosts")
                    .font(.system(size: 13, weight: .semibold))
                StatusLine(model: model)
            }
            Spacer()
            Toggle("Protection", isOn: Binding(
                get: { model.settings.protectionEnabled },
                set: { model.setProtection($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(model.settings.protectionEnabled ? "Turn blocking off" : "Turn blocking on")
            .accessibilityLabel("Protection")
        }
    }
}

struct StatusLine: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            indicator
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var indicator: some View {
        switch model.health {
        case .loading, .applying:
            ProgressView().controlSize(.mini).frame(width: 9, height: 9)
        case .active:
            StatusDot(color: .green)
        case .off:
            StatusDot(color: .secondary.opacity(0.6))
        case .needsSetup, .attention, .externallyEdited:
            StatusDot(color: .orange)
        }
    }

    private var text: String {
        switch model.health {
        case .loading: "Loading lists…"
        case .applying: "Applying changes…"
        case .active:
            model.blockedCount == 0 ? "Active · no domains blocked yet"
                : "Active · \(model.blockedCount.formatted()) domains blocked"
        case .off: "Off · nothing is blocked"
        case .needsSetup: "Setup required"
        case .attention: "Changes not applied"
        case .externallyEdited: "Hosts file was edited elsewhere"
        }
    }
}

// MARK: Notices

private struct NoticeArea: View {
    @Bindable var model: AppModel
    var actions: MenuActions

    var body: some View {
        VStack(spacing: 8) {
            switch model.health {
            case .needsSetup:
                setupBanner
            case .attention(let message):
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Changes weren’t applied", message: message) {
                    Button("Try Again") { model.requestApply() }
                }
            case .externallyEdited:
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: "The QuietHosts section was changed",
                       message: "Another app or a manual edit changed the QuietHosts lines in /etc/hosts. Replace them with your current rules?") {
                    Button("Replace") { model.overwriteExternalEdits() }
                }
            default:
                EmptyView()
            }
            if let filter = model.upstreamFilter, model.health != .needsSetup {
                Banner(symbol: "info.circle.fill", tint: .blue,
                       title: "\(filter.provider) is filtering DNS",
                       message: "Sites it blocks stay blocked even if you allow them here.") {
                    Button("Learn More") { actions.openManage(.general) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, hasNotice ? 10 : 0)
    }

    private var hasNotice: Bool {
        switch model.health {
        case .needsSetup, .attention, .externallyEdited: return true
        default: return model.upstreamFilter != nil
        }
    }

    @ViewBuilder private var setupBanner: some View {
        switch model.helper.status {
        case .requiresApproval:
            Banner(symbol: "lock.fill", tint: .orange,
                   title: "Approve QuietHosts in System Settings",
                   message: "Turn on QuietHosts under General › Login Items & Extensions. You’ll only need to do this once.") {
                Button("Open System Settings") { model.helper.openSystemSettings() }
            }
        case .notFound:
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   title: "Helper missing",
                   message: "The helper wasn’t found inside the app. Reinstall QuietHosts in your Applications folder.")
        default:
            Banner(symbol: "lock.fill", tint: .accentColor,
                   title: "One-time setup",
                   message: model.helper.lastError ?? "QuietHosts uses a small helper to update /etc/hosts. macOS will ask you to allow it once.") {
                Button("Set Up…") { model.helper.install() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: Blocklists

private struct BlocklistSection: View {
    @Bindable var model: AppModel
    var actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Blocklists")
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(model.settings.sources) { source in
                SourceRow(model: model, source: source)
            }
            Button {
                actions.openManage(.sites)
            } label: {
                HStack {
                    Text("My blocked sites")
                        .font(.system(size: 13))
                    Spacer()
                    Text(model.customSiteCount == 0 ? "None" : "\(model.customSiteCount) site\(model.customSiteCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .help("Websites you’ve added yourself. These stay blocked regardless of the lists above.")
        }
        .padding(.bottom, 6)
    }
}

private struct SourceRow: View {
    @Bindable var model: AppModel
    let source: SourceDefinition

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.system(size: 13))
                    .foregroundStyle(source.enabled ? .primary : .secondary)
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(source.lastError != nil && !source.hasData && !model.refreshing.contains(source.id) ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.refreshing.contains(source.id) {
                ProgressView().controlSize(.small)
            } else if let count = source.domainCount, source.hasData {
                Text(count.formatted())
                    .font(.system(size: 12))
                    .foregroundStyle(source.enabled ? .secondary : .tertiary)
                    .monospacedDigit()
            }
            Toggle(source.name, isOn: Binding(
                get: { source.enabled },
                set: { model.setSource(source.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .help(source.detail)
    }

    private var note: String? {
        if model.refreshing.contains(source.id) { return source.hasData ? "Updating…" : "Downloading…" }
        if let error = source.lastError, !source.hasData, source.enabled { return error }
        return nil
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : (hovering ? 0.05 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: Footer

private struct FooterView: View {
    @Bindable var model: AppModel
    var actions: MenuActions

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.addingWebsite = true
            } label: {
                Label("Add Website", systemImage: "plus")
            }
            .disabled(model.addingWebsite)
            Spacer()
            Button("Manage Lists…") { actions.openManage(.lists) }
            Menu {
                Button("Settings…") { actions.openManage(.general) }
                Button("Update Lists Now") { Task { await model.refreshAll() } }
                Divider()
                Section("Blocking stays on after quitting") {
                    Button("Quit QuietHosts") { actions.quit() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}
