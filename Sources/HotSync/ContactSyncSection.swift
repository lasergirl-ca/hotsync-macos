import Contacts
import PalmSyncMac
import SwiftUI

/// Der Kontakte-Abgleich Mac → Palm eines Profils: ein- und ausschalten,
/// die Konten wählen; die Gruppen werden Kategorien auf dem Palm.
struct ContactSyncSection: View {
    @Environment(AppState.self) var appState
    let profileId: UUID

    @State private var containers: [ContactSource.Container] = []
    @State private var accessStatus: CNAuthorizationStatus = .notDetermined
    @State private var showContainers = false

    private var settings: ContactSyncSettings {
        appState.deviceManager.profile(profileId)?.contactSync ?? ContactSyncSettings()
    }

    private func update(_ change: (inout ContactSyncSettings) -> Void) {
        var s = settings
        change(&s)
        appState.setContactSync(s, for: profileId)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: Binding(get: { settings.enabled }, set: { on in update { $0.enabled = on } })) {
                        Text(L10n.contactSyncToggle)
                    }
                    Spacer()
                    Button {
                        showContainers.toggle()
                    } label: {
                        Label(L10n.contactSyncChoose, systemImage: showContainers ? "chevron.up" : "chevron.down")
                    }
                    .disabled(accessStatus != .authorized)
                }
                if settings.enabled {
                    Text(L10n.contactSyncWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                switch accessStatus {
                case .authorized:
                    if showContainers { containerList }
                    summary
                case .denied, .restricted:
                    Text(L10n.contactSyncDenied)
                        .font(.caption)
                        .foregroundStyle(.red)
                default:
                    Button(L10n.contactSyncAllow) { requestAccess() }
                }
            }
            .padding(4)
        } label: {
            Label(L10n.contactSyncTitle, systemImage: "person.crop.circle")
        }
        .onAppear { refreshAccess() }
    }

    private var containerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(containers) { container in
                Toggle(isOn: Binding(
                    get: { settings.containers.contains { $0.id == container.id } },
                    set: { on in
                        update { s in
                            s.containers.removeAll { $0.id == container.id }
                            if on { s.containers.append(.init(id: container.id, title: container.title)) }
                        }
                    }
                )) {
                    Text(container.title)
                    Text(container.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(L10n.contactSyncGroupsHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        HStack {
            if settings.containers.isEmpty {
                Text(L10n.contactSyncNoContainers)
            } else {
                Text(settings.containers.map(\.title).joined(separator: ", "))
                if let preview = appState.contactPreview(for: profileId) { Text("· " + preview) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func refreshAccess() {
        accessStatus = appState.contactSource.accessStatus
        if accessStatus == .authorized {
            containers = appState.contactSource.containers()
            for choice in settings.containers where !containers.contains(where: { $0.id == choice.id }) {
                containers.append(.init(id: choice.id, title: choice.title, kind: L10n.calendarGone))
            }
        }
    }

    private func requestAccess() {
        Task {
            _ = try? await appState.contactSource.requestAccess()
            refreshAccess()
            appState.refreshContactPreview(for: profileId)
        }
    }
}
