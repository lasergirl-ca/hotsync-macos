import EventKit
import PalmSyncMac
import SwiftUI

/// Der Aufgaben-Abgleich Mac → Palm eines Profils: ein- und ausschalten,
/// die Erinnerungslisten wählen (je eine eine Kategorie auf dem Palm), wie
/// lange erledigte Aufgaben auf dem Palm bleiben.
struct TaskSyncSection: View {
    @Environment(AppState.self) var appState
    let profileId: UUID

    @State private var lists: [ReminderSource.List] = []
    @State private var accessStatus: EKAuthorizationStatus = .notDetermined
    @State private var showLists = false

    private var settings: TaskSyncSettings {
        appState.deviceManager.profile(profileId)?.taskSync ?? TaskSyncSettings()
    }

    private func update(_ change: (inout TaskSyncSettings) -> Void) {
        var s = settings
        change(&s)
        appState.setTaskSync(s, for: profileId)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: Binding(get: { settings.enabled }, set: { on in update { $0.enabled = on } })) {
                        Text(L10n.taskSyncToggle)
                    }
                    Spacer()
                    Button {
                        showLists.toggle()
                    } label: {
                        Label(L10n.taskSyncChoose, systemImage: showLists ? "chevron.up" : "chevron.down")
                    }
                    .disabled(accessStatus != .fullAccess)
                }
                if settings.enabled {
                    Text(L10n.taskSyncWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                switch accessStatus {
                case .fullAccess:
                    if showLists { listRows }
                    summary
                case .denied, .restricted, .writeOnly:
                    Text(L10n.taskSyncDenied)
                        .font(.caption)
                        .foregroundStyle(.red)
                default:
                    Button(L10n.taskSyncAllow) { requestAccess() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label(L10n.taskSyncTitle, systemImage: "checklist")
        }
        .onAppear {
            refreshAccess()
            if appState.taskPreview(for: profileId) == nil { appState.refreshTaskPreview(for: profileId) }
        }
    }

    private var listRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lists) { list in
                Toggle(isOn: Binding(
                    get: { settings.lists.contains { $0.id == list.id } },
                    set: { on in
                        update { s in
                            s.lists.removeAll { $0.id == list.id }
                            if on { s.lists.append(.init(id: list.id, title: list.title)) }
                        }
                    }
                )) {
                    Text(list.title)
                    Text(list.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(L10n.taskSyncHint)
                Stepper(value: Binding(get: { settings.keepCompletedDays }, set: { v in update { $0.keepCompletedDays = v } }),
                        in: 0...365, step: 5) {
                    Text(L10n.taskSyncDays(settings.keepCompletedDays))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        HStack {
            if settings.lists.isEmpty {
                Text(L10n.taskSyncNoLists)
            } else {
                Text(settings.lists.map(\.title).joined(separator: ", "))
                if let preview = appState.taskPreview(for: profileId) { Text("· " + preview) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func refreshAccess() {
        accessStatus = appState.reminderSource.accessStatus
        if accessStatus == .fullAccess {
            lists = appState.reminderSource.lists()
            for choice in settings.lists where !lists.contains(where: { $0.id == choice.id }) {
                lists.append(.init(id: choice.id, title: choice.title, source: L10n.calendarGone))
            }
        }
    }

    private func requestAccess() {
        Task {
            _ = try? await appState.reminderSource.requestAccess()
            refreshAccess()
            appState.refreshTaskPreview(for: profileId)
        }
    }
}
