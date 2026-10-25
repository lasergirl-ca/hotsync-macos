import AppKit
import Foundation
import HotSyncCore
import Observation
import PalmSync
import PalmSyncMac

/// Steuert alle Sitzungen: welche Tabs an welchem Anschluss lauschen, welcher
/// Palm zu welchem Tab gehört, und den Ablauf der Ketten.
///
/// Regeln:
/// - An einem Anschluss läuft immer höchstens EIN hotsync-session - zwei
///   Prozesse an usb: würden sich um denselben Palm streiten. Verschiedene
///   Anschlüsse (USB, jeder serielle Adapter) laufen unabhängig.
/// - Ein Anschluss mit Tabs "automatisch lauschen" hat einen Listener, der
///   jeden Palm annimmt und ihn anhand der User-ID dem passenden Tab gibt.
/// - Ein von Hand oder von einer Kette gestarteter Tab lauscht gezielt: ein
///   anderer Palm bekommt nichts installiert. Er hat Vorrang vor dem Listener.
@Observable
final class AppState {
    let deviceManager = DeviceManager()
    let tabStore = TabStore()
    /// Calendar.app und Contacts.app für den Abgleich; je eine Instanz, sie halten die Freigabe
    let calendarSource = CalendarSource()
    let contactSource = ContactSource()
    let reminderSource = ReminderSource()
    let portMonitor = PortMonitor()

    private(set) var queues: [UUID: InstallQueue] = [:]
    private(set) var statuses: [UUID: TabStatus] = [:]
    private(set) var notices: [PortNotice] = []
    /// Der offene Dialog "Neuer Palm" (höchstens einer zur Zeit)
    var newPalmPrompt: NewPalmPrompt?
    /// Holt das Fenster nach vorn, wenn HotSync etwas fragen muss
    @ObservationIgnored var onAttentionNeeded: (() -> Void)?
    private(set) var activeChain: ActiveChain?

    var selectedTabId: UUID?
    var showSetup = false
    var showDeviceList = false
    var showChains = false

    struct ActiveChain: Equatable {
        let chainId: UUID
        var run: ChainRun
    }

    // Sprachumschaltung - gespeichert und beobachtet in LanguageSetting
    var language: Language {
        get { L10n.language }
        set { L10n.language = newValue }
    }

    /// Wartezeit eines Kettenschritts auf den Palm, danach hält die Kette an.
    static let chainStepTimeout = 300
    /// Nach einer Sitzung braucht der Palm etwas, bis er den USB-Bus verlässt;
    /// ein sofort neu startender Listener würde ihn sonst noch einmal greifen.
    private static let palmDisconnectDelay: TimeInterval = 3
    /// Startet das Werkzeug an einem Anschluss gar nicht erst (z. B. serieller
    /// Port belegt), nicht im Sekundentakt neu versuchen.
    private static let errorRetryDelay: TimeInterval = 10

    @ObservationIgnored private var watchers: [UUID: FileWatcher] = [:]
    @ObservationIgnored private var sessions: [String: Session] = [:]
    /// Tabs, die gezielt syncen sollen und auf ihren Anschluss warten (FIFO)
    @ObservationIgnored private var pendingStarts: [UUID] = []
    @ObservationIgnored private var restartWork: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var nextToken = 0

    // MARK: - Start

    func setup() {
        DebugLog.shared.log(L10n.logSetupStarted, source: "App")
        deviceManager.migrateFromLegacy()
        tabStore.migrate(profiles: deviceManager.profiles)

        for profile in deviceManager.profiles {
            makeQueue(for: profile)
        }
        for tab in tabStore.tabs {
            statuses[tab.id] = TabStatus()
        }
        selectedTabId = tabStore.tabs.first?.id
        showSetup = !deviceManager.hasProfiles

        portMonitor.onChange = { [weak self] in self?.scheduleAll() }
        portMonitor.start()
        scheduleAll()
    }

    /// Beim Beenden: kein hotsync-session darf weiterlaufen.
    func shutdown() {
        for session in sessions.values {
            session.stopRequested = true
            session.runner.kill()
        }
    }

    // MARK: - Abfragen für die Views

    func queue(for tab: SyncTab) -> InstallQueue? {
        queues[tab.profileId]
    }

    func status(_ tabId: UUID) -> TabStatus? {
        statuses[tabId]
    }

    func title(of tab: SyncTab) -> String {
        let name = deviceManager.profile(tab.profileId)?.username ?? "?"
        return "\(name) · \(tab.portLabel)"
    }

    func profileName(_ id: UUID) -> String {
        deviceManager.profile(id)?.username ?? "?"
    }

    /// Für die Menüleiste: synct gerade irgendein Tab?
    var syncingTab: SyncTab? {
        tabStore.tabs.first { statuses[$0.id]?.isSyncing == true }
    }

    var isListening: Bool {
        statuses.values.contains { if case .listening = $0.phase { return true } else { return false } }
    }

    // MARK: - Tabs von Hand

    /// Syncen gezielt mit diesem Tab: nur sein Palm bekommt etwas installiert.
    func startTab(_ id: UUID) {
        requestStart(id)
    }

    func stopTab(_ id: UUID) {
        if pendingStarts.contains(id) {
            pendingStarts.removeAll { $0 == id }
            statuses[id]?.phase = .idle
            statuses[id]?.lastResult = .stopped(date: Date())
            failChainStep(id, reason: L10n.chainStepStopped)
            return
        }
        if let session = sessions.values.first(where: { $0.tabId == id }) {
            session.stopRequested = true
            session.runner.kill()
        }
    }

    /// Läuft für diesen Tab gerade eine gezielte Sitzung (oder wartet sie)?
    func isStarted(_ id: UUID) -> Bool {
        pendingStarts.contains(id) || sessions.values.contains {
            if case .tab(let tabId, _) = $0.purpose { return tabId == id }
            return false
        }
    }

    func saveTab(_ tab: SyncTab) {
        tabStore.save(tab)
        if statuses[tab.id] == nil {
            statuses[tab.id] = TabStatus()
        }
        restartIdleListeners()
    }

    func deleteTab(_ id: UUID) {
        stopTab(id)
        pendingStarts.removeAll { $0 == id }
        tabStore.deleteTab(id)
        statuses[id] = nil
        if selectedTabId == id {
            selectedTabId = tabStore.tabs.first?.id
        }
        restartIdleListeners()
    }

    // MARK: - Profile

    /// Neues Profil ohne Palm (User-ID 0) mit einem Tab: Der erste Palm
    /// ohne Benutzer, der in diesem Tab synct, übernimmt den Namen - ein
    /// schon benutzter Palm lässt sich danach zuordnen.
    @discardableResult
    func addProfile(name: String, note: String?, port: String = SyncTab.usbPort) -> DeviceProfile {
        let profile = deviceManager.addProfile(username: name, userId: 0, deviceNote: note)
        makeQueue(for: profile)
        let tab = SyncTab(profileId: profile.id, port: port, autoListen: true)
        saveTab(tab)
        selectedTabId = tab.id
        showSetup = false
        return profile
    }

    /// Dialog "Neuer Palm", "Anlegen": Der Palm wird ein Profil unter `name`.
    /// Ist er noch verbunden, geht es in derselben Sitzung weiter - ein Palm
    /// ohne Benutzer bekommt dort die Identität des Profils geschrieben (nur
    /// so ist sicher, dass es genau dieser Palm ist), ein umbenannter seinen
    /// neuen Namen; dann wird installiert. Ohne Verbindung (nur ein Palm mit
    /// Benutzer) bleibt sein Name.
    func createDevice(for prompt: NewPalmPrompt, name: String) {
        newPalmPrompt = nil
        let session = waitingSession(for: prompt)
        session?.awaitingDecision = false

        if !prompt.user.isBlank {
            var user = prompt.user
            // umbenannt: neuer Name auf den Palm, die ID bleibt
            if let session, !name.isEmpty, name != user.name {
                user = PalmUser(name: name, userId: user.userId)
                session.runner.send("setuser \(user.userId) \(name)")
            }
            let profile = createProfile(from: user, port: prompt.port)
            if let session { install(profile.id, user: user, session: session) }
        } else if let session {
            let profile = addProfile(name: name, note: nil, port: prompt.port)
            adopt(profile.id, session: session)
        }
    }

    /// Dialog "Neuer Palm", "übernehmen": Der Palm ist ein Gerät, das HotSync
    /// schon kennt - etwa nach einem Hard Reset. Er bekommt in derselben
    /// Sitzung Name und ID dieses Profils zurück, dann dessen Warteschlange.
    /// `restore`: in derselben Sitzung auch die Sicherung des Geräts zurück -
    /// der Palm nach einem Datenverlust (leere Batterien, Hard Reset).
    func takeOverDevice(for prompt: NewPalmPrompt, profileId: UUID, restore: Bool) {
        newPalmPrompt = nil
        guard let session = waitingSession(for: prompt) else { return }
        session.awaitingDecision = false
        requestRestore(restore, for: profileId)
        // install() sucht den Tab des Profils unter den Auto-Tabs des Anschlusses
        if !autoTabs(on: prompt.port).contains(where: { $0.profileId == profileId }) {
            saveTab(SyncTab(profileId: profileId, port: prompt.port, autoListen: true))
        }
        adopt(profileId, session: session)
    }

