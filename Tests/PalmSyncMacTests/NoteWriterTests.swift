import Foundation
import Testing
import PalmSync
@testable import PalmSyncMac

@Test func noteBodyIsOneDivPerLine() {
    #expect(NoteSource.html(for: "Title") == "<div>Title</div>")
    #expect(NoteSource.html(for: "Title\n\nA & B <c>") == "<div>Title</div><div><br></div><div>A &amp; B &lt;c&gt;</div>")
    #expect(NoteSource.html(for: "") == "<div><br></div>")
}

@Test func memoSettingsDefaultToTheMacWinning() throws {
    let settings = MemoSyncSettings(enabled: true, folders: [.init(id: "f1", title: "Notes")])
    #expect(settings.conflicts == .macWins)
    let json = try JSONEncoder().encode(settings)
    let back = try JSONDecoder().decode(MemoSyncSettings.self, from: json)
    #expect(back == settings)
    // a profile from before the policy was stored
    let old = try JSONDecoder().decode(MemoSyncSettings.self, from: Data(#"{"enabled":false,"folders":[]}"#.utf8))
    #expect(old.conflictPolicy == nil && old.conflicts == .macWins)
}

@Test func noteSourceAccessStatusIsOneOfTheFour() {
    // no Apple event is sent; the answer depends on this machine
    let status = NoteSource().accessStatus
    #expect([.allowed, .denied, .notDetermined, .unknown].contains(status))
}
