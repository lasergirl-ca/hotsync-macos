import Foundation
import Observation

/// Ein Tab: ein Palm-Profil an einem Anschluss - "m515 · USB",
/// "IIIx · cu.usbserial-A1". Derselbe Palm kann mehrere Tabs haben (einmal
/// USB, einmal seriell); die Warteschlange gehört dem Profil, nicht dem Tab.
struct SyncTab: Codable, Identifiable, Equatable {
    let id: UUID
    var profileId: UUID
    /// "usb:" oder ein serieller Callout-Pfad wie /dev/cu.usbserial-A1
    var port: String
    /// Baudrate für serielle Anschlüsse (PILOTRATE); bei USB ohne Bedeutung
    var baudRate: Int
    /// Lauscht von selbst, sobald der Anschluss frei ist - wie HotSync bis
    /// 1.0.x. Ohne: nur per Start-Knopf oder als Schritt einer Kette.
    var autoListen: Bool
    /// Von vor der Betriebsart: true/nil "Installieren + Sichern", false
    /// "Nur installieren". Bleibt in tabs.json für ältere Versionen.
    var fullSync: Bool?
    /// Was ein HotSync dieses Tabs tut; nil: wie `fullSync` sagt - ein Tab
    /// aus einer Version ohne PIM-Abgleich bleibt bei Installieren und
    /// Sichern, der Abgleich kommt erst, wenn man ihn wählt
    var mode: HotSyncMode?
    /// "An Cradle weiterreichen": der Cradle-Airlock, "host" oder
    /// "host:port" (Vorgabe Port 14238)
    var relayAddress: String?
    /// Der Secure-Transport, den der Airlock durch das Relay ausgegeben hat;
    /// ab dann geht der HotSync über TLS an diesen Port, nie mehr unverschlüsselt
    var relayTransport: RelayTransport?
    /// Ein Pair-Code für Cradle, hier getippt statt in CradleSync; der Airlock
    /// fragt ihn beim nächsten HotSync ab, danach ist er vergessen
    var relayPairCode: String?

    var hotSyncMode: HotSyncMode {
        get { mode ?? (fullSync == false ? .installOnly : .installBackup) }
        set {
            mode = newValue
            fullSync = newValue.backsUp
        }
    }

    var isFullSync: Bool { hotSyncMode.backsUp }

    init(id: UUID = UUID(), profileId: UUID, port: String, baudRate: Int = SyncTab.defaultBaudRate,
         autoListen: Bool) {
        self.id = id
        self.profileId = profileId
        self.port = port
        self.baudRate = baudRate
        self.autoListen = autoListen
    }

    static let usbPort = "usb:"
    /// Schnell genug für Installationen, und jedes serielle Cradle (ab Palm
    /// III) kann es; 115200 schaffen nicht alle Kabel/Adapter stabil.
    static let defaultBaudRate = 57600
    static let baudRates = [9600, 19200, 38400, 57600, 115200]

    /// Netzwerk-HotSync: libpisock lauscht auf TCP 14238 (NetSync), der Palm
    /// verbindet sich über WLAN mit der Adresse des "primären PCs". Der
    /// Anschluss nennt die Schnittstelle ("net:en1"); ihre Adresse wird beim
    /// Start nachgeschlagen, weil DHCP sie ändern kann. "net:any" lauscht
    /// auf allen - Ethernet und VPN eingeschlossen, darum nicht die Vorgabe.
    static let networkPrefix = "net:"
    static let networkAll = "any"
    static let networkPort = networkPrefix + networkAll
    static func networkPort(interface: String) -> String { networkPrefix + interface }
    static func isNetworkPort(_ port: String) -> Bool { port.hasPrefix(networkPrefix) }
    /// "en1", or "any"
    static func networkInterface(of port: String) -> String? {
        isNetworkPort(port) ? String(port.dropFirst(networkPrefix.count)) : nil
    }

