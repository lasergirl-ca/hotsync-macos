import Foundation
import Testing
@testable import PalmSync

/// MemoDB.pdb and MemosDB-PMem.pdb are written by Fixtures/generate-memos.c
/// with pilot-link's pack_Memo and pack_MemoAppInfo.
private func memoFixture(_ name: String, subdirectory: String = "Fixtures") throws -> PalmDatabase {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "pdb", subdirectory: subdirectory))
    return try PalmDatabase(data: Data(contentsOf: url))
}

// MARK: - Codec

@Test func memoFixturesRoundTripThroughTheCodec() throws {
    for (name, family, count) in [("MemoDB", PalmPIMFamily.classic, 7), ("MemosDB-PMem", .garnet, 8)] {
        let db = try memoFixture(name)
        #expect(db.name == family.databaseName(.memos))
        #expect(db.creator == family.creator(.memos))
        #expect(db.records.count == count, Comment(rawValue: name))
        for record in db.records {
            let memo = try PalmMemo(data: record.data)
            #expect(memo.encode() == record.data, "\(name) record \(String(record.uniqueID, radix: 16))")
            #expect(family.readsBack(record.data, kind: .memos))
            #expect(try family.garnetRecord(record.data, kind: .memos) == record.data)
        }
        let info = try MemoAppInfo(data: try #require(db.appInfo))
        #expect(info.categories.names.prefix(4) == ["Unfiled", "Business", "Personal", "Recipes"])
        #expect(info.internalBytes.count == MemoAppInfo.classicInternalSize)
        #expect(info.sortByAlpha)
        #expect(info.encode() == db.appInfo)
        #expect(family.categories(ofAppInfo: db.appInfo!, kind: .memos)?.names[3] == "Recipes")
    }
}

@Test func memoFixtureRecordsReadAsExpected() throws {
    let db = try memoFixture("MemosDB-PMem")
    let shopping = try PalmMemo(data: db.records[0].data)
    #expect(shopping.text == "Shopping" && shopping.title == "Shopping" && db.records[0].category == 2)
    let cafe = try PalmMemo(data: db.records[1].data)
    #expect(cafe.text == "Café list\n\nCrème brûlée – 2 €\nStraße 7")
    #expect(cafe.title == "Café list")
    #expect(try PalmMemo(data: db.records[2].data).text == "" && db.records[2].attributes & 0x40 != 0)
    #expect(db.records[3].attributes & PalmDatabase.Record.secret != 0)
    #expect(db.records[4].isDeleted)
    let big = try PalmMemo(data: db.records[5].data)
    #expect(big.byteCount == 4096 && db.records[5].data.count == 4097)
    #expect(try PalmMemo(data: db.records[6].data).text == "Ends with a newline\n")
    #expect(try PalmMemo(data: db.records[7].data).byteCount == 20480)
}

@Test func aMemoMustEndAtItsNUL() {
    #expect(throws: PalmFormatError.self) { try PalmMemo(data: Data("no terminator".utf8)) }
    #expect(throws: PalmFormatError.self) { try PalmMemo(data: Data([0x41, 0x00, 0x42])) }
    #expect(throws: PalmFormatError.self) { try PalmMemo(data: Data()) }
}

// MARK: - Real Palms

/// MemoDB.pdb backed up from an m515 (Palm OS 4.1): the four memos Palm
/// ships (Handheld Basics …); MemosDB-PMem.pdb from a T|X (Palm OS 5.4.9),
/// empty but for its AppInfo block.
@Test func deviceMemoDatabasesRoundTrip() throws {
    let m515 = try memoFixture("MemoDB", subdirectory: "Fixtures/device")
    #expect(m515.creator == "memo" && m515.records.count == 4)
    #expect(PalmPIMFamily.family(ofDatabase: m515.name) == .classic && PalmPIMFamily.kind(ofDatabase: m515.name) == .memos)
    for record in m515.records {
        #expect(PalmPIMFamily.classic.readsBack(record.data, kind: .memos), Comment(rawValue: "\(record.uniqueID)"))
    }
    #expect(try m515.records.map { try PalmMemo(data: $0.data).title }
            == ["Handheld Basics", "Four Ways to Enter Text", "Download Free Applications", "Power Tips"])
    let m515Info = try MemoAppInfo(data: try #require(m515.appInfo))
    #expect(m515Info.categories.names.prefix(3) == ["Unfiled", "Business", "Personal"])
    #expect(m515Info.internalBytes.count == MemoAppInfo.classicInternalSize && !m515Info.sortByAlpha)
    #expect(m515Info.encode() == m515.appInfo)
    // a Memo Pad memo is within Memo Pad's limit and comes back unchanged
    for record in m515.records {
        let memo = try PalmMemo(data: record.data)
        #expect(ClassicMemo.limit(memo) == memo)
        #expect(try PalmPIMFamily.classic.deviceRecord(record.data, kind: .memos) == record.data)
    }

    let tx = try memoFixture("MemosDB-PMem", subdirectory: "Fixtures/device")
    #expect(tx.creator == "PMem" && tx.records.isEmpty)
    #expect(PalmPIMFamily.family(ofDatabase: tx.name) == .garnet)
    let txInfo = try MemoAppInfo(data: try #require(tx.appInfo))
    #expect(txInfo.internalBytes.count == MemoAppInfo.garnetInternalSize)
    #expect(txInfo.encode() == tx.appInfo)
    #expect(MemoAppInfo().encode().count == tx.appInfo?.count)
}

// MARK: - What a memo holds

@Test func limitedTextIsWhatNotesAndThePalmBothHold() {
    let messy = "\r\n  Title with  spaces \t\r\nline two\t\ttabs   \n\n\nthird → arrow\n\n"
    let limited = PalmMemo.limited(messy, maxBytes: 4096)
    #expect(limited == "Title with spaces\nline two tabs\n\n\nthird ? arrow")
    #expect(PalmMemo.limited(limited, maxBytes: 4096) == limited)
    #expect(PalmMemo.limited("", maxBytes: 10) == "" && PalmMemo.limited("\n \n", maxBytes: 10) == "")
    // cut on a line break when one is near, else mid-line; never over the limit
    let lines = (1...100).map { "line \($0) of the long memo" }.joined(separator: "\n")
    let cut = PalmMemo.limited(lines, maxBytes: 500)
    #expect(PalmText.bytes(cut).count <= 500 && cut.hasSuffix("of the long memo") && !cut.hasSuffix("\n"))
    let oneLine = String(repeating: "x", count: 5000)
    #expect(PalmText.bytes(PalmMemo.limited(oneLine, maxBytes: 4096)).count == 4096)
    // the cut can leave a trailing space: gone, and still within the limit
    #expect(PalmMemo.limited("abc def", maxBytes: 4) == "abc")
    for text in [messy, lines, oneLine, "ü" + String(repeating: "é", count: 5000)] {
        let once = PalmMemo.limited(text, maxBytes: 4096)
        #expect(PalmMemo.limited(once, maxBytes: 4096) == once)
        #expect(PalmText.bytes(once).count <= 4096)
    }
}

@Test func theFamilyLimitsAMemoToItsApplication() throws {
    let db = try memoFixture("MemosDB-PMem")
    let big = try PalmMemo(data: db.records[7].data)   // 20 KB
    #expect(PalmPIMFamily.garnet.limit(big) == big)
    let onMemoPad = PalmPIMFamily.classic.limit(big)
    #expect(onMemoPad.byteCount == ClassicMemo.textLimit && big.text.hasPrefix(onMemoPad.text))
    #expect(try PalmMemo(data: try PalmPIMFamily.classic.deviceRecord(big.encode(), kind: .memos)) == onMemoPad)
    #expect(PalmPIMFamily.garnet.memoTextLimit == 32767 && PalmPIMFamily.classic.memoTextLimit == 4096)

    // the Mac items through the writer's limit and `limited`
    let item = MacSyncItem(key: MacKey(seriesID: "n1"), item: SyncedMemo(text: big.text, category: "Business"), palmRecord: big.encode())
    #expect(PalmPIMFamily.garnet.limited([item]) == [item])
    let classic = PalmPIMFamily.classic.limited([item])[0]
    let cut = PalmMemo.limited(big.text, maxBytes: ClassicMemo.textLimit)
    #expect(big.text.hasPrefix(cut) && !cut.hasSuffix("\n") && PalmText.bytes(cut).count <= ClassicMemo.textLimit)
    #expect(classic.item.text == cut && classic.palmRecord == PalmMemo(text: cut).encode() && classic.item.category == "Business")
    #expect(PalmPIMFamily.classic.memoLimit(item.item) == classic.item)
}

// MARK: - Builder

private let folders: [MemosBuilder.MacFolder] = [.init(id: "f1", title: "Notes"), .init(id: "f2", title: "Recipes and other long things")]

@Test func memosBuilderMakesADatabaseWithAFolderPerCategory() throws {
    let builder = MemosBuilder(options: .init(folders: folders))
    let notes = [
        MacNote(id: "n1", folderID: "f1", text: "Zebra\nlast by title\n"),
        MacNote(id: "n2", folderID: "f2", text: "Apple pie\n\n3 apples   and  sugar\n"),
        MacNote(id: "n3", folderID: "f1", text: "\n\n"),
        MacNote(id: "n4", folderID: "gone", text: "Unfiled note"),
    ]
    let (db, report) = builder.build(notes)
    #expect(db.name == "MemosDB-PMem" && db.creator == "PMem")
    #expect(report.records == 3 && report.emptySkipped == 1 && report.truncated == 0)
    #expect(report.categories == ["Unfiled", "Notes", "Recipes and oth"])
    #expect(try db.records.map { try PalmMemo(data: $0.data).title } == ["Apple pie", "Unfiled note", "Zebra"])
    #expect(db.records.map(\.category) == [2, 0, 1])
    #expect(try PalmMemo(data: db.records[0].data).text == "Apple pie\n\n3 apples and sugar")
    let info = try MemoAppInfo(data: try #require(db.appInfo))
    #expect(info.categories.names[2] == "Recipes and oth" && info.internalBytes.count == MemoAppInfo.garnetInternalSize)

    // the same through a classic Palm: MemoDB with a 4-byte AppInfo tail
    let classic = PalmPIMFamily.classic.deviceDatabase(db, kind: .memos,
                                                       appInfo: PalmPIMFamily.classic.classicAppInfo(kind: .memos, existing: nil, categories: info.categories))
    #expect(classic.name == "MemoDB" && classic.creator == "memo")
    #expect(try MemoAppInfo(data: classic.appInfo!).internalBytes.count == MemoAppInfo.classicInternalSize)
    #expect(classic.records.map(\.data) == db.records.map(\.data))
    #expect(try PalmDatabase(data: classic.encode()) == classic)
}

@Test func memosBuilderCutsLongNotesAndSaysSo() {
    let builder = MemosBuilder(options: .init(folders: folders, maxBytes: ClassicMemo.textLimit))
    let (db, report) = builder.build([MacNote(id: "n1", folderID: "f1", text: String(repeating: "long line\n", count: 1000))])
    #expect(report.truncated == 1 && report.warnings.count == 1)
    #expect(db.records[0].data.count <= ClassicMemo.textLimit + 1)
}

// MARK: - Through the engine

@Test func syncedMemoRoundTripsThroughTheRecord() throws {
    let record = PalmMemo(text: "Title\nbody")
    let synced = SyncedMemo(record, category: "Notes")
    #expect(synced.title == "Title" && synced.text == "Title\nbody")
    var edited = synced
    edited.text = "Title\nnew body"
    let back = try PalmMemo(data: edited.palmBytes(over: record.encode()))
    #expect(back.text == "Title\nnew body")
    #expect(SyncedMemo(back, category: "Notes") == edited)
    #expect(SyncedMemo(text: String(repeating: "t", count: 70), category: "").title?.count == 58)
    #expect(synced.shiftingDates(by: 3) == synced)
}

@Test func memosSlowSyncPairsByTitleThenFastSyncMerges() throws {
    let builder = MemosBuilder(options: .init(folders: folders))
    let engine = SyncEngine<SyncedMemo>()
    let categories = ["Unfiled", "Notes", "Business"]
    let mac = builder.syncItems([MacNote(id: "n1", folderID: "f1", text: "Shopping\nmilk\neggs\n"),
                                 MacNote(id: "n2", folderID: "f1", text: "Only on the Mac")])
    let palmOnly = PalmRecordIn(id: 0x4010, category: 2, data: PalmMemo(text: "Palm only\nwritten on the road").encode())
    let palm = PalmSnapshot.all([PalmRecordIn(id: 0x4001, category: 1, data: PalmMemo(text: "Shopping\nmilk").encode()), palmOnly])
    let plan = try engine.plan(palm: palm, palmCategories: categories, mac: mac, mirror: MemoMirror(pcID: 7))

    // Shopping paired by title (no base: the Mac's text wins), "Only on the
    // Mac" new on the Palm, "Palm only" new on the Mac in category Business
    #expect(plan.log.contains("Shopping: found on both sides, paired"))
    #expect(plan.palmWrites.count == 2)
    #expect(try PalmMemo(data: plan.palmWrites.first { $0.id == 0x4001 }!.record).text == "Shopping\nmilk\neggs")
    #expect(plan.macCreates.count == 1 && plan.macCreates[0].item == SyncedMemo(text: "Palm only\nwritten on the road", category: "Business"))
    #expect(plan.conflicts.isEmpty)

    // the whole database: by title, the Palm's AppInfo tail kept, a new ID above the Palm's
    var existing = MemoAppInfo(categories: CategoryAppInfo(names: categories))
    existing.internalBytes = Data([0, 0, 1, 0])
    let (db, palmIDs, _) = plan.palmDatabase(appInfo: existing)
    #expect(try db.records.map { try PalmMemo(data: $0.data).title } == ["Only on the Mac", "Palm only", "Shopping"])
    #expect(palmIDs.count == 1 && palmIDs.values.first == 0x4011)
    #expect(try MemoAppInfo(data: db.appInfo!).sortByAlpha)

    // a fast sync after that: the Palm edits the body, the Mac the category
    let mirror = plan.mirror(after: MemoMirror(pcID: 7), palmIDs: palmIDs, macKeys: [plan.macCreates[0].entry: MacKey(seriesID: "n3")])
    #expect(mirror.entries.count == 3)
    let palmEdit = PalmRecordIn(id: 0x4001, attributes: 0x40, category: 1, data: PalmMemo(text: "Shopping\nmilk\neggs\nbread").encode())
    let macMoved = builder.syncItems([MacNote(id: "n1", folderID: "f2", text: "Shopping\nmilk\neggs\n"),
                                      MacNote(id: "n2", folderID: "f1", text: "Only on the Mac"),
                                      MacNote(id: "n3", folderID: "f1", text: "Palm only\nwritten on the road")])
    let next = try engine.plan(palm: .modified([palmEdit]), palmCategories: categories + ["Recipes and oth"], mac: macMoved, mirror: mirror)
    #expect(next.conflicts.isEmpty)
    #expect(next.macUpdates.count == 1 && next.macUpdates[0].changed == [.text])
    #expect(next.macUpdates[0].item.text == "Shopping\nmilk\neggs\nbread" && next.macUpdates[0].item.category == "Recipes and oth")
    // the Palm gets the moved memo in the new category, and "Palm only",
    // which the Mac filed under Notes
    #expect(next.palmWrites.map { "\($0.id ?? 0):\($0.category)" } == ["16385:3", "16400:1"])

    // both edit the text: a conflict, the policy decides
    let macEdit = builder.syncItems([MacNote(id: "n1", folderID: "f1", text: "Shopping\nmilk\neggs\ncheese")])
    var palmWins = engine
    palmWins.conflictPolicy = .palmWins
    let clash = try palmWins.plan(palm: .modified([palmEdit]), palmCategories: categories, mac: macEdit + Array(macMoved[1...]), mirror: mirror)
    #expect(clash.conflicts.count == 1 && clash.conflicts[0].field == "text" && clash.conflicts[0].resolution == .palmWins)
    #expect(clash.macUpdates[0].item.text == "Shopping\nmilk\neggs\nbread")
}

@Test func aNoteLongerThanAMemoRoundTripsUnchanged() throws {
    // a 20 KB note on a classic Palm: the Palm gets 4 KB, and the next sync
    // sees no change on either side
    let builder = MemosBuilder(options: .init(folders: folders, maxBytes: PalmPIMFamily.classic.memoTextLimit))
    let long = MacNote(id: "n1", folderID: "f1", text: (1...2000).map { "line \($0)" }.joined(separator: "\n"))
    let mac = PalmPIMFamily.classic.limited(builder.syncItems([long]))
    let engine = SyncEngine<SyncedMemo>()
    let plan = try engine.plan(palm: .all([]), palmCategories: ["Unfiled", "Notes"], mac: mac, mirror: MemoMirror(pcID: 7))
    #expect(plan.palmWrites.count == 1 && plan.palmWrites[0].record.count <= ClassicMemo.textLimit + 1)
    let mirror = plan.mirror(after: MemoMirror(pcID: 7), palmIDs: [0: 1], macKeys: [:])
    let onPalm = PalmRecordIn(id: 1, category: 1, data: plan.palmWrites[0].record)
    let again = try engine.plan(palm: .all([onPalm]), palmCategories: ["Unfiled", "Notes"], mac: mac, mirror: mirror)
    #expect(again.isEmpty)
}

@Test func memoDatabasesAreKnownToTheFamily() {
    #expect(PalmPIMFamily.garnet.databaseName(.memos) == "MemosDB-PMem" && PalmPIMFamily.garnet.creator(.memos) == "PMem")
    #expect(PalmPIMFamily.classic.databaseName(.memos) == "MemoDB" && PalmPIMFamily.classic.creator(.memos) == "memo")
    #expect(PalmPIMFamily.kind(ofDatabase: "MemoDB") == .memos && PalmPIMFamily.kind(ofDatabase: "MemosDB-PMem") == .memos)
    #expect(PalmPIMFamily.Kind.allCases.contains(.memos))
}