    /// Das Gerät, dessen Name `name` ist (ohne Rücksicht auf Groß-/Kleinschreibung).
    func profile(named name: String) -> DeviceProfile? {
        deviceManager.profiles.first { $0.username.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Dialog "Neuer Palm", "Ignorieren": Die Sitzung endet ohne
    /// Installation, der Hinweis oben im Fenster bleibt.
    func ignoreNewPalm(_ prompt: NewPalmPrompt) {
        newPalmPrompt = nil
        guard let session = waitingSession(for: prompt), let user = session.user else { return }
        session.awaitingDecision = false
        notify(PortNotice(port: prompt.port, kind: user.isBlank ? .blank : .unknown(user), date: Date()))
        endWithoutInstall(session, user: user)
    }

    /// Die Sitzung, in der der Palm des Dialogs noch auf die Antwort wartet.
    private func waitingSession(for prompt: NewPalmPrompt) -> Session? {
        guard let token = prompt.sessionToken, let session = sessions[prompt.port],
              session.token == token, session.awaitingDecision else { return nil }
        return session
    }

    /// Ein Palm, der keinem Tab gehört: fragen, ob er ein neues Gerät wird.
    /// Die Sitzung bleibt offen, bis der Benutzer antwortet (das Werkzeug
    /// hält den Palm so lange wach). Steht schon ein Dialog, endet sie.
    private func promptNewPalm(_ user: PalmUser, session: Session) {
        let port = session.runner.port
        guard newPalmPrompt == nil else {
            notify(PortNotice(port: port, kind: user.isBlank ? .blank : .unknown(user), date: Date()))
            endWithoutInstall(session, user: user)
            return
        }
        session.awaitingDecision = true
        newPalmPrompt = NewPalmPrompt(port: port, user: user, sessionToken: session.token)
        onAttentionNeeded?()
    }

    /// Ein unbekannter Palm wird ein neues Profil, mit Tab an dem Anschluss,
    /// an dem er sich gemeldet hat.
    @discardableResult
    func createProfile(from user: PalmUser, port: String) -> DeviceProfile {
        let name = user.name.isEmpty ? "Palm" : user.name
        let profile = deviceManager.addProfile(username: name, userId: UInt(user.userId), deviceNote: nil)
        makeQueue(for: profile)
        let tab = SyncTab(profileId: profile.id, port: port, autoListen: true)
        saveTab(tab)
        selectedTabId = tab.id
        forget(user)
        return profile
    }

    /// Ordnet einem Profil einen Palm zu: ab dem nächsten HotSync erkennt
    /// HotSync ihn an seiner User-ID.
    func assign(_ user: PalmUser, to profileId: UUID) {
        deviceManager.assignIdentity(user, to: profileId)
        forget(user)
    }

    func deleteProfile(_ profile: DeviceProfile) {
        for tab in tabStore.tabs where tab.profileId == profile.id {
            stopTab(tab.id)
            statuses[tab.id] = nil
            pendingStarts.removeAll { $0 == tab.id }
        }
        tabStore.deleteTabs(ofProfile: profile.id)
        watchers[profile.id]?.stop()
        watchers[profile.id] = nil
        queues[profile.id] = nil
        deviceManager.deleteProfile(profile)
        if let selected = selectedTabId, tabStore.tab(selected) == nil {
            selectedTabId = tabStore.tabs.first?.id
        }
        showSetup = !deviceManager.hasProfiles
        restartIdleListeners()
    }

    func dismissNotice(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    func clearResult(_ tabId: UUID) {
        statuses[tabId]?.lastResult = nil
        statuses[tabId]?.lastBackup = nil
        statuses[tabId]?.lastRestore = nil
        statuses[tabId]?.lastROMDump = nil
    }

    // MARK: - Sicherung

    /// Profile, deren Sicherung beim nächsten HotSync auf den Palm
    /// zurückgeht (vor den Installationen). Gilt, bis das geschehen ist
    /// oder die App endet.
    private(set) var restoreRequests: Set<UUID> = []

    /// Profile, deren ROM beim nächsten HotSync ausgelesen wird (zum Schluss)
    private(set) var romRequests: Set<UUID> = []

    func requestROMDump(_ dump: Bool, for profileId: UUID) {
        if dump { romRequests.insert(profileId) } else { romRequests.remove(profileId) }
    }

    func requestRestore(_ restore: Bool, for profileId: UUID) {
        if restore { restoreRequests.insert(profileId) } else { restoreRequests.remove(profileId) }
    }

    func setMode(_ mode: HotSyncMode, for tabId: UUID) {
        guard var tab = tabStore.tab(tabId), tab.hotSyncMode != mode else { return }
        tab.hotSyncMode = mode
        saveTab(tab)
    }

    func setModeForAllTabs(_ mode: HotSyncMode) {
        for var tab in tabStore.tabs where tab.hotSyncMode != mode {
            tab.hotSyncMode = mode
            tabStore.save(tab)
        }
    }

    /// Datenbanken in der Sicherung - gezählt, nicht geprüft (das tut erst
    /// das Zurückspielen); für die Anzeige
    func backupCount(for profileId: UUID) -> Int {
        guard let profile = deviceManager.profile(profileId),
              let names = try? FileManager.default.contentsOfDirectory(
                atPath: deviceManager.backupDirectory(for: profile).path) else { return 0 }
        return names.filter { PalmDatabaseFile.supportedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.count
    }

    /// Die Datenbanken einer Sicherung, in der Reihenfolge zum Zurückspielen
    func backupFiles(for profileId: UUID) -> [URL] {
        guard let profile = deviceManager.profile(profileId) else { return [] }
        let dir = deviceManager.backupDirectory(for: profile)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var byName: [String: URL] = [:]
        var items: [RestoreOrder.Item] = []
        for url in urls {
            // nur fertig gesicherte Datenbanken, keine .part einer abgebrochenen
            guard case .success(let db) = PalmDatabaseFile.inspect(url: url) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            byName[url.lastPathComponent] = url
            items.append(RestoreOrder.Item(name: url.lastPathComponent, type: db.type,
                                           creator: db.creator, size: size))
        }
        return RestoreOrder.sorted(items).compactMap { byName[$0.name] }
    }

    /// Hinweise und Ablehnungen zu einem Palm, der jetzt zugeordnet ist.
    private func forget(_ user: PalmUser) {
        notices.removeAll { if case .unknown(let u) = $0.kind { return u == user } else { return false } }
        for status in statuses.values {
            if case .rejected(_, let rejection) = status.lastResult {
                switch rejection {
                case .unknown(let u) where u == user, .wrongPalm(let u, _) where u == user:
                    status.lastResult = nil
                default:
                    break
                }
            }
        }
    }

    // MARK: - Ketten

    func runChain(_ id: UUID) {
        guard activeChain == nil, let chain = tabStore.chain(id), !chain.steps.isEmpty else { return }
        activeChain = ActiveChain(chainId: id, run: ChainRun(steps: chain.steps))
        DebugLog.shared.log(L10n.logChainStarted(chain.name), source: "Chain")
        continueChain()
    }

    func retryChainStep() {
        activeChain?.run.retry()
        continueChain()
    }

    func skipChainStep() {
        activeChain?.run.skip()
        continueChain()
    }

    func cancelChain() {
        guard let tab = activeChain?.run.currentTab else {
            activeChain = nil
            return
        }
        activeChain?.run.cancel()
        stopTab(tab)
        continueChain()
    }

    private func continueChain() {
        guard let active = activeChain, let chain = tabStore.chain(active.chainId) else {
            activeChain = nil
            return
        }
        switch active.run.state {
        case .running:
            if let tab = active.run.currentTab, !isStarted(tab) {
                requestStart(tab)
            }
        case .paused:
            break
        case .finished:
            DebugLog.shared.log(L10n.logChainFinished(chain.name), source: "Chain")
            NotificationManager.shared.send(title: L10n.chainFinishedTitle,
                                            body: L10n.chainFinishedBody(chain.name, active.run.skipped.count))
            activeChain = nil
        case .cancelled:
            DebugLog.shared.log(L10n.logChainCancelled(chain.name), source: "Chain")
            activeChain = nil
        }
    }

    private func isChainStep(_ tabId: UUID) -> Bool {
        guard let run = activeChain?.run, case .running = run.state else { return false }
        return run.currentTab == tabId
    }

    private func failChainStep(_ tabId: UUID, reason: String) {
        guard isChainStep(tabId) else { return }
        activeChain?.run.stepFailed(reason: reason)
        continueChain()
    }

    // MARK: - Warteschlangen

    private func makeQueue(for profile: DeviceProfile) {
        deviceManager.ensureProfileDirectories(profile)
        let queue = InstallQueue(installDir: deviceManager.installDirectory(for: profile),
                                 installedDir: deviceManager.installedDirectory(for: profile))
        queues[profile.id] = queue
        let watcher = FileWatcher(path: queue.installDir.path)
        watcher.start { [weak queue] in queue?.refresh() }
        watchers[profile.id] = watcher
    }

    /// Verschiebt Dateien in die Warteschlange eines anderen Profils.
    func move(_ items: [InstallQueue.QueueItem], from source: InstallQueue, to profileId: UUID) {
        guard let target = queues[profileId] else { return }
        source.move(items, to: target)
    }

    /// Auf einen Reiter gezogene Dateien: Eine Datei aus einer anderen
    /// Warteschlange wandert in die des Reiters - mit allen dort
    /// ausgewählten, wenn sie dazugehört. Alle anderen werden hineinkopiert.
    func drop(_ urls: [URL], on tab: SyncTab) {
        guard let target = queues[tab.profileId] else { return }
        for url in urls {
            if let source = queues.values.first(where: { $0.holds(url) }),
               let item = source.items.first(where: { $0.name == url.lastPathComponent }) {
                source.move(source.targets(for: item), to: target)
            } else {
                target.add([url])
            }
        }
    }

    // MARK: - Anschlüsse verteilen

    private func requestStart(_ id: UUID) {
        guard let tab = tabStore.tab(id) else {
            failChainStep(id, reason: L10n.chainStepMissingTab)
            return
        }
        guard !isStarted(id) else { return }
        pendingStarts.append(id)
        statuses[id]?.phase = .waitingForPort

        if let session = sessions[tab.port] {
            // Ein Listener ohne Palm macht Platz; eine laufende Übertragung
            // wird zu Ende gebracht.
            if case .listener = session.purpose, !session.connected {
                session.stopRequested = true
                session.runner.kill()
            }
        } else {
            restartWork[tab.port]?.cancel()
            restartWork[tab.port] = nil
            schedule(tab.port)
        }
    }

    /// Listener ohne Palm neu starten, damit geänderte Tabs (Anschluss,
    /// Baudrate, automatisch lauschen) gelten.
    private func restartIdleListeners() {
        for session in sessions.values {
            if case .listener = session.purpose, !session.connected {
                session.stopRequested = true
                session.runner.kill()
            }
        }
        scheduleAll()
    }

    private func scheduleAll() {
        for port in Set(tabStore.tabs.map(\.port)) {
            schedule(port)
        }
        // Tabs, deren serieller Anschluss gerade fehlt
        for tab in tabStore.tabs where !portMonitor.isConnected(tab.port) {
            if case .listening = statuses[tab.id]?.phase {
                statuses[tab.id]?.phase = .idle
            }
        }
    }

    private func schedule(_ port: String) {
        guard sessions[port] == nil, restartWork[port] == nil, portMonitor.isConnected(port) else { return }
        if let tabId = pendingStarts.first(where: { tabStore.tab($0)?.port == port }),
           let tab = tabStore.tab(tabId) {
            pendingStarts.removeAll { $0 == tabId }
            launch(.tab(tabId, chain: isChainStep(tabId)), on: port, baudRate: tab.baudRate)
        } else if let tab = tabStore.tabs.first(where: { $0.port == port && $0.autoListen }) {
            launch(.listener, on: port, baudRate: tab.baudRate)
        }
    }

    private func scheduleRestart(_ port: String, after delay: TimeInterval) {
        guard delay > 0 else {
            schedule(port)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.restartWork[port] = nil
            self?.schedule(port)
        }
        restartWork[port] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Die Auto-Tabs eines Anschlusses - ihr Listener nimmt jeden ihrer Palms.
    private func autoTabs(on port: String) -> [SyncTab] {
        tabStore.tabs.filter { $0.port == port && $0.autoListen }
    }

    // MARK: - Sitzungen

    private final class Session {
        enum Purpose: Equatable {
            /// gezielt für einen Tab (von Hand oder als Kettenschritt)
            case tab(UUID, chain: Bool)
            /// automatisch für alle Auto-Tabs des Anschlusses
            case listener
        }

        let runner: SessionRunner
        let purpose: Purpose
        let token: Int
        /// gezielt: von Anfang an; Listener: sobald der Palm erkannt ist
        var tabId: UUID?
        var profileId: UUID?
        var user: PalmUser?
        var connected = false
        var admitted = false
        /// verbunden, der Dialog "Neuer Palm" wartet auf die Antwort
        var awaitingDecision = false
        var files: [URL] = []
        var results = 0
        var installed: Set<URL> = []
        var failed: [String: InstallFailure] = [:]
        var rejection: TabStatus.Rejection?
        /// Ablauf einer angenommenen Sitzung: zurückspielen (falls angefragt),
        /// die Warteschlange installieren, sichern (falls eingeschaltet)
        enum Stage { case restoring, installing, backingUp, readingCalendar, twoWayCalendar, fixingLocations, dumpingROM }
        var stage: Stage = .installing
        /// nach der Sicherung: diese Datenbanken vom Palm lesen und prüfen
        var checkDatabases: [String] = []
        var checking: String?
        var calendarAppInfo: Data?
        var calendarRecords: [PalmRecordIn] = []
        /// danach: die Ortsdatenbanken mit der tzdata des Macs abgleichen
        var fixDatabases: [String] = []
        var fixing: String?
        var fixChanged = 0
        var fixTotal = 0
        var fixUnknown = 0
        /// die korrigierte Datenbank, die nach dem Schließen installiert wird
        var fixInstall: URL?
        /// die Zonennamen des Palms (locLTimeZoneDB), für die Reihenfolge
        var zoneTable = PalmZoneTable(zones: [])
        /// Kalender in beide Richtungen (Probelauf): nach der Sicherung
        var twoWayCalendar = false
        /// aus dem syncInfo-Ereignis: welcher PC zuletzt abgeglichen hat
        var lastSyncPC: UInt32 = 0
        /// der zusammengeführte Kalender, der nach dem Schließen installiert
        /// wird, und der Spiegel, der danach gespeichert wird
        var twoWayInstall: URL?
        var twoWayMirror: CalendarMirror?
        var restoreFiles: [URL] = []
        var restoreDone = 0
        var restoreFailed = 0
        var backupEnabled = false
        var backupTotal = 0
        var backupDone = 0
        var backupSaved = 0
        var backupUnchanged = 0
        var backupFailed = 0
        var backupFinished = false
        var romVersion: UInt32 = 0
        var romRequested = false
        var romTotal = 0
        var romDone = 0
        var romResult: TabStatus.ROMDump?
        var timedOut = false
        var errorMessage: String?
        var stopRequested = false

        init(runner: SessionRunner, purpose: Purpose, token: Int) {
            self.runner = runner
            self.purpose = purpose
            self.token = token
        }
    }

    private func launch(_ purpose: Session.Purpose, on port: String, baudRate: Int) {
        let chainStep: Bool
        if case .tab(_, let chain) = purpose { chainStep = chain } else { chainStep = false }
        let runner = SessionRunner(port: port, baudRate: baudRate,
                                   timeout: chainStep ? Self.chainStepTimeout : 0)
        nextToken += 1
        let session = Session(runner: runner, purpose: purpose, token: nextToken)
        if case .tab(let id, _) = purpose {
            session.tabId = id
            session.profileId = tabStore.tab(id)?.profileId
        }

        runner.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handle(event, of: session)
        }
        runner.onExit = { [weak self, weak session] exit in
            guard let self, let session else { return }
            self.finish(session, exit: exit)
        }

        sessions[port] = session
        do {
            try runner.start()
        } catch {
            sessions[port] = nil
            let message = L10n.sessionToolMissing(error.localizedDescription)
            DebugLog.shared.log(message, source: "Session")
            if let tabId = session.tabId {
                statuses[tabId]?.phase = .idle
                statuses[tabId]?.lastResult = .failed(date: Date(), message: message)
                failChainStep(tabId, reason: message)
            }
        }
    }

    private func handle(_ event: SessionEvent, of session: Session) {
        let port = session.runner.port
        switch event {
        case .listening:
            let since = Date()
            if let tabId = session.tabId {
                statuses[tabId]?.phase = .listening(since: since)
                tabLog(tabId, L10n.logTabListening(portLabel(port)))
            } else {
                for tab in autoTabs(on: port) where statuses[tab.id]?.isBusy == false {
                    statuses[tab.id]?.phase = .listening(since: since)
                }
            }

        case .timeout:
            session.timedOut = true

        case .connected(let user, let romVersion):
            session.connected = true
            session.romVersion = romVersion
            // ein Palm ist durchgekommen: frühere Fehler hier sind erledigt
            notices.removeAll { if case .failed = $0.kind { return $0.port == port } else { return false } }
            session.user = user
            portMonitor.recordSighting(user, on: port)
            admit(user, session: session)

        case .userWritten(let user):
            if let profileId = session.profileId {
                deviceManager.assignIdentity(user, to: profileId)
            }

        // Kalender in beide Richtungen (Probelauf): lesen, planen, schließen
        case .syncInfo(let pc, _):
            session.lastSyncPC = pc
        case .dbOpened where session.stage == .twoWayCalendar:
            session.runner.send("readappinfo")
        case .appInfo(let data) where session.stage == .twoWayCalendar:
            session.calendarAppInfo = data
            session.runner.send("readall")
        case .record(let id, _, let attrs, let category, let data) where session.stage == .twoWayCalendar:
            session.calendarRecords.append(PalmRecordIn(id: id, attributes: attrs, category: category, data: data))
        case .recordsDone where session.stage == .twoWayCalendar:
            twoWayPlanned(session)
            session.runner.send("closedb")
        case .dbClosed where session.stage == .twoWayCalendar:
            if let url = session.twoWayInstall {
                session.twoWayInstall = nil
                session.runner.send("install \(url.path)")
            } else {
                fixLocations(session)
            }
        case .installing where session.stage == .twoWayCalendar:
            break
        case .installed where session.stage == .twoWayCalendar:
            twoWayInstalled(session)
        case .failed(_, let failure) where session.stage == .twoWayCalendar:
            if let tabId = session.tabId { tabLog(tabId, L10n.logTwoWayFailed(L10n.failureText(failure))) }
            session.twoWayMirror = nil
            fixLocations(session)
        case .syncInfoWritten where session.stage == .twoWayCalendar:
            if let tabId = session.tabId { tabLog(tabId, L10n.logTwoWayDone) }
            fixLocations(session)
        case .error(let stage, let message) where session.stage == .twoWayCalendar && stage == "syncinfo":
            if let tabId = session.tabId { tabLog(tabId, L10n.logTwoWayFailed("\(stage): \(message)")) }
            fixLocations(session)
        case .error(let stage, let message) where session.stage == .twoWayCalendar
            && ["opendb", "readappinfo", "readall", "closedb"].contains(stage):
            if let tabId = session.tabId { tabLog(tabId, L10n.logTwoWayFailed("\(stage): \(message)")) }
            if stage == "readall" || stage == "readappinfo" { session.runner.send("closedb") } else { fixLocations(session) }

        // Zeitzonen: die korrigierte Ortsdatenbank wird installiert - vor den
        // allgemeinen Fällen, sonst zählt sie als Datei der Warteschlange
        case .installing where session.stage == .fixingLocations:
            break
        case .installed(let file, _) where session.stage == .fixingLocations:
            if let tabId = session.tabId { tabLog(tabId, L10n.logLocationsInstalled(file)) }
            fixLocations(session)
        case .failed(let file, let failure) where session.stage == .fixingLocations:
            if let tabId = session.tabId { tabLog(tabId, L10n.logLocationsFailed(file, "install", L10n.failureText(failure))) }
            fixLocations(session)

        case .installing(let file):
            guard let tabId = session.tabId, let user = session.user else { return }
            if session.stage == .restoring {
                statuses[tabId]?.phase = .restoring(user: user, file: file, done: session.restoreDone,
                                                     total: session.restoreFiles.count)
            } else {
                statuses[tabId]?.phase = .syncing(user: user, file: file, done: session.results,
                                                   total: session.files.count)
                tabLog(tabId, L10n.logInstalling(file))
            }

        case .progress:
            break

        case .installed(let file, _) where session.stage == .restoring:
            restoreFileDone(session, file: file, failure: nil)

        case .failed(let file, let failure) where session.stage == .restoring:
            restoreFileDone(session, file: file, failure: failure)

        case .installed(let file, _):
            if let url = session.files.first(where: { $0.lastPathComponent == file }) {
                session.installed.insert(url)
            }
            if let tabId = session.tabId { tabLog(tabId, L10n.logFileInstalled(file)) }
            fileDone(session)

        case .failed(let file, let failure):
            session.failed[file] = failure
            if let tabId = session.tabId {
                tabLog(tabId, L10n.logFileNotInstalled(file, L10n.failureText(failure)))
            }
            fileDone(session)

        case .backupStarted(_, let total):
            session.backupTotal = total
            backupProgress(session, file: nil)

        case .backingUp(let file, let index, _):
            session.backupDone = index - 1
            backupProgress(session, file: file)

        case .backupUnchanged(_, let index):
            session.backupDone = index
            session.backupUnchanged += 1
            backupProgress(session, file: nil)

        case .backedUp(let file, let bytes):
            session.backupDone += 1
            session.backupSaved += 1
            if let tabId = session.tabId { tabLog(tabId, L10n.logBackedUp(file, bytes)) }
            backupProgress(session, file: nil)

        case .backupFailed(let file, let palmOSError):
            session.backupDone += 1
            session.backupFailed += 1
            if let tabId = session.tabId { tabLog(tabId, L10n.logBackupFailed(file, palmOSError)) }

        case .backupFinished(let saved, let unchanged, let failed):
            // vollständig nur, wenn jede Datenbank durch ist (nicht abgebrochen)
            session.backupFinished = session.backupDone >= session.backupTotal
            if let tabId = session.tabId { tabLog(tabId, L10n.logBackupFinished(saved, unchanged, failed)) }
            afterBackup(session)

        case .romStarted(let file, let version, let total):
            session.romTotal = total
            romProgress(session)
            if let tabId = session.tabId { tabLog(tabId, L10n.logROMStarting(version, total, file)) }

        case .romProgress(let bytes):
            session.romDone = bytes
            romProgress(session)

        case .romFinished(let file, let bytes):
            session.romResult = .saved(file: file, bytes: bytes)
            if let tabId = session.tabId { tabLog(tabId, L10n.logROMFinished(file, bytes)) }
            endSession(session)

        case .romUnsupported(let version):
            session.romResult = .unsupported(version: version)
            if let tabId = session.tabId { tabLog(tabId, L10n.logROMUnsupported(version)) }
            endSession(session)

        case .finished:
            break

        case .error(_, let message) where session.stage == .dumpingROM:
            // ein Fehler beendet das Auslesen; die Sitzung selbst ist heil
            session.romResult = .failed(message: message)
            if let tabId = session.tabId { tabLog(tabId, L10n.logROMFailed(message)) }
            endSession(session)

        // Kalenderprüfung: Datenbank öffnen, AppInfo und alle Datensätze lesen, schließen
        case .dbOpened where session.stage == .readingCalendar:
            session.runner.send("readappinfo")
        case .appInfo(let data) where session.stage == .readingCalendar:
            session.calendarAppInfo = data
            session.runner.send("readall")
        case .record(let id, _, let attrs, let category, let data) where session.stage == .readingCalendar:
            session.calendarRecords.append(PalmRecordIn(id: id, attributes: attrs, category: category, data: data))
            if let tabId = session.tabId, let user = session.user, session.calendarRecords.count % 10 == 0 {
                statuses[tabId]?.phase = .readingCalendar(user: user, database: session.checking ?? "", done: session.calendarRecords.count)
            }
        case .recordsDone where session.stage == .readingCalendar:
            calendarRead(session)
            session.runner.send("closedb")
        case .dbClosed where session.stage == .readingCalendar:
            afterBackup(session)    // die nächste Datenbank, oder weiter
        case .error(let stage, let message) where session.stage == .readingCalendar
            && ["opendb", "readappinfo", "readall", "closedb"].contains(stage):
            // die Prüfung scheitert, die Sitzung selbst ist heil
            if let tabId = session.tabId { tabLog(tabId, L10n.logCalendarCheckFailed(session.checking ?? "", stage, message)) }
            if stage == "opendb" || stage == "closedb" {
                afterBackup(session)
            } else {
                session.runner.send("closedb")
            }

        // Zeitzonen: Orte lesen, abweichende neu schreiben, schließen
        case .timeSet(let date):
            if let tabId = session.tabId { tabLog(tabId, L10n.logTimeSet(date)) }
        case .dbOpened where session.stage == .fixingLocations:
            session.runner.send("readall")
        case .record(let id, _, let attrs, let category, let data) where session.stage == .fixingLocations:
            session.calendarRecords.append(PalmRecordIn(id: id, attributes: attrs, category: category, data: data))
        case .recordsDone where session.stage == .fixingLocations:
            locationsRead(session)
        case .dbClosed where session.stage == .fixingLocations:
            if let url = session.fixInstall {
                session.fixInstall = nil
                session.runner.send("install \(url.path)")   // die korrigierte Datenbank, ganz
            } else {
                fixLocations(session)    // die nächste Datenbank, oder weiter
            }
        case .error(let stage, let message) where session.stage == .fixingLocations
            && ["opendb", "readall", "closedb"].contains(stage):
            if let tabId = session.tabId { tabLog(tabId, L10n.logLocationsFailed(session.fixing ?? "", stage, message)) }
            if stage == "readall" { session.runner.send("closedb") } else { fixLocations(session) }

        case .error(let stage, let message):
            session.errorMessage = "\(stage): \(message)"
            DebugLog.shared.log(L10n.logSessionError(portLabel(port), stage, message), source: "Session")
            if let tabId = session.tabId { tabLog(tabId, L10n.logSessionError(portLabel(port), stage, message)) }

        case .dbOpened, .dbClosed, .appInfo, .appInfoWritten, .record, .recordsDone,
             .recordWritten, .recordDeleted, .flagsReset, .cleanedUp, .syncInfoWritten:
            // Datensatzzugriff außerhalb der Kalenderprüfung: gehört dem
            // Abgleich, den die App noch nicht fährt
            break
        }
    }

    // MARK: - Kalender-Abgleich

    func setCalendarSync(_ settings: CalendarSyncSettings, for profileId: UUID) {
        guard var profile = deviceManager.profile(profileId) else { return }
        profile.calendarSync = settings
        deviceManager.updateProfile(profile)
        refreshCalendarPreview(for: profileId)
    }

    func setClockSync(_ on: Bool, for profileId: UUID) {
        guard var profile = deviceManager.profile(profileId) else { return }
        profile.clockSync = on
        deviceManager.updateProfile(profile)
    }

    func setZoneSync(_ on: Bool, for profileId: UUID) {
        guard var profile = deviceManager.profile(profileId) else { return }
        profile.zoneSync = on
        deviceManager.updateProfile(profile)
    }

    func setContactSync(_ settings: ContactSyncSettings, for profileId: UUID) {
        guard var profile = deviceManager.profile(profileId) else { return }
        profile.contactSync = settings
        deviceManager.updateProfile(profile)
        refreshContactPreview(for: profileId)
    }

    func setDryRun(_ on: Bool, for profileId: UUID) {
        guard var profile = deviceManager.profile(profileId) else { return }
        profile.dryRun = on
        deviceManager.updateProfile(profile)
    }

    func setCalendarTwoWay(_ on: Bool, for profileId: UUID) {
        guard var profile = deviceManager.profile(profileId) else { return }
        profile.calendarTwoWay = on
        deviceManager.updateProfile(profile)
    }

    func setTaskSync(_ settings: TaskSyncSettings, for profileId: UUID) {
        guard var profile = deviceManager.profile(profileId) else { return }
        profile.taskSync = settings
        deviceManager.updateProfile(profile)
        refreshTaskPreview(for: profileId)
    }

    private(set) var taskPreviews: [UUID: String] = [:]

    func taskPreview(for profileId: UUID) -> String? { taskPreviews[profileId] }

    func refreshTaskPreview(for profileId: UUID) {
        let key = "tasks-\(profileId)"
        previewTasks[key]?.cancel()
        guard let settings = deviceManager.profile(profileId)?.taskSync, !settings.lists.isEmpty,
              reminderSource.hasAccess else {
            if taskPreviews[profileId] != nil { taskPreviews[profileId] = nil }
            return
        }
        let source = reminderSource
        previewTasks[key] = Task { [weak self] in
            let text: String? = await Task.detached {
                guard let run = try? await TaskSyncRun(settings: settings, source: source) else { return nil }
                return L10n.taskSyncPreview(run.report.records, run.report.categories.count - 1, run.report.completedSkipped)
            }.value
            guard !Task.isCancelled else { return }
            self?.taskPreviews[profileId] = text
        }
    }

    /// Was der nächste HotSync tragen würde, je Profil - einmal gerechnet,
    /// wenn sich die Einstellungen ändern, nicht bei jedem Zeichnen der View
    private(set) var calendarPreviews: [UUID: String] = [:]
    private(set) var contactPreviews: [UUID: String] = [:]
    private var previewTasks: [String: Task<Void, Never>] = [:]

    // Nur lesen: ein Anstoß von hier aus würde beim Zeichnen den Zustand
    // ändern und die View endlos neu zeichnen. Die Abschnitte stoßen beim
    // Erscheinen an.
    func calendarPreview(for profileId: UUID) -> String? { calendarPreviews[profileId] }
    func contactPreview(for profileId: UUID) -> String? { contactPreviews[profileId] }

    func refreshCalendarPreview(for profileId: UUID) {
        let key = "calendar-\(profileId)"
        previewTasks[key]?.cancel()
        guard let settings = deviceManager.profile(profileId)?.calendarSync, !settings.calendars.isEmpty,
              calendarSource.hasAccess else {
            if calendarPreviews[profileId] != nil { calendarPreviews[profileId] = nil }
            return
        }
        let source = calendarSource
        previewTasks[key] = Task { [weak self] in
            let text: String? = await Task.detached {
                guard let run = try? CalendarSyncRun(settings: settings, source: source) else { return nil }
                return L10n.calendarSyncPreview(run.report.records, run.report.seriesMapped, run.report.seriesExpanded)
            }.value
            guard !Task.isCancelled else { return }
            self?.calendarPreviews[profileId] = text
        }
    }

    func refreshContactPreview(for profileId: UUID) {
        let key = "contacts-\(profileId)"
        previewTasks[key]?.cancel()
        guard let settings = deviceManager.profile(profileId)?.contactSync, !settings.containers.isEmpty,
              contactSource.hasAccess else {
            if contactPreviews[profileId] != nil { contactPreviews[profileId] = nil }
            return
        }
        let source = contactSource
        previewTasks[key] = Task { [weak self] in
            let text: String? = await Task.detached {
                guard let run = try? ContactSyncRun(settings: settings, source: source) else { return nil }
                return L10n.contactSyncPreview(run.report.records, run.report.categories.count - 1, run.report.duplicatesDropped)
            }.value
            guard !Task.isCancelled else { return }
            self?.contactPreviews[profileId] = text
        }
    }

    /// Ein Palm hat sich gemeldet: gehört er hierher - und zu welchem Profil?
    private func admit(_ user: PalmUser, session: Session) {
        let port = session.runner.port
        let expected: UUID?
        let candidates: [ProfileIdentity]
        let all = deviceManager.identities
        switch session.purpose {
        case .tab:
            expected = session.profileId
            candidates = all.filter { $0.id == session.profileId }
        case .listener:
            expected = nil
            let profileIds = Set(autoTabs(on: port).map(\.profileId))
            candidates = all.filter { profileIds.contains($0.id) }
        }

        switch PalmAdmission.decide(user: user, expected: expected, candidates: candidates, profiles: all) {
        case .install(let profileId):
            install(profileId, user: user, session: session)

        case .adopt(let profileId):
            adopt(profileId, session: session)

        case .wrongPalm(_, let owner):
            reject(session, .wrongPalm(found: user, owner: owner), user: user)

        case .unknown:
            if case .tab = session.purpose {
                // Der Tab zeigt die Ablehnung; der Palm ist an seiner ID
                // eindeutig und kann auch ohne offene Sitzung angelegt werden
                reject(session, .unknown(user), user: user)
                if newPalmPrompt == nil {
                    newPalmPrompt = NewPalmPrompt(port: port, user: user, sessionToken: nil)
                    onAttentionNeeded?()
                }
            } else {
                promptNewPalm(user, session: session)
            }

        case .blank:
            promptNewPalm(user, session: session)
        }
    }

    /// Ein Palm ohne Benutzer übernimmt ein Profil: HotSync schreibt ihm
    /// Name und ID, dann wird installiert.
    private func adopt(_ profileId: UUID, session: Session) {
        guard let profile = deviceManager.profile(profileId) else { return }
        // Ein schon gebundenes Profil gibt seine ID zurück (z. B. nach einem
        // Hard Reset des Palms); ein neues bekommt eine eigene.
        let userId = profile.isBound
            ? UInt32(truncatingIfNeeded: profile.userId)
            : UInt32.random(in: 1_000_000...0x7FFF_FFFF)
        session.runner.send("setuser \(userId) \(profile.username)")
        // vor install(): das legt los und schreibt sonst seine Zeilen zuerst
        if let tabId = session.tabId ?? autoTabs(on: session.runner.port).first(where: { $0.profileId == profileId })?.id {
            tabLog(tabId, L10n.logAdopting(profile.username))
        }
        install(profileId, user: PalmUser(name: profile.username, userId: userId), session: session)
    }

    private func install(_ profileId: UUID, user: PalmUser, session: Session) {
        session.admitted = true
        session.profileId = profileId
        session.user = user
        if case .listener = session.purpose {
            session.tabId = autoTabs(on: session.runner.port).first { $0.profileId == profileId }?.id
        }
        guard let tabId = session.tabId, let queue = queues[profileId] else {
            session.runner.send("end")
            return
        }
        // Das Fenster zeigt den Tab, der gerade synct
        selectedTabId = tabId

        let mode = tabStore.tab(tabId)?.hotSyncMode ?? .syncInstallBackup
        if mode.syncs, let profile = deviceManager.profile(profileId) {
            let dry = profile.isDryRun
            if dry { tabLog(tabId, L10n.logDryRun) }
            // Uhr vom Mac jetzt, Zeitzonen nach der Sicherung
            if profile.isClockSyncOn {
                if dry { tabLog(tabId, L10n.logDryRunClock) } else { session.runner.send("settime") }
            }
            if profile.isZoneSyncOn { session.fixDatabases = ["locLTimeZoneDB", "locLDefLocationDB", "locLCusLocationDB"] }
            // Erst sichern, dann ersetzen: ohne Sicherung dieses Palms gehen
            // sein eigener Kalender und seine Kontakte nicht verloren
            if let settings = profile.calendarSync, settings.enabled {
                if profile.isCalendarTwoWay {
                    // nach der Sicherung: Palm lesen, zusammenführen, dann schreiben
                    session.twoWayCalendar = true
                    tabLog(tabId, L10n.logTwoWayPending)
                } else if profile.lastBackupAt == nil {
                    tabLog(tabId, L10n.logCalendarNeedsBackup)
                } else {
                    queueCalendar(settings, profileId: profileId, tabId: tabId, queue: queue, dryRun: dry)
                    if !dry { session.checkDatabases.append(CalendarBuilder.databaseName) }
                }
            }
            if let settings = profile.contactSync, settings.enabled {
                if profile.lastBackupAt == nil {
                    tabLog(tabId, L10n.logContactsNeedBackup)
                } else {
                    queueContacts(settings, profileId: profileId, tabId: tabId, queue: queue, dryRun: dry)
                }
                if !dry { session.checkDatabases.append(ContactsBuilder.databaseName) }
            }
            if let settings = profile.taskSync, settings.enabled {
                if !dry { session.checkDatabases.append(TasksBuilder.databaseName) }
                if profile.lastBackupAt == nil {
                    tabLog(tabId, L10n.logTasksNeedBackup)
                } else {
                    // Reminders liefert asynchron; der Palm wartet solange (Lebenszeichen)
                    Task { @MainActor [weak self, weak session] in
                        guard let self, let session else { return }
                        await self.queueTasks(settings, profileId: profileId, tabId: tabId, queue: queue, dryRun: dry)
                        self.startQueue(session, profileId: profileId, tabId: tabId, user: user, queue: queue, mode: mode)
                    }
                    return
                }
            }
        }
        startQueue(session, profileId: profileId, tabId: tabId, user: user, queue: queue, mode: mode)
    }

    /// Die Warteschlange ist vollständig: was von ihr auf den Palm geht,
    /// zurückspielen falls angefragt, dann installieren.
    private func startQueue(_ session: Session, profileId: UUID, tabId: UUID, user: PalmUser, queue: InstallQueue, mode: HotSyncMode) {
        // "Nur abgleichen": von der Warteschlange gehen nur die Datenbanken
        // des Abgleichs auf den Palm, der Rest wartet
        let synced = [CalendarBuilder.databaseName, ContactsBuilder.databaseName, TasksBuilder.databaseName].map { "\($0).pdb" }
        let files = mode.installs ? queue.pendingFiles : queue.pendingFiles.filter { synced.contains($0.lastPathComponent) }
        session.files = files
        queue.beginInstall(files, session: session.token)
        deviceManager.updateRomVersion(session.romVersion, for: profileId)
        if restoreRequests.remove(profileId) != nil {
            session.restoreFiles = backupFiles(for: profileId)
        }
        session.romRequested = romRequests.remove(profileId) != nil
        // Nach dem Zurückspielen nicht gleich wieder sichern: der Palm hat
        // gerade die Sicherung bekommen
        session.backupEnabled = mode.backsUp && session.restoreFiles.isEmpty
        statuses[tabId]?.lastResult = nil
        statuses[tabId]?.lastBackup = nil
        statuses[tabId]?.lastRestore = nil
        statuses[tabId]?.lastROMDump = nil
        tabLog(tabId, L10n.logPalmConnected(user.name, user.userId, files.count))

        if session.restoreFiles.isEmpty {
            startInstalls(session)
        } else {
            session.stage = .restoring
            statuses[tabId]?.phase = .restoring(user: user, file: nil, done: 0, total: session.restoreFiles.count)
            tabLog(tabId, L10n.logRestoreStarting(session.restoreFiles.count))
            for file in session.restoreFiles {
                session.runner.send("install \(file.path)")
            }
        }
    }

    /// Eine Datenbank der Sicherung ist zurück (oder nicht); nach der
    /// letzten folgt die Warteschlange.
    private func restoreFileDone(_ session: Session, file: String, failure: InstallFailure?) {
        session.restoreDone += 1
        if let tabId = session.tabId {
            if let failure {
                session.restoreFailed += 1
                tabLog(tabId, L10n.logRestoreFailed(file, L10n.restoreFailureText(failure)))
            }
            if let user = session.user {
                statuses[tabId]?.phase = .restoring(user: user, file: nil, done: session.restoreDone,
                                                     total: session.restoreFiles.count)
            }
        }
        if session.restoreDone == session.restoreFiles.count {
            if let tabId = session.tabId {
                tabLog(tabId, L10n.logRestoreFinished(session.restoreDone - session.restoreFailed,
                                                      session.restoreFailed))
            }
            startInstalls(session)
        }
    }

    /// Die Warteschlange auf den Palm
    private func startInstalls(_ session: Session) {
        session.stage = .installing
        guard !session.files.isEmpty else {
            installsDone(session)
            return
        }
        if let tabId = session.tabId, let user = session.user {
            statuses[tabId]?.phase = .syncing(user: user, file: nil, done: 0, total: session.files.count)
        }
        for file in session.files {
            session.runner.send("install \(file.path)")
        }
    }

    private func fileDone(_ session: Session) {
        session.results += 1
        if let tabId = session.tabId, let user = session.user {
            statuses[tabId]?.phase = .syncing(user: user, file: nil, done: session.results,
                                               total: session.files.count)
        }
        if session.results == session.files.count {
            installsDone(session)
        }
    }

    /// Baut CalendarDB-PDat aus Calendar.app und legt es in die Warteschlange,
    /// damit es mit diesem HotSync auf den Palm geht.
    /// Wohin eine gebaute Datenbank kommt: in die Warteschlange, oder beim
    /// Probelauf daneben nach Sync/DryRun, wo sie niemand installiert.
    private func syncTarget(_ name: String, for profile: DeviceProfile, dryRun: Bool) throws -> URL {
        if !dryRun { return deviceManager.installDirectory(for: profile).appendingPathComponent("\(name).pdb") }
        let dir = deviceManager.profileDirectory(for: profile).appendingPathComponent("Sync").appendingPathComponent("DryRun")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).pdb")
    }

    private func queueCalendar(_ settings: CalendarSyncSettings, profileId: UUID, tabId: UUID, queue: InstallQueue, dryRun: Bool) {
        guard let profile = deviceManager.profile(profileId) else { return }
        do {
            let run = try CalendarSyncRun(settings: settings, source: calendarSource)
            let url = try syncTarget(CalendarBuilder.databaseName, for: profile, dryRun: dryRun)
            let bytes = try run.write(to: url)
            if dryRun { tabLog(tabId, L10n.logDryRunWouldInstall(CalendarBuilder.databaseName, run.report.records, bytes)); return }
            queue.refresh()
            tabLog(tabId, L10n.logCalendarQueued(run.report.records, run.report.seriesMapped, bytes))
            for warning in run.report.warnings { tabLog(tabId, L10n.logCalendarWarning(warning)) }
        } catch CalendarSyncRun.Failure.noAccess {
            tabLog(tabId, L10n.logCalendarNoAccess)
        } catch {
            tabLog(tabId, L10n.logCalendarFailed(error.localizedDescription))
        }
    }

    /// Alle Dateien sind durch: sichern, falls eingeschaltet.
    private func installsDone(_ session: Session) {
        guard session.backupEnabled, let profileId = session.profileId,
              let profile = deviceManager.profile(profileId), let tabId = session.tabId else {
            afterBackup(session)
            return
        }
        session.stage = .backingUp
        backupProgress(session, file: nil)
        let directory = deviceManager.backupDirectory(for: profile)
        tabLog(tabId, L10n.logBackupStarting(directory.path))
        session.runner.send("backup \(directory.path)")
    }

    /// Nach der Sicherung: die abgeglichenen Datenbanken auf dem Palm
    /// prüfen, eine nach der anderen, dann die Zeitzonen, dann das ROM.
    private func afterBackup(_ session: Session) {
        guard !session.checkDatabases.isEmpty, let tabId = session.tabId, let user = session.user else {
            twoWayCalendar(session)
            return
        }
        let name = session.checkDatabases.removeFirst()
        session.checking = name
        session.calendarAppInfo = nil
        session.calendarRecords = []
        session.stage = .readingCalendar
        statuses[tabId]?.phase = .readingCalendar(user: user, database: name, done: 0)
        tabLog(tabId, L10n.logCalendarChecking(name))
        session.runner.send("opendb r \(name)")
    }

    /// Eine Datenbank ist vom Palm gelesen: jeden Datensatz durch den Codec
    /// und zurück - was nicht Byte für Byte übereinstimmt, steht im Log.
    private func calendarRead(_ session: Session) {
        guard let tabId = session.tabId, let name = session.checking else { return }
        var identical = 0, different = 0, deleted = 0
        for record in session.calendarRecords {
            if record.isDeleted { deleted += 1; continue }
            let back: Data?
            switch name {
            case CalendarBuilder.databaseName: back = (try? CalendarEvent(data: record.data))?.encode()
            case ContactsBuilder.databaseName: back = (try? Contact(data: record.data))?.encode()
            case TasksBuilder.databaseName: back = (try? PalmTask(data: record.data))?.encode()
            default: back = record.data
            }
            if back == record.data {
                identical += 1
            } else {
                different += 1
                tabLog(tabId, L10n.logCalendarRecordDiffers(record.id, record.data.count,
                                                              record.data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")))
            }
        }
        let categories: [String]
        if let info = session.calendarAppInfo {
            switch name {
            case CalendarBuilder.databaseName: categories = (try? CalendarAppInfo(data: info))?.categories.named.map(\.name) ?? []
            case ContactsBuilder.databaseName: categories = (try? ContactAppInfo(data: info))?.categories.named.map(\.name) ?? []
            case TasksBuilder.databaseName: categories = (try? TaskAppInfo(data: info))?.categories.named.map(\.name) ?? []
            default: categories = (try? CategoryAppInfo(bytes: [UInt8](info)[...]))?.named.map(\.name) ?? []
            }
        } else {
            categories = []
        }
        tabLog(tabId, L10n.logCalendarChecked(name, session.calendarRecords.count, identical, different, deleted, categories))
    }

    // MARK: Kalender in beide Richtungen (Probelauf)

    /// Liest den Kalender des Palms, plant den Abgleich gegen den Spiegel
    /// und schreibt den Plan ins Log - nichts wird geschrieben. Dann die
    /// Zeitzonen.
    private func twoWayCalendar(_ session: Session) {
        guard session.twoWayCalendar, let tabId = session.tabId, let user = session.user else {
            fixLocations(session)
            return
        }
        session.twoWayCalendar = false
        session.calendarAppInfo = nil
        session.calendarRecords = []
        session.stage = .twoWayCalendar
        statuses[tabId]?.phase = .readingCalendar(user: user, database: CalendarBuilder.databaseName, done: 0)
        tabLog(tabId, L10n.logTwoWayReading)
        session.runner.send("opendb r \(CalendarBuilder.databaseName)")
    }

    private func mirrorURL(for profile: DeviceProfile) -> URL {
        deviceManager.profileDirectory(for: profile).appendingPathComponent("Sync").appendingPathComponent("calendar-mirror.json")
    }

    /// Der Kalender ist gelesen: Mac-Seite holen, planen, berichten.
    private func twoWayPlanned(_ session: Session) {
        guard let tabId = session.tabId, let profileId = session.profileId,
              let profile = deviceManager.profile(profileId), let settings = profile.calendarSync else { return }
        let url = mirrorURL(for: profile)
        let mirror = (try? CalendarMirror.load(from: url)) ?? CalendarMirror(pcID: CalendarMirror.newPCID())
        let fast = mirror.lastSync != nil && session.lastSyncPC == mirror.pcID
        tabLog(tabId, L10n.logTwoWayMode(fast: fast, lastSyncPC: session.lastSyncPC, mirrorEntries: mirror.entries.count))

        let categories = session.calendarAppInfo.flatMap { try? CalendarAppInfo(data: $0) }?.categories.names ?? ["Unfiled"]
        let palm = PalmSnapshot.all(session.calendarRecords)   // der Probelauf liest immer alles

        guard calendarSource.hasAccess else {
            tabLog(tabId, L10n.logCalendarNoAccess)
            return
        }
        let calendar = Foundation.Calendar.current
        let today = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -settings.daysBack, to: today)!
        let windowEnd = calendar.date(byAdding: .day, value: settings.daysAhead, to: today)!
        let events = calendarSource.events(from: windowStart, to: windowEnd, calendarIDs: settings.calendars.map(\.id))
        let builder = CalendarBuilder(options: .init(homeZone: .current, windowStart: windowStart, windowEnd: windowEnd,
                                                     calendars: settings.macCalendars,
                                                     startOfWeek: calendar.firstWeekday == 2 ? 1 : 0))
        let items = builder.items(events).items
        let engine = CalendarSyncEngine(windowStart: PalmDate(windowStart, in: calendar), windowEnd: PalmDate(windowEnd, in: calendar),
                                        conflictPolicy: settings.conflicts)
        do {
            let plan = try engine.plan(palm: palm, palmCategories: categories, mac: items, mirror: mirror)
            tabLog(tabId, L10n.logTwoWaySummary(toPalm: plan.palmWrites.count, palmDeletes: plan.palmDeletes.count,
                                                toMac: plan.macCreates.count + plan.macUpdates.count, macDeletes: plan.macDeletes.count,
                                                conflicts: plan.conflicts.count, policy: settings.conflicts))
            var lines: [String] = []
            for w in plan.palmWrites.prefix(10) {
                let title = (try? CalendarEvent(data: w.record))?.title ?? "?"
                lines.append(L10n.logTwoWayToPalm(title, new: w.id == nil))
            }
            for c in plan.macCreates.prefix(10) { lines.append(L10n.logTwoWayToMac(c.item.title ?? "?", new: true)) }
            for c in plan.macUpdates.prefix(10) { lines.append(L10n.logTwoWayToMac(c.item.title ?? "?", new: false)) }
            for conflict in plan.conflicts.prefix(10) {
                lines.append(L10n.logTwoWayConflict(conflict.title, conflict.field, conflict.palmValue, conflict.macValue,
                                                    policy: settings.conflicts))
            }
            for line in lines { tabLog(tabId, "  " + line) }
            for line in plan.log.prefix(10) { tabLog(tabId, "  " + line) }
            if !plan.missingCategories.isEmpty { tabLog(tabId, L10n.logTwoWayMissingCategories(plan.missingCategories)) }

            guard !profile.isDryRun else {
                tabLog(tabId, L10n.logTwoWayDryRunDone)
                return
            }
            twoWayApply(plan, mirror: mirror, session: session, profile: profile, settings: settings,
                        palmCategories: session.calendarAppInfo.flatMap { try? CalendarAppInfo(data: $0) }?.categories ?? CategoryAppInfo(),
                        startOfWeek: calendar.firstWeekday == 2 ? 1 : 0)
        } catch {
            tabLog(tabId, L10n.logTwoWayFailed(error.localizedDescription))
        }
    }

    /// Anwenden: die Mac-Seite über EventKit, der Palm bekommt den
    /// zusammengeführten Kalender als Ganzes (nach dem Schließen installiert),
    /// danach Spiegel speichern und lastSyncPC setzen.
    private func twoWayApply(_ plan: CalendarSyncPlan, mirror: CalendarMirror, session: Session, profile: DeviceProfile,
                             settings: CalendarSyncSettings, palmCategories: CategoryAppInfo, startOfWeek: UInt8) {
        guard let tabId = session.tabId else { return }
        let calendars = settings.calendars
        let writer = CalendarWriter(store: calendarSource.store, homeZone: .current) { category in
            let id = calendars.first { ($0.category ?? $0.title) == category }?.id ?? calendars.first?.id
            return id.flatMap { self.calendarSource.store.calendar(withIdentifier: $0) }
        }
        let result = writer.apply(plan)
        tabLog(tabId, L10n.logTwoWayMacApplied(result.createdKeys.count, result.updated, result.deleted))
        for failure in result.failures.prefix(10) { tabLog(tabId, L10n.logTwoWayMacFailure(failure)) }

        let (db, palmIDs, _) = plan.palmDatabase(categories: palmCategories, startOfWeek: startOfWeek)
        session.twoWayMirror = plan.mirror(after: mirror, palmIDs: palmIDs, macKeys: result.createdKeys)
        let url = deviceManager.profileDirectory(for: profile).appendingPathComponent("Sync")
            .appendingPathComponent("\(CalendarBuilder.databaseName).pdb")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try db.encode().write(to: url, options: .atomic)
            session.twoWayInstall = url
            tabLog(tabId, L10n.logTwoWayPalmInstalling(db.records.count))
        } catch {
            tabLog(tabId, L10n.logTwoWayFailed(error.localizedDescription))
            session.twoWayMirror = nil
        }
    }

    /// Der zusammengeführte Kalender ist auf dem Palm: Spiegel speichern,
    /// diesen Mac als letzten PC eintragen.
    private func twoWayInstalled(_ session: Session) {
        guard let tabId = session.tabId, let profileId = session.profileId, let profile = deviceManager.profile(profileId),
              let mirror = session.twoWayMirror else { return }
        do {
            try mirror.save(to: mirrorURL(for: profile))
            tabLog(tabId, L10n.logTwoWayMirrorSaved(mirror.entries.count))
        } catch {
            tabLog(tabId, L10n.logTwoWayFailed(error.localizedDescription))
        }
        session.twoWayMirror = nil
        session.runner.send("syncinfo \(mirror.pcID)")
    }

    /// Die Ortsdatenbanken des Palms (eingebaute und eigene Orte) mit der
    /// tzdata des Macs vergleichen und abweichende Einträge neu schreiben:
    /// ein Palm OS 5 kennt weder die Regeln von 2007 noch eine Provinz, die
    /// die Uhr nicht mehr umstellt. Eine Datenbank nach der anderen.
    private func fixLocations(_ session: Session) {
        guard !session.fixDatabases.isEmpty, let tabId = session.tabId, let user = session.user else {
            afterCalendarCheck(session)
            return
        }
        let name = session.fixDatabases.removeFirst()
        session.fixing = name
        session.calendarRecords = []
        session.fixChanged = 0
        session.fixUnknown = 0
        session.fixInstall = nil
        session.stage = .fixingLocations
        statuses[tabId]?.phase = .readingCalendar(user: user, database: name, done: 0)
        tabLog(tabId, L10n.logLocationsChecking(name))
        session.runner.send("opendb r \(name)")
    }

    /// Die Orte sind gelesen: weicht einer von der tzdata ab, geht die ganze
    /// Datenbank korrigiert zurück - installiert, in derselben Reihenfolge.
    /// Einzelne Datensätze zu schreiben bringt die Reihenfolge durcheinander,
    /// und der Palm spricht seine Orte über die Position an.
    private func locationsRead(_ session: Session) {
        guard let tabId = session.tabId, let name = session.fixing, let profileId = session.profileId,
              let profile = deviceManager.profile(profileId) else { return }
        if name == "locLTimeZoneDB" {
            // nur gelesen: die Zonennamen, nach denen der Palm seine Orte ordnet
            session.zoneTable = PalmZoneTable(records: session.calendarRecords.map(\.data))
            session.runner.send("closedb")
            return
        }
        session.fixTotal = session.calendarRecords.count
        var records: [PalmDatabase.Record] = []
        for record in session.calendarRecords where !record.isDeleted {
            var data = record.data
            if let location = try? PalmLocation(data: record.data) {
                if TimeZoneFixups.zone(for: location) == nil {
                    session.fixUnknown += 1
                } else if let (fixed, change) = TimeZoneFixups.fix(location) {
                    tabLog(tabId, L10n.logLocationFixed(change))
                    session.fixChanged += 1
                    data = fixed.encode()
                }
            }
            records.append(PalmDatabase.Record(attributes: 0, category: record.category, uniqueID: record.id, data: data))
        }
        tabLog(tabId, L10n.logLocationsDone(name, session.fixChanged, session.fixTotal, session.fixUnknown))

        // Die Auswahlliste des Palms geht davon aus, dass die eingebauten Orte
        // nach Zonenname und Stadt gespeichert sind: ändert sich eine Zone,
        // wird der Länderblock so sortiert, sonst öffnet "Vancouver" St. John's
        var reordered = false
        if name == "locLDefLocationDB" {
            let sorted = TimeZoneFixups.reorderWithinCountries(records, location: { try? PalmLocation(data: $0.data) },
                                                               zones: session.zoneTable)
            if sorted.map(\.uniqueID) != records.map(\.uniqueID) {
                reordered = true
                records = sorted
                tabLog(tabId, L10n.logLocationsReordered)
            }
        }

        if session.fixChanged > 0 || reordered {
            // wie die des Palms: Version 2, Backup-Flag, Typ DATA (eingebaute) / DATC (eigene)
            var db = PalmDatabase(name: name, type: name == "locLCusLocationDB" ? "DATC" : "DATA", creator: "locL",
                                  attributes: 0x0008, version: 2)
            db.records = records
            db.uniqueIDSeed = (records.map(\.uniqueID).max() ?? 0) + 1
            let url = deviceManager.profileDirectory(for: profile).appendingPathComponent("Sync")
                .appendingPathComponent("\(name).pdb")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try db.encode().write(to: url, options: .atomic)
                if profile.isDryRun {
                    tabLog(tabId, L10n.logDryRunWouldInstall(name, records.count, db.encode().count))
                } else {
                    session.fixInstall = url
                    if name == "locLDefLocationDB" { tabLog(tabId, L10n.logLocationsHint) }
                }
            } catch {
                tabLog(tabId, L10n.logLocationsFailed(name, "write", error.localizedDescription))
            }
        }
        session.runner.send("closedb")
    }

    /// Baut TasksDB-PTod aus Reminders.app und legt es in die Warteschlange.
    private func queueTasks(_ settings: TaskSyncSettings, profileId: UUID, tabId: UUID, queue: InstallQueue, dryRun: Bool) async {
        guard let profile = deviceManager.profile(profileId) else { return }
        do {
            let run = try await TaskSyncRun(settings: settings, source: reminderSource)
            let url = try syncTarget(TasksBuilder.databaseName, for: profile, dryRun: dryRun)
            let bytes = try run.write(to: url)
            if dryRun { tabLog(tabId, L10n.logDryRunWouldInstall(TasksBuilder.databaseName, run.report.records, bytes)); return }
            queue.refresh()
            tabLog(tabId, L10n.logTasksQueued(run.report.records, run.report.completedSkipped, bytes))
            for warning in run.report.warnings { tabLog(tabId, L10n.logTasksWarning(warning)) }
        } catch TaskSyncRun.Failure.noAccess {
            tabLog(tabId, L10n.logTasksNoAccess)
        } catch {
            tabLog(tabId, L10n.logTasksFailed(error.localizedDescription))
        }
    }

    /// Baut ContactsDB-PAdd aus Contacts.app und legt es in die Warteschlange.
    private func queueContacts(_ settings: ContactSyncSettings, profileId: UUID, tabId: UUID, queue: InstallQueue, dryRun: Bool) {
        guard let profile = deviceManager.profile(profileId) else { return }
        do {
            let run = try ContactSyncRun(settings: settings, source: contactSource)
            let url = try syncTarget(ContactsBuilder.databaseName, for: profile, dryRun: dryRun)
            let bytes = try run.write(to: url)
            if dryRun { tabLog(tabId, L10n.logDryRunWouldInstall(ContactsBuilder.databaseName, run.report.records, bytes)); return }
            queue.refresh()
            tabLog(tabId, L10n.logContactsQueued(run.report.records, run.report.categories.count - 1, bytes))
            for warning in run.report.warnings { tabLog(tabId, L10n.logContactsWarning(warning)) }
        } catch ContactSyncRun.Failure.noAccess {
            tabLog(tabId, L10n.logContactsNoAccess)
        } catch {
            tabLog(tabId, L10n.logContactsFailed(error.localizedDescription))
        }
    }

    /// Nach der Kalenderprüfung: das ROM auslesen, falls angefragt, sonst Ende.
    private func afterCalendarCheck(_ session: Session) {
        guard session.romRequested, let profileId = session.profileId,
              let profile = deviceManager.profile(profileId), let tabId = session.tabId else {
            endSession(session)
            return
        }
        session.stage = .dumpingROM
        romProgress(session)
        let directory = deviceManager.romDirectory(for: profile)
        tabLog(tabId, L10n.logROMRequested(directory.path))
        session.runner.send("getrom \(directory.path)")
    }

    private func romProgress(_ session: Session) {
        guard let tabId = session.tabId, let user = session.user else { return }
        statuses[tabId]?.phase = .dumpingROM(user: user, done: session.romDone, total: session.romTotal)
    }

    private func backupProgress(_ session: Session, file: String?) {
        guard let tabId = session.tabId, let user = session.user else { return }
        statuses[tabId]?.phase = .backingUp(user: user, file: file, done: session.backupDone,
                                             total: session.backupTotal)
    }

    /// Alle Dateien sind durch: Eintrag ins HotSync-Log des Palms, Ende.
    private func endSession(_ session: Session) {
        session.runner.send("log " + L10n.palmLogSummary(session.installed.count, session.failed.count))
        session.runner.send("end")
    }

    private func reject(_ session: Session, _ rejection: TabStatus.Rejection, user: PalmUser) {
        session.rejection = rejection
        if let tabId = session.tabId {
            tabLog(tabId, L10n.logPalmRejected(user.name, user.userId))
        }
        endWithoutInstall(session, user: user)
    }

    private func endWithoutInstall(_ session: Session, user: PalmUser) {
        DebugLog.shared.log(L10n.logPalmRejected(user.name, user.userId), source: portLabel(session.runner.port))
        session.runner.send("log " + L10n.palmLogNothingInstalled)
        session.runner.send("end")
    }

    private func notify(_ notice: PortNotice) {
        // derselbe Palm am selben Anschluss nur einmal
        notices.removeAll { $0.port == notice.port && $0.kind == notice.kind }
        notices.append(notice)
    }

    /// Das Werkzeug hat sich beendet - alle Ereignisse sind ausgewertet.
    private func finish(_ session: Session, exit: SessionRunner.Exit) {
        let port = session.runner.port
        if sessions[port] === session {
            sessions[port] = nil
        }
        let now = Date()

        // Der Palm ist weg, bevor der Benutzer im Dialog geantwortet hat
        if session.awaitingDecision, let user = session.user {
            if newPalmPrompt?.sessionToken == session.token {
                newPalmPrompt = nil
            }
            notify(PortNotice(port: port, kind: user.isBlank ? .blank : .unknown(user), date: now))
        }

        // Warteschlange: Bestätigtes nach Installed/, der Rest bleibt mit Grund
        if session.admitted, let profileId = session.profileId, let queue = queues[profileId] {
            var failed = session.failed
            for file in session.files where !session.installed.contains(file)
                && failed[file.lastPathComponent] == nil {
                failed[file.lastPathComponent] = .notConfirmed
            }
            queue.finishInstall(session: session.token, installed: session.installed, failed: failed)
            deviceManager.updateLastSync(for: profileId)
            if session.backupFinished {
                deviceManager.updateLastBackup(for: profileId)
            }
            if !session.installed.isEmpty {
                NotificationManager.shared.send(title: L10n.syncCompleteNotifTitle,
                                                body: L10n.syncCompleteNotifBody(session.installed.count))
            }
            session.failed = failed
        }

        let result: TabStatus.Result?
        if session.admitted {
            result = .finished(date: now, installed: session.installed.count, failed: session.failed.count)
        } else if let rejection = session.rejection {
            result = .rejected(date: now, rejection)
        } else if session.stopRequested {
            result = .stopped(date: now)
        } else if session.timedOut {
            result = .timedOut(date: now)
        } else if let message = session.errorMessage {
            result = .failed(date: now, message: message)
        } else {
            switch exit {
            case .status(0): result = nil
            case .status(let status): result = .failed(date: now, message: L10n.sessionExitStatus(Int(status)))
            case .signal(let signal): result = .failed(date: now, message: L10n.sessionCrashed(Int(signal)))
            }
        }

        // Anzeige: gezielter Tab bzw. der Tab, dem der Listener den Palm gab
        if let tabId = session.tabId {
            statuses[tabId]?.phase = .idle
            if let result {
                statuses[tabId]?.lastResult = result
            }
            if session.admitted, !session.restoreFiles.isEmpty {
                statuses[tabId]?.lastRestore = TabStatus.Restore(
                    installed: session.restoreDone - session.restoreFailed,
                    failed: session.restoreFailed + (session.restoreFiles.count - session.restoreDone),
                    total: session.restoreFiles.count)
            }
            if session.romRequested {
                var notReached = L10n.romNotReached
                if case .signal(let signal) = exit, !session.stopRequested {
                    notReached = L10n.sessionCrashed(Int(signal))
                }
                statuses[tabId]?.lastROMDump = session.romResult ?? .failed(message: notReached)
            }
            // auch eine abgebrochene Sicherung zeigt, was schon da ist
            if session.stage == .backingUp, session.backupTotal > 0 {
                statuses[tabId]?.lastBackup = TabStatus.Backup(saved: session.backupSaved,
                                                               unchanged: session.backupUnchanged,
                                                               failed: session.backupFailed,
                                                               complete: session.backupFinished)
                if !session.backupFinished { tabLog(tabId, L10n.logBackupIncomplete) }
            }
        }
        if case .listener = session.purpose {
            for tab in autoTabs(on: port) {
                if case .listening = statuses[tab.id]?.phase { statuses[tab.id]?.phase = .idle }
            }
            // Ein Listener hat keinen Tab, der das Ergebnis zeigt
            if session.tabId == nil, !session.stopRequested, case .failed(_, let message) = result {
                notify(PortNotice(port: port, kind: .failed(message), date: now))
            }
        }

        // Kette
        if case .tab(let tabId, true) = session.purpose {
            let success = session.admitted && session.failed.isEmpty
            if success, isChainStep(tabId) {
                activeChain?.run.stepSucceeded()
                continueChain()
            } else if !success {
                failChainStep(tabId, reason: chainFailureReason(result))
            }
        }

        // Anschluss wieder vergeben
        let delay: TimeInterval
        if session.connected {
            delay = Self.palmDisconnectDelay
        } else if case .failed = result {
            // Fehlermeldung, Fehler-Status oder Absturz: nicht sofort wieder,
            // sonst startet ein abstürzendes Werkzeug im Takt neu
            delay = Self.errorRetryDelay
        } else {
            delay = 0
        }
        scheduleRestart(port, after: delay)
    }

    private func chainFailureReason(_ result: TabStatus.Result?) -> String {
        switch result {
        case .finished(_, _, let failed): return L10n.chainReasonFilesFailed(failed)
        case .timedOut: return L10n.chainReasonTimeout(Self.chainStepTimeout / 60)
        case .failed(_, let message): return message
        case .rejected(_, let rejection):
            switch rejection {
            case .wrongPalm(let found, _), .unknown(let found): return L10n.chainReasonWrongPalm(found.name)
            }
        case .stopped: return L10n.chainStepStopped
        case nil: return L10n.chainStepStopped
        }
    }

    // MARK: - Log

    func portLabel(_ port: String) -> String {
        port == SyncTab.usbPort ? "USB" : (port as NSString).lastPathComponent
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func tabLog(_ tabId: UUID, _ text: String) {
        statuses[tabId]?.log.append("[\(Self.timeFormatter.string(from: Date()))] \(text)")
        let source = tabStore.tab(tabId).map { title(of: $0) } ?? "Tab"
        DebugLog.shared.log(text, source: source)
    }
}