    var isUSB: Bool { port == Self.usbPort }
    var isNetwork: Bool { Self.isNetworkPort(port) }
    var isSerial: Bool { !isUSB && !isNetwork }
    var networkInterface: String? { Self.networkInterface(of: port) }

    /// Kurzname des Anschlusses für Tab-Titel: "USB", "Wi-Fi", "cu.usbserial-A1".
    var portLabel: String {
        Self.label(port)
    }

    static func label(_ port: String) -> String {
        if port == usbPort { return "USB" }
        if let interface = networkInterface(of: port) {
            if interface == networkAll { return "Network" }
            return interface == LocalAddress.wifiInterface ? "Wi-Fi" : "Network (\(interface))"
        }
        return (port as NSString).lastPathComponent
    }
}

/// Der Secure-Transport eines Cradle-Airlocks, wie CradleSync ihn hält:
/// TLS-Port, Servername (SNI) und der SPKI-Pin seines Zertifikats (Hex).
struct RelayTransport: Codable, Equatable {
    var port: Int
    var name: String
    var pin: String

    /// die ersten acht Bytes des Pins, wie die Konsole ihn zeigt
    var shortPin: String { String(pin.prefix(16)) }
}

/// Die Betriebsart eines Tabs: welche Schritte ein HotSync macht.
/// "Abgleichen" ist der PIM-Abgleich (Kalender, Kontakte), wie im Profil
/// eingestellt; "Installieren" die Warteschlange; "Sichern" die Sicherung.
enum HotSyncMode: String, Codable, CaseIterable, Equatable {
    // in der Reihenfolge des Menüs
    case syncInstallBackup
    case installBackup
    case installOnly
    case syncOnly
    /// der ganze HotSync geht an einen Cradle-Server im Netz (LANSync):
    /// der Mac reicht nur die Pakete durch, Cradle führt die Sitzung
    case relay

    var syncs: Bool { self == .syncInstallBackup || self == .syncOnly }
    var installs: Bool { self != .syncOnly && self != .relay }
    var backsUp: Bool { self == .syncInstallBackup || self == .installBackup }
    var relays: Bool { self == .relay }
}

/// Eine Kette: Tabs, die nacheinander syncen - "wenn A fertig ist, B, dann C".
struct SyncChain: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var steps: [UUID]

    init(id: UUID = UUID(), name: String, steps: [UUID] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }
}

/// Speichert Tabs und Ketten in ~/HotSync (tabs.json, chains.json) - neben
/// profiles.json, damit alles zu einem Palm-Setup an einer Stelle liegt.
@Observable
final class TabStore {
    private(set) var tabs: [SyncTab] = []
    private(set) var chains: [SyncChain] = []

