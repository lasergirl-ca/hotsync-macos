import PalmSync
import PalmSyncMac
import SwiftUI

/// Der Memo-Abgleich Mac → Palm eines Profils: ein- und ausschalten, die
/// Notizen-Ordner wählen (je einer eine Kategorie auf dem Palm). Notizen
/// gehen als reiner Text; die Freigabe ist die Automation-Erlaubnis von
/// macOS für Notizen.app.
struct MemoSyncSection: View {
    @Environment(AppState.self) var appState
    let profileId: UUID

    @State private var folders: [NoteSource.Folder] = []
    @State private var accessStatus: NoteSource.AccessStatus = .unknown
    @State private var showFolders = false
    @State private var loading = false

    private var settings: MemoSyncSettings {
        appState.deviceManager.profile(profileId)?.memoSync ?? MemoSyncSettings()
    }

    private func update(_ change: (inout MemoSyncSettings) -> Void) {
        var s = settings
        change(&s)
        appState.setMemoSync(s, for: profileId)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: Binding(get: { settings.enabled }, set: { on in update { $0.enabled = on } })) {
                        Text(L10n.memoSyncToggle)
                    }
                    Spacer()
                    Button {
                        showFolders.toggle()
                    } label: {
                        Label(L10n.memoSyncChoose, systemImage: showFolders ? "chevron.up" : "chevron.down")
                    }
                    .disabled(accessStatus != .allowed)
                }
                if settings.enabled {
                    let twoWay = appState.deviceManager.profile(profileId)?.isMemoTwoWay ?? false
                    Text(twoWay ? L10n.twoWayHintMemos : L10n.memoSyncWarning)
                        .font(.caption)
                        .foregroundStyle(twoWay ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Toggle(isOn: Binding(
                            get: { appState.deviceManager.profile(profileId)?.isMemoTwoWay ?? false },
                            set: { appState.setMemoTwoWay($0, for: profileId) }
                        )) {
                            Text(L10n.twoWayToggle)
                        }
                        if twoWay {
                            Picker(selection: Binding(get: { settings.conflicts }, set: { v in update { $0.conflictPolicy = v } })) {
                                ForEach(ConflictPolicy.allCases, id: \.self) { Text(L10n.conflictPolicyName($0)).tag($0) }
                            } label: {
                                Text(L10n.conflictPolicyLabel)
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help(L10n.conflictPolicyHelp)
                        }
                    }
                    .font(.caption)
                }

                switch accessStatus {
                case .allowed:
                    if showFolders { folderRows }
                    summary
                case .denied:
                    Text(L10n.memoSyncDenied)
                        .font(.caption)
                        .foregroundStyle(.red)
                default:
                    // noch nicht gefragt, oder Notizen.app läuft nicht: der
                    // erste Aufruf startet sie und holt die Erlaubnis
                    VStack(alignment: .leading, spacing: 4) {
                        Button(L10n.memoSyncAllow) { requestAccess() }
                            .disabled(loading)
                        Text(L10n.memoSyncAllowHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label(appState.deviceManager.profile(profileId)?.isMemoTwoWay == true ? L10n.memoSyncTitleTwoWay : L10n.memoSyncTitle,
                  systemImage: "note.text")
        }
        .onAppear {
            refreshAccess()
            if appState.memoPreview(for: profileId) == nil { appState.refreshMemoPreview(for: profileId) }
        }
    }

    private var folderRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(folders) { folder in
                Toggle(isOn: Binding(
                    get: { settings.folders.contains { $0.id == folder.id } },
                    set: { on in
                        update { s in
                            s.folders.removeAll { $0.id == folder.id }
                            if on { s.folders.append(.init(id: folder.id, title: folder.title)) }
                        }
                    }
                )) {
                    Text(folder.title)
                    Text(folder.account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(L10n.memoSyncHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        HStack {
            if settings.folders.isEmpty {
                Text(L10n.memoSyncNoFolders)
            } else {
                Text(settings.folders.map(\.title).joined(separator: ", "))
                if let preview = appState.memoPreview(for: profileId) { Text("· " + preview) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Die Erlaubnis abfragen, ohne Notizen.app zu starten; die Ordner
    /// erst, wenn sie erteilt ist (jede Abfrage ist ein Apple-Event).
    private func refreshAccess() {
        accessStatus = appState.noteSource.accessStatus
        if accessStatus == .allowed { loadFolders() }
    }

    private func loadFolders() {
        let source = appState.noteSource
        let chosen = settings.folders
        loading = true
        Task {
            let found = await Task.detached { (try? source.folders()) ?? [] }.value
            var list = found
            for choice in chosen where !list.contains(where: { $0.id == choice.id }) {
                list.append(.init(id: choice.id, title: choice.title, account: L10n.calendarGone))
            }
            folders = list
            loading = false
        }
    }

    private func requestAccess() {
        let source = appState.noteSource
        loading = true
        Task {
            let answered = await Task.detached { source.requestAccess() }.value
            loading = false
            accessStatus = answered ? .allowed : source.accessStatus
            if answered { loadFolders() }
            appState.refreshMemoPreview(for: profileId)
        }
    }
}
