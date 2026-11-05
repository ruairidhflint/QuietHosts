import AppKit
import QuietHostsCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ManageState {
    var tab: ManageTab = .lists
}

struct ManageView: View {
    @Bindable var model: AppModel
    @Bindable var state: ManageState

    var body: some View {
        TabView(selection: $state.tab) {
            ListsTab(model: model)
                .tabItem { Label("Blocklists", systemImage: "list.bullet.rectangle") }
                .tag(ManageTab.lists)
            MySitesTab(model: model)
                .tabItem { Label("My Sites", systemImage: "hand.raised") }
                .tag(ManageTab.sites)
            ExceptionsTab(model: model)
                .tabItem { Label("Exceptions", systemImage: "checkmark.shield") }
                .tag(ManageTab.exceptions)
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(ManageTab.general)
        }
        .padding(16)
        .frame(minWidth: 620, idealWidth: 660, minHeight: 470, idealHeight: 540)
    }
}

// MARK: Blocklists

private struct ListsTab: View {
    @Bindable var model: AppModel
    @State private var showingURLSheet = false
    @State private var importError: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(model.settings.sources) { source in
                    SourceDetailRow(model: model, source: source)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.visible)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Menu("Add List") {
                    Button("From a Web Address…") { showingURLSheet = true }
                    Button("From a File…") { importFile() }
                }
                .fixedSize()
                .disabled(importing)
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Update weekly", isOn: Binding(get: { model.settings.weeklyUpdates },
                                                     set: { model.setWeeklyUpdates($0) }))
                    .help("Once a week, download newer versions of enabled lists while QuietHosts is running.")
                Button("Update All Now") { Task { await model.refreshAll() } }
                    .disabled(!model.refreshing.isEmpty)
            }
            Text("Lists are downloaded only when you turn them on, update them, or during the weekly check. Your exceptions and blocked sites are stored separately and are never changed by list updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingURLSheet) {
            AddURLSheet(model: model)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Blocklist"
        panel.message = "Choose a hosts file or a text file with one domain per line."
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = nil
        importing = true
        Task {
            defer { importing = false }
            do {
                try await model.addSource(origin: .file(path: url.path), name: nil)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

private struct SourceDetailRow: View {
    @Bindable var model: AppModel
    let source: SourceDefinition
    @State private var editingName = false
    @State private var name = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(source.name, isOn: Binding(get: { source.enabled }, set: { model.setSource(source.id, enabled: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if editingName {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.renameSource(source.id, to: name); editingName = false }
                        .frame(maxWidth: 260)
                } else {
                    Text(source.name).font(.body.weight(.medium))
                }
                if !source.detail.isEmpty {
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                statusLine
            }
            Spacer()
            if model.refreshing.contains(source.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh(source.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(source.isRemote ? "Download the latest version" : "Re-read the file")
            }
            if !source.builtIn {
                Menu {
                    Button("Rename…") { name = source.name; editingName = true }
                    Button("Remove List", role: .destructive) { model.removeSource(source.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 4) {
            if let count = source.domainCount, source.hasData {
                Text("\(count.formatted()) domains")
            }
            if let updated = source.lastUpdated {
                Text("·")
                Text("Updated \(updated.relativeDescription)")
            } else if !model.refreshing.contains(source.id) {
                Text(source.enabled ? "Not downloaded yet" : "Downloads when turned on")
            }
            Text("·")
            Text(source.originDescription)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if let error = source.lastError {
            Label(source.hasData ? "Last update failed: \(error) The previous version is still in use." : error,
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AddURLSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var name = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Blocklist from the Web").font(.headline)
            Text(verbatim: "Use an https:// address that serves a hosts file (0.0.0.0 example.com) or a plain list of domains. Adblock-style filter lists aren’t supported.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Address", text: $urlText, prompt: Text("https://example.com/hosts.txt"))
                TextField("Name", text: $name, prompt: Text("Optional"))
            }
            .formStyle(.columns)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Downloading and checking…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func add() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)), url.host() != nil else {
            error = "Enter a full web address beginning with https://."
            return
        }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await model.addSource(origin: .remote(url), name: name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: My sites

private struct MySitesTab: View {
    @Bindable var model: AppModel
    @State private var input = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a website, such as example.com", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: input) { error = nil }
                Button("Block", action: add)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            let sites = model.customSites
            if sites.isEmpty {
                ContentUnavailableView("No Blocked Sites", systemImage: "hand.raised",
                                       description: Text("Websites you add appear here. They stay blocked whichever lists are turned on."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(sites, id: \.domain) { site in
                        HStack(spacing: 12) {
                            Toggle(site.domain, isOn: Binding(get: { site.block.enabled },
                                                              set: { model.setWebsite(site.domain, enabled: $0) }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.domain)
                                    .foregroundStyle(site.block.enabled ? .primary : .secondary)
                                Text(caption(site))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isPending(site.domain) { ProgressView().controlSize(.small) }
                            Button {
                                model.removeWebsite(site.domain)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(site.domain)")
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(verbatim: "The hosts file blocks exact names. Adding a site blocks both example.com and www.example.com; other subdomains such as m.example.com must be added separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ site: (domain: String, block: RuleSet.Block, alsoWWW: Bool)) -> String {
        var parts: [String] = []
        if site.alsoWWW, let twin = Hostname.wwwTwin(of: site.domain) { parts.append("Also \(twin)") }
        parts.append("Added \(site.block.added.formatted(date: .abbreviated, time: .omitted))")
        if !site.block.enabled { parts.append("Off") }
        return parts.joined(separator: " · ")
    }

    private func add() {
        switch model.addWebsite(input) {
        case .success: input = ""
        case .failure(let e): error = e.localizedDescription
        }
    }
}

// MARK: Exceptions

private struct ExceptionsTab: View {
    @Bindable var model: AppModel
    @State private var filter = ""

    var body: some View {
        let all = model.rules.allowed.sorted { $0.key < $1.key }
        let shown = filter.isEmpty ? all : all.filter { $0.key.contains(filter.lowercased()) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Exceptions override every blocklist and are kept when lists update.")
                    .foregroundStyle(.secondary)
                Spacer()
                if all.count > 8 {
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            .font(.callout)
            if all.isEmpty {
                ContentUnavailableView("No Exceptions", systemImage: "checkmark.shield",
                                       description: Text("Search for a blocked site in the menu bar and click Allow. It will appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(shown, id: \.key) { domain, allow in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(domain)
                                Text(caption(domain, allow))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isPending(domain) { ProgressView().controlSize(.small) }
                            Button("Block Again") { model.removeException(domain) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func caption(_ domain: String, _ allow: RuleSet.Allow) -> String {
        let names = model.settings.sources.filter { model.index.mask(of: domain) & $0.mask != 0 }.map(\.name)
        let listed = names.isEmpty ? "No longer in any list" : "Listed in " + names.joined(separator: ", ")
        return listed + " · Allowed " + allow.added.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: General

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Block websites", isOn: Binding(get: { model.settings.protectionEnabled },
                                                      set: { model.setProtection($0) }))
                LabeledContent("Status") { StatusLine(model: model) }
                LabeledContent("Hosts file") { Text(hostsSummary).foregroundStyle(.secondary) }
            } header: {
                Text("Protection")
            } footer: {
                Text("Blocking stays in effect when QuietHosts isn’t running and after you restart your Mac. Turn protection off here to remove QuietHosts’ entries.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Helper") {
                LabeledContent("Privileged helper") { Text(helperSummary).foregroundStyle(.secondary) }
                HStack {
                    if model.helper.status == .notRegistered {
                        Button("Set Up Helper…") { model.helper.install() }
                    }
                    Button("Open Login Items Settings") { model.helper.openSystemSettings() }
                    Button("Reinstall Helper") { Task { await model.helper.reinstall() } }
                }
                if let error = model.helper.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Startup and Updates") {
                Toggle("Open QuietHosts at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do {
                        try LaunchAtLogin.set(on)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    launchAtLogin = LaunchAtLogin.isEnabled
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Toggle("Update blocklists weekly", isOn: Binding(get: { model.settings.weeklyUpdates },
                                                                set: { model.setWeeklyUpdates($0) }))
            }

            Section {
                HStack {
                    Button("Remove All QuietHosts Entries") { model.removeAllEntries() }
                        .disabled(!model.helper.isReady)
                    Button("Show Backups in Finder") {
                        let url = URL(fileURLWithPath: HostsFileWriter.Configuration.system.backupDirectory)
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Library/Application Support"))
                        }
                    }
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text(verbatim: "Removing entries turns protection off and deletes only the lines QuietHosts added to /etc/hosts. Your own entries are kept. Before changing the file, QuietHosts saves a copy of the original and of every distinct version of your own entries in /Library/Application Support/QuietHosts/Backups.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("How blocking works") {
                VStack(alignment: .leading, spacing: 8) {
                    explanation("QuietHosts adds 0.0.0.0 and :: entries to /etc/hosts, so normal macOS name lookups for blocked sites fail in every browser, including private windows. All decisions happen on your Mac.")
                    explanation("The hosts file blocks exact names, not wildcards: blocking example.com doesn’t block m.example.com unless that name is listed too.")
                    explanation("It can’t stop VPNs, proxies, apps with their own DNS, or DNS-over-HTTPS settings that skip the system resolver. Firefox with DNS over HTTPS only re-reads the hosts file when it restarts.")
                    explanation("Browsers keep open connections and cache lookups for about a minute. If a site still loads after a change, close its tabs or restart the browser.")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Your DNS") {
                let servers = UpstreamFilterDetector.currentServers()
                LabeledContent("Current resolvers") {
                    Text(servers.isEmpty ? "Unknown" : servers.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let filter = model.upstreamFilter {
                    Label("\(filter.provider) is filtering DNS on this network.", systemImage: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
                Text(verbatim: "Exceptions in QuietHosts only override QuietHosts’ own lists. If your DNS provider also filters adult sites (for example Cloudflare for Families at 1.1.1.3), sites it blocks stay blocked. For full control over exceptions, use a non-filtering resolver such as Cloudflare 1.1.1.1 or the malware-only 1.1.1.2. QuietHosts never changes your DNS settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func explanation(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }

    private var hostsSummary: String {
        switch model.hostsVerified {
        case .some(true):
            if !model.settings.protectionEnabled { return "No QuietHosts entries · verified" }
            return "\(model.blockedCount.formatted()) domains · verified by checksum"
        case .some(false): return "Doesn’t match your current rules yet"
        case .none: return "Not checked yet"
        }
    }

    private var helperSummary: String {
        switch model.helper.status {
        case .enabled: "Installed and allowed"
        case .requiresApproval: "Waiting for approval in System Settings"
        case .notRegistered: "Not set up"
        case .notFound: "Missing from the app bundle"
        }
    }
}