    private let tabsURL: URL
    private let chainsURL: URL
    /// Tabs aus tabs.json, die diese Version nicht lesen kann (ein Modus
    /// aus einem neueren oder anderen Build): sie bleiben, wie sie sind,
    /// und werden beim Speichern unverändert zurückgeschrieben, damit ein
    /// älterer Build sie nicht verliert.
    private var foreignTabs: [[String: Any]] = []
    /// tabs.json war da, ließ sich aber gar nicht lesen: dann wird nichts
    /// gespeichert, sonst überschriebe eine leere Liste die Datei.
    private var tabsUnreadable = false

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("HotSync")
        tabsURL = dir.appendingPathComponent("tabs.json")
        chainsURL = dir.appendingPathComponent("chains.json")
        loadTabs()
        chains = load(chainsURL) ?? []
    }

    /// Liest tabs.json Tab für Tab: was sich lesen lässt, ist ein Tab; was
    /// nicht, bleibt als Rohdaten erhalten (siehe `foreignTabs`).
    private func loadTabs() {
        guard let data = try? Data(contentsOf: tabsURL) else { return }
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            DebugLog.shared.log(L10n.logLoadError("tabs.json: not a list of tabs; nothing will be saved to it"), source: "App")
            tabsUnreadable = true
            return
        }
        var read: [SyncTab] = []
        for entry in list {
            do {
                let one = try JSONSerialization.data(withJSONObject: entry)
                read.append(try JSONDecoder().decode(SyncTab.self, from: one))
            } catch {
                foreignTabs.append(entry)
                DebugLog.shared.log(L10n.logTabKept(entry["id"] as? String ?? "?", "\(error)"), source: "App")
            }
        }
        tabs = read
    }

    /// true, wenn es noch keine tabs.json gibt (erster Start von 1.1).
    var isFirstRun: Bool {
        !FileManager.default.fileExists(atPath: tabsURL.path)
    }

    /// Bis 1.0.x lauschte HotSync für das aktive Profil an USB. Jedes Profil
    /// bekommt deshalb einen USB-Tab, der wie bisher von selbst lauscht.
    func migrate(profiles: [DeviceProfile]) {
        guard isFirstRun else { return }
        tabs = profiles.map { SyncTab(profileId: $0.id, port: SyncTab.usbPort, autoListen: true) }
        saveTabs()
        DebugLog.shared.log(L10n.logTabsMigrated(tabs.count), source: "App")
    }

    func tab(_ id: UUID) -> SyncTab? {
        tabs.first { $0.id == id }
    }

    func chain(_ id: UUID) -> SyncChain? {
        chains.first { $0.id == id }
    }

    func save(_ tab: SyncTab) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        saveTabs()
    }

    /// Löscht einen Tab und nimmt ihn aus allen Ketten.
    func deleteTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        saveTabs()
        removeFromChains { $0 == id }
    }

    /// Ein Profil wurde gelöscht: seine Tabs verschwinden mit.
    func deleteTabs(ofProfile profileId: UUID) {
        let ids = Set(tabs.filter { $0.profileId == profileId }.map(\.id))
        guard !ids.isEmpty else { return }
        tabs.removeAll { ids.contains($0.id) }
        saveTabs()
        removeFromChains { ids.contains($0) }
    }

    func save(_ chain: SyncChain) {
        if let index = chains.firstIndex(where: { $0.id == chain.id }) {
            chains[index] = chain
        } else {
            chains.append(chain)
        }
        saveChains()
    }

    func deleteChain(_ id: UUID) {
        chains.removeAll { $0.id == id }
        saveChains()
    }

    private func removeFromChains(where shouldRemove: (UUID) -> Bool) {
        var changed = false
        for index in chains.indices {
            let before = chains[index].steps.count
            chains[index].steps.removeAll(where: shouldRemove)
            changed = changed || chains[index].steps.count != before
        }
        if changed { saveChains() }
    }

    // MARK: - Dateien

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            DebugLog.shared.log(L10n.logLoadError("\(url.lastPathComponent): \(error)"), source: "App")
            return nil
        }
    }

    private func saveTabs() {
        guard !tabsUnreadable else {
            DebugLog.shared.log(L10n.logSaveError("tabs.json: left as it is, it could not be read at start"), source: "App")
            return
        }
        guard !foreignTabs.isEmpty else {
            write(tabs, to: tabsURL)
            return
        }
        // die eigenen Tabs als JSON, die fremden unverändert dahinter
        do {
            let encoded = try JSONEncoder().encode(tabs)
            let own = (try JSONSerialization.jsonObject(with: encoded)) as? [[String: Any]] ?? []
            let data = try JSONSerialization.data(withJSONObject: own + foreignTabs, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: tabsURL, options: .atomic)
        } catch {
            DebugLog.shared.log(L10n.logSaveError("tabs.json: \(error)"), source: "App")
        }
    }
    private func saveChains() { write(chains, to: chainsURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            DebugLog.shared.log(L10n.logSaveError("\(url.lastPathComponent): \(error)"), source: "App")
        }
    }
}
