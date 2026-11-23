import Foundation
import PalmSync

/// Applies the Mac side of a memos sync plan to Notes.app. A note's body
/// is rewritten only when the Palm changed the text, as plain text; a
/// note moves folders only when the Palm changed the category.
public struct NoteWriter {
    public struct Result: Equatable, Sendable {
        public var createdKeys: [Int: MacKey] = [:]
        public var updated = 0
        public var deleted = 0
        public var failures: [String] = []
        /// Entry indices of creates and updates that did not happen, so the
        /// mirror keeps the old base for them and they are retried.
        public var failedEntries: [Int] = []
    }

    public let source: NoteSource
    /// What the Palm holds of a note's text: the Mac's note is seen
    /// through it before the comparison, so a note is never rewritten for
    /// what the Palm could not hold in the first place.
    public let limit: @Sendable (SyncedMemo) -> SyncedMemo
    /// Which Notes folder a Palm category goes to.
    public let folderForCategory: (String) -> String?
    /// Where a new note goes when no folder matches its category.
    public let fallback: String?

    public init(source: NoteSource, limit: @escaping @Sendable (SyncedMemo) -> SyncedMemo, fallback: String? = nil,
                folderForCategory: @escaping (String) -> String?) {
        self.source = source
        self.limit = limit
        self.fallback = fallback
        self.folderForCategory = folderForCategory
    }

    public func apply(_ plan: MemoSyncPlan) -> Result {
        var result = Result()

        for change in plan.macCreates {
            guard let folder = folderForCategory(change.item.category) ?? fallback else {
                result.failures.append("\(change.item.title ?? "?"): no folder for category \(change.item.category)")
                result.failedEntries.append(change.entry)
                continue
            }
            do {
                let id = try source.createNote(text: change.item.text, in: folder)
                result.createdKeys[change.entry] = MacKey(seriesID: id)
            } catch {
                result.failures.append("\(change.item.title ?? "?"): \(error.localizedDescription)")
                result.failedEntries.append(change.entry)
            }
        }

        for change in plan.macUpdates {
            do {
                guard let key = change.key, let note = try source.note(key.seriesID) else {
                    result.failures.append("\(change.item.title ?? "?"): not found on the Mac any more")
                    result.failedEntries.append(change.entry)
                    continue
                }
                let now = limit(SyncedMemo(text: note.text, category: change.item.category))
                if change.item.differs(from: now, in: .text) { try source.setText(change.item.text, of: note.id) }
                if change.changed.contains(.category), let folder = folderForCategory(change.item.category), folder != note.folderID {
                    try source.move(note.id, to: folder)
                }
                result.updated += 1
            } catch {
                result.failures.append("\(change.item.title ?? "?"): \(error.localizedDescription)")
                result.failedEntries.append(change.entry)
            }
        }

        for key in plan.macDeletes {
            do {
                guard try source.note(key.seriesID) != nil else { continue }
                try source.deleteNote(key.seriesID)
                result.deleted += 1
            } catch {
                result.failures.append("\(key.seriesID): \(error.localizedDescription)")
            }
        }
        return result
    }
}
