import ApplicationServices
import Foundation
import PalmSync

/// Notes.app as the sync sees it: the folders to choose from and their
/// notes as MacNotes, plain text.
///
/// Notes has no public framework. Its AppleScript dictionary is the one
/// supported way to read and write notes, so this talks to Notes.app
/// through `osascript` running JavaScript for Automation: a subprocess,
/// so the app's main thread never blocks on an Apple event (NSAppleScript
/// and OSAScript have to run there), with the arguments passed as argv
/// (never spliced into the script) and the answer as one JSON document on
/// stdout. macOS attributes a child's Apple events to the app that spawned
/// it, so the Automation permission is HotSync's: the first call puts up
/// the system's prompt ("HotSync wants access to control Notes"), after
/// that it is kept under Privacy & Security › Automation. The usage text
/// for the prompt is NSAppleEventsUsageDescription in the Info.plist.
///
/// What does not travel: a note's formatting, attachments, images,
/// checklists, tables and links. `plaintext` is what Notes shows of them;
/// a note edited on the Palm comes back as plain text, one `<div>` per
/// line, and loses what it had.
public final class NoteSource: Sendable {
    public struct Folder: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let account: String

        public init(id: String, title: String, account: String) {
            self.id = id
            self.title = title
            self.account = account
        }
    }

    /// What the system says about controlling Notes from this app.
    public enum AccessStatus: Equatable, Sendable {
        case allowed
        case denied
        /// Not asked yet: the first call puts up the prompt.
        case notDetermined
        /// Notes.app is not running, so the system cannot say; the first
        /// call starts it and then either works or prompts.
        case unknown
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// Automation denied: the user said no, or it is off in
        /// System Settings.
        case notPermitted
        case folderMissing(String)
        case scriptFailed(String)
        case badAnswer

        public var errorDescription: String? {
            switch self {
            case .notPermitted: return "no permission to control Notes (System Settings › Privacy & Security › Automation)"
            case .folderMissing(let id): return "Notes folder \(id) no longer exists"
            case .scriptFailed(let text): return "Notes: \(text)"
            case .badAnswer: return "Notes gave no usable answer"
            }
        }
    }

    public static let bundleID = "com.apple.Notes"

    public init() {}

    // MARK: Permission

    public var accessStatus: AccessStatus {
        var target = AEAddressDesc()
        let id = Data(Self.bundleID.utf8)
        let made = id.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, id.count, &target) }
        guard made == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown
        }
    }

    /// Not known to be denied; the sync goes ahead and the call decides.
    public var hasAccess: Bool { accessStatus != .denied }

    /// Asks Notes for its name: starts it if need be and puts up the
    /// Automation prompt the first time. True when Notes answered.
    public func requestAccess() -> Bool {
        ((try? run(#"function run() { return JSON.stringify(Application("Notes").name()); }"#)) as? String) == "Notes"
    }

    // MARK: Reading

    /// Folders Notes lists but a sync must not touch: Recently Deleted,
    /// which Notes names "Trash" to a script and shows only while it has
    /// something in it. A deleted note stays there for 30 days and is
    /// still found by its id.
    static let trashNames = ["Trash", "Recently Deleted"]

    /// Every folder of every account, as Notes lists them, without the
    /// Recently Deleted one.
    public func folders() throws -> [Folder] {
        let script = #"""
        function run(argv) {
            const N = Application("Notes");
            const out = [];
            for (const account of N.accounts()) {
                const name = account.name();
                for (const folder of account.folders()) {
                    const title = folder.name();
                    if (argv.indexOf(title) >= 0) continue;
                    out.push({ id: folder.id(), title: title, account: name });
                }
            }
            return JSON.stringify(out);
        }
        """#
        guard let list = try run(script, Self.trashNames) as? [[String: Any]] else { throw Failure.badAnswer }
        return list.compactMap { f in
            guard let id = f["id"] as? String, let title = f["title"] as? String else { return nil }
            return Folder(id: id, title: title, account: f["account"] as? String ?? "")
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Every note of the given folders as plain text, each folder's in one
    /// round trip. A folder that no longer exists is an error: the sync
    /// must not take it for "everything deleted".
    public func notes(in folderIDs: [String]) throws -> [MacNote] {
        guard !folderIDs.isEmpty else { return [] }
        let script = #"""
        function run(argv) {
            const N = Application("Notes");
            const out = { folders: [], missing: [] };
            for (const id of argv) {
                const folder = N.folders.byId(id);
                let notes = [];
                try {
                    const ids = folder.notes.id(), texts = folder.notes.plaintext();
                    for (let i = 0; i < ids.length; i++) notes.push({ id: ids[i], text: texts[i] });
                } catch (e) {
                    out.missing.push(id);
                    continue;
                }
                out.folders.push({ id: id, notes: notes });
            }
            return JSON.stringify(out);
        }
        """#
        guard let answer = try run(script, folderIDs) as? [String: Any],
              let folders = answer["folders"] as? [[String: Any]] else { throw Failure.badAnswer }
        if let missing = (answer["missing"] as? [String])?.first { throw Failure.folderMissing(missing) }
        var notes: [MacNote] = []
        for folder in folders {
            guard let folderID = folder["id"] as? String, let list = folder["notes"] as? [[String: Any]] else { continue }
            for n in list {
                guard let id = n["id"] as? String, let text = n["text"] as? String else { continue }
                notes.append(MacNote(id: id, folderID: folderID, text: text))
            }
        }
        return notes
    }

    /// One note by its Notes identifier; nil when it is gone, Recently
    /// Deleted included.
    public func note(_ id: String) throws -> MacNote? {
        let script = #"""
        function run(argv) {
            const N = Application("Notes");
            const note = N.notes.byId(argv[0]);
            try {
                const folder = note.container();
                if (argv.indexOf(folder.name(), 1) >= 1) return "null";
                return JSON.stringify({ id: note.id(), folder: folder.id(), text: note.plaintext() });
            } catch (e) {
                return "null";
            }
        }
        """#
        guard let answer = try run(script, [id] + Self.trashNames) else { return nil }
        guard let n = answer as? [String: Any], let text = n["text"] as? String else { throw Failure.badAnswer }
        return MacNote(id: id, folderID: n["folder"] as? String ?? "", text: text)
    }

    // MARK: Writing

    /// A note's body for plain text: one `<div>` per line, a blank line as
    /// `<div><br></div>`, the first line being what Notes takes as the
    /// title. Notes collapses runs of spaces as HTML does; `PalmMemo
    /// .limited` reads text the same way, so what is written compares
    /// equal to what comes back.
    public static func html(for text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard !line.isEmpty else { return "<div><br></div>" }
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<div>\(escaped)</div>"
        }.joined()
    }

    /// A new note in a folder; its Notes identifier.
    public func createNote(text: String, in folderID: String) throws -> String {
        let script = #"""
        function run(argv) {
            const N = Application("Notes");
            const folder = N.folders.byId(argv[0]);
            const note = N.Note({ body: argv[1] });
            folder.notes.push(note);
            return JSON.stringify(note.id());
        }
        """#
        guard let id = try run(script, [folderID, Self.html(for: text)]) as? String else { throw Failure.badAnswer }
        return id
    }

    public func setText(_ text: String, of id: String) throws {
        let script = #"""
        function run(argv) {
            const N = Application("Notes");
            N.notes.byId(argv[0]).body = argv[1];
            return "true";
        }
        """#
        _ = try run(script, [id, Self.html(for: text)])
    }

    public func move(_ id: String, to folderID: String) throws {
        let script = #"""
        function run(argv) {
            const N = Application("Notes");
            N.move(N.notes.byId(argv[0]), { to: N.folders.byId(argv[1]) });
            return "true";
        }
        """#
        _ = try run(script, [id, folderID])
    }

    /// Into Recently Deleted, where Notes keeps it for 30 days.
    public func deleteNote(_ id: String) throws {
        let script = #"""
        function run(argv) {
            const N = Application("Notes");
            N.delete(N.notes.byId(argv[0]));
            return "true";
        }
        """#
        _ = try run(script, [id])
    }

    // MARK: osascript

    /// Runs a JavaScript for Automation script whose `run(argv)` returns a
    /// JSON document, and gives back what the document holds.
    @discardableResult
    func run(_ script: String, _ arguments: [String] = []) throws -> Any? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-"] + arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw Failure.scriptFailed(error.localizedDescription) }
        // the script goes in through stdin; both outputs are drained while
        // it runs, so a long answer cannot stall the process
        let group = DispatchGroup()
        var out = Data(), err = Data()
        group.enter()
        DispatchQueue.global().async { out = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        group.wait()
        let errorText = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            if errorText.contains("-1743") { throw Failure.notPermitted }
            throw Failure.scriptFailed(errorText.isEmpty ? "osascript exited with \(process.terminationStatus)" : errorText)
        }
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw Failure.badAnswer
        }
        return json is NSNull ? nil : json
    }
}

/// What the user chose for a Palm: which Notes folders go on it, each
/// its own category. Stored with the device profile.
public struct MemoSyncSettings: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public var enabled: Bool
    public var folders: [Choice]
    public var conflictPolicy: ConflictPolicy?

    public init(enabled: Bool = false, folders: [Choice] = [], conflictPolicy: ConflictPolicy? = nil) {
        self.enabled = enabled
        self.folders = folders
        self.conflictPolicy = conflictPolicy
    }

    public var conflicts: ConflictPolicy { conflictPolicy ?? .macWins }
}

/// One run of the one-way memos sync, checked by reading it back.
public struct MemoSyncRun {
    public let notes: Int
    public let database: PalmDatabase
    public let report: MemosBuilder.Report

    public enum Failure: Error {
        case noAccess
        case doesNotReadBack
    }

    public init(settings: MemoSyncSettings, source: NoteSource, family: PalmPIMFamily = .garnet) throws {
        guard source.hasAccess else { throw Failure.noAccess }
        let found: [MacNote]
        do { found = try source.notes(in: settings.folders.map(\.id)) } catch NoteSource.Failure.notPermitted {
            throw Failure.noAccess
        }
        notes = found.count
        let builder = MemosBuilder(options: .init(folders: settings.folders.map { .init(id: $0.id, title: $0.title) },
                                                  maxBytes: family.memoTextLimit))
        let (built, builtReport) = builder.build(found)
        report = builtReport
        let categories = (try? MemoAppInfo(data: built.appInfo ?? Data()))?.categories ?? CategoryAppInfo()
        database = family.deviceDatabase(built, kind: .memos,
                                         appInfo: family.classicAppInfo(kind: .memos, existing: nil, categories: categories))

        let image = database.encode()
        guard let check = try? PalmDatabase(data: image), check == database,
              check.records.allSatisfy({ family.readsBack($0.data, kind: .memos) }),
              let appInfo = check.appInfo, family.categories(ofAppInfo: appInfo, kind: .memos) != nil else {
            throw Failure.doesNotReadBack
        }
    }

    @discardableResult
    public func write(to url: URL) throws -> Int {
        let image = database.encode()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: url, options: .atomic)
        return image.count
    }
}
