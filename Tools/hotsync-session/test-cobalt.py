#!/usr/bin/env python3
"""Tool-level test of the Cobalt DLP layer: a fake Palm OS Cobalt handheld
over NET on 127.0.0.1 answers the real hotsync-session with the replies
Zoë's T|X (Cobalt 6.1) gave on 2026-11-26 to the read-only probe.

    python3 -I Tools/hotsync-session/test-cobalt.py .build/release/hotsync-session

The fake Palm is keyed by the exact request bytes the T|X saw, so the test
also checks that the tool frames every Cobalt request byte for byte as the
probe did (the probe was hand-built in Python; this is the C framing). The
reply bytes are device data from the probe log (no personal data: database
and column names, categories, sync ids of a fresh store). Two replies are
synthetic and marked as such: an unknown-handle error and a long-form
argument header, both never seen from the device but part of the framing.
The NET handshake and the classic replies (ReadSysInfo, ReadUserInfo,
OpenConduit, EndOfSync) come from test-relay.py.

A reply given as a tuple is several messages sent one after the other for
one request (0xAE answers with the row stream and then an empty F0 AE)."""

import importlib.util
import os
import socket
import struct
import sys
import threading

# test-relay.py has a hyphen in its name: load it by path
_spec = importlib.util.spec_from_file_location(
    "test_relay", os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-relay.py"))
_relay = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_relay)
Net, PALM_HELLO, PALM_MSG2, PALM_MSG3 = _relay.Net, _relay.PALM_HELLO, _relay.PALM_MSG2, _relay.PALM_MSG3
dlp_reply, free_port, start_tool = _relay.dlp_reply, _relay.free_port, _relay.start_tool

# ReadSysInfo as the T|X answers it: ROM 6.1 in argument 0x20 and, as a
# second argument 0x21, DLP 2.1 (what the Cobalt commands need announced),
# compatibility 1.0, 64 KiB records.
SYSINFO = struct.pack(">II", 0x06103021, 0) + b"\0" + bytes([4]) + b"ABCD"
DLP_VERSION = struct.pack(">HHHHI", 2, 1, 1, 0, 0xFFFF)
SYSINFO_REPLY = bytes([0x92, 2, 0, 0, 0x20, len(SYSINFO)]) + SYSINFO + bytes([0x21, len(DLP_VERSION)]) + DLP_VERSION
NAME = b"Cobalt Palm\0"
USERINFO = struct.pack(">III", 4711, 0, 0) + bytes(16) + bytes([len(NAME), 0]) + NAME

# request hex -> list of reply payloads (hex), handed out in order; the last
# one repeats. Every pair below is what the probe sent and the T|X answered,
# except the two marked synthetic.
REPLAY = {
    # 0x7F list, flags 0x0007: 18 databases, short-form argument (0x043E bytes)
    "707f010020020007": [
        "f07f01000000a000043e0000001280444154416164727310080040000100003a040000000007ea0b1b0102010000003a04"
        "00000100000001340000000b41646472657373444253000080444154416461747310080040000600003a040000000007ea"
        "0b1b0102020000003a0400000100000000020000000c44617465426f6f6b444253000080444154416d656d731008004000"
        "0600003a040000000007ea0b1b0102020000003a040000010000000002000000084d656d6f4442530000804441544173796e"
        "6330000040000007ea0b1b01041e0007ea0b1b01041e0000003a0400000100000000010000000e547275737465644474496e"
        "666f0000804441544173796e6310000040000007ea0b1b01041e0007ea0b1b01041e0000003a0400000100000000010000"
        "000c4465736b746f70496e666f0000804441544173796e6330000040000007ea0b1b01041d0007ea0b1b01041e0000003a04"
        "000001000000000300000011417070726f76656453796e63417070730000804441544174646f7310080040000600000b1b"
        "01041d0007ea0b1b0102020000003a04000001000000000200000008546f446f44425300008044415441747a646290000040"
        "000100000b1b01041d0000000b1b0102020000003a0400000100000000020000000a74696d657a6f6e657300008064617461"
        "7374737410080040000007ea0b1b0101390007ea0b1b010a050000003a04000001000000000e0000000973657474696e6773"
        "0000806c6f672073796e6310000040000007ea0b1b01041f0007ea0b1b010a060000003a0400000100000000070000000b48"
        "6f7453796e634c6f67000080706368637274737691400040000000000b1b01041f0000000b1b010a060000003a0400000100"
        "000000020000000c5061746368436f6e666967000080706c6764636e637310000040000007ea0b1b0102000007ea0b1b0102"
        "010000003a04000001000000000c0000000b436e63506c7567696e7300008070726664636e637310280040000007ea0b1b01"
        "02000007ea0b1b01041e0000003a0400000100000001f20000000c436e6350726f66696c657300008076616c746175746890"
        "000040000000000b1b0102000000000b1b01041e0000003a04000001000000002300000011414d5f53746f726167655f5661"
        "756c7400008076616c74617a6d5f90080040000000000b1b0102000000000b1b01041e0000003a0400000100000000010000"
        "0011415a4d5f4261636b75705f5661756c7400008076616c74617a6d5f90000040000000000b1b0102000000000b1b01041e"
        "0000003a0400000100000000170000000a415a4d5f5661756c7400008076616c74646d677210080040000000000b1b010200"
        "0000000b1b01041e0000003a0400000100000000030000000e446174614d67725f5661756c7400008076616c74706b697390"
        "080040000000000b1b0102000000000b1b01041e0000003a0400000100000000860000000d436572744d67725661756c7400"
        "00"],
    # 0x81 open AddressDBS, creator adrs, mode 1, no token -> handle 1
    "70810100201b6164727300000000000100000000000b4164647265737344425300": ["f08101000000200101"],
    # 0x71 tables of handle 1: first the T|X's tiny-form reply, then the same
    # argument in the long form (0x60 00 u32), synthetic, for the framing
    "70710100200101": [
        "f07101000000203b000000020000003b0000001441646472657373426f6f6b4442536368656d6100000000010000001341"
        "646472657373426f6f6b417070496e666f00",
        "f0710100000060000000003b000000020000003b0000001441646472657373426f6f6b4442536368656d6100000000010000"
        "001341646472657373426f6f6b417070496e666f00"],
    # 0x71 tables of handle 9 (never opened): error 50, synthetic (the
    # emulator answered 0x70 with handle 0 this way; the T|X was not asked)
    "70710100200109": ["f0710000" "0032"],
    # 0x98 categories of handle 1
    "70980100200101": [
        "f098010000002038000000030000001000000009427573696e657373000000001100000009506572736f6e616c0000000012"
        "0000000a517569636b4c69737400"],
    # 0x87 sync state of handle 1, no token
    "7087010020050100000000": ["f087010000002014000000100001000023e2422e0001000000000000"],
    # 0x76 schema of AddressBookAppInfo (handle 1)
    "707601002018010000001341646472657373426f6f6b417070496e666f00": [
        "f07601000000201e000000010000006400000002020000000008436f756e7472790000000000"],
    # 0x88 row counts (handle 1), flag 0
    "70880100201a01000000001441646472657373426f6f6b4442536368656d6100": ["f08801000000200400000000"],
    "70880100201901000000001341646472657373426f6f6b417070496e666f00": ["f08801000000200400000001"],
    # 0x82 close handle 1 with flag 0x20: error 15 after a read-only open
    "7082010020020120": ["f0820000000f"],
    # 0x81 open MemoDBS, creator mems, mode 1 -> handle 4 (it was the fourth
    # open of the probe's session; the tool takes what the Palm says)
    "7081010020186d656d730000000000010000000000084d656d6f44425300": ["f08101000000200104"],
    # 0x98 categories and 0x87 sync state of handle 4
    "70980100200104": [
        "f098010000002026000000020000001000000009427573696e657373000000001100000009506572736f6e616c00"],
    "7087010020050400000000": ["f08701000000201400000010000100004e8d58bf0001000000000000"],
    # 0x76 schema of MemoDBSchema (handle 4): one column, MemoText
    "707601002012040000000d4d656d6f4442536368656d6100": [
        "f07601000000201f00000001000000640000fffe1000000000094d656d6f546578740000000000"],
}

# 0xAE table scans (handle 1, selector 1, A 0x0B, filter 0, matchMode 1, no
# categories, table name as a C string). The T|X answered each with the
# data message and then the empty F0 AE message of the same transaction.
AE_EMPTY_END = "f0ae00000000"
REPLAY["70ae0100202c01000000010000000b00000000000000010000000000000041646472657373426f6f6b4442536368656d6100"] = [
    # empty table: prefix 01 + X 0, no rows, no name table, rowCount 0, nTables 0
    ("f0ae01000000200d01000000000000000000000000", AE_EMPTY_END)]
REPLAY["70ae0100202b01000000010000000b00000000000000010000000000000041646472657373426f6f6b417070496e666f00"] = [
    # AddressBookAppInfo: one row 0x807BE001, syncStatus 3, no categories,
    # column 100 = 2 bytes 53 55; then the 32-byte name entry (19 bytes of
    # name with NUL, 13 uninitialised) and rowCount 1, nTables 1
    ("f0ae01000000206701000000000000000b00000000807be0010000000000000003000000000000000800000001000000005300504400"
     "000064000000020000000000000000535541646472657373426f6f6b417070496e666f00000100000004fa121c640000000000000100000001",
     AE_EMPTY_END)]


def ae_row(row_id, attr, status, cats, cols, present=0x0B, err=0, table_index=0, junk="deadbeef"):
    """One row record of the 0xAE stream (section 9 of the design note):
    the 40-byte header (36 written, 4 uninitialised), the categories, the
    16-byte column entries and the concatenated column bytes."""
    data = b""
    entries = b""
    for col_id, value in cols:
        entries += struct.pack(">IIII", col_id, len(value), len(data), 0)
        data += value
    head = struct.pack(">IIIHIHIIII", present, err, row_id, attr, table_index, status, len(cats), 8, len(cols), 4 * len(cats))
    return head + bytes.fromhex(junk) + b"".join(struct.pack(">I", c) for c in cats) + entries + data


def ae_reply(x, rows, tables):
    """A complete 0xAE data message: prefix, rows, the 32-byte name entries
    (name with NUL, then non-zero junk the reader must not take as name),
    the trailer. No name table when there are no rows (as the T|X did)."""
    body = bytes([1]) + struct.pack(">I", x) + b"".join(rows)
    if rows:
        for name in tables:
            entry = name.encode() + b"\0"
            body += entry + bytes(range(0xA1, 0xA1 + 32 - len(entry)))
    body += struct.pack(">II", len(rows), len(tables) if rows else 0)
    assert len(body) < 256
    return "f0ae01000000" + bytes([0x20, len(body)]).hex() + body.hex()


# MemoDBSchema scans on handle 4 (the probe's request bytes): the T|X's
# empty answer first, then synthesized rows per the emulator's one-row
# layout: a new row in category 0x11 (Personal) with MemoText "hello\0",
# a deleted row (attr 0x80, syncStatus 4) without categories or columns;
# then an X = 0x8000 answer (a result over one message) with the same rows.
MEMO_ROWS = [ae_row(0x80C48001, 0, 3, [0x11], [(100, b"hello\0")]),
             ae_row(0x80C48002, 0x80, 4, [], [], present=0x01, junk="cafebabe")]
REPLAY["70ae0100202504000000010000000b0000000000000001000000000000004d656d6f4442536368656d6100"] = [
    ("f0ae01000000200d01000000000000000000000000", AE_EMPTY_END),
    (ae_reply(0, MEMO_ROWS, ["MemoDBSchema"]), AE_EMPTY_END),
    (ae_reply(0x8000, MEMO_ROWS, ["MemoDBSchema"]), AE_EMPTY_END)]

# 0xAE by row id (selector 0, A 0x0B, count 3, u16 0, u8 0, the ids), on
# handle 4, synthesized: the two memo rows plus an unknown id 5, which comes
# back as a row with err 5, presentFlags 0 and tableIndex 0xFFFFFFFF. The
# first memo row here has two columns to check the offsets.
TWO_COL_ROW = ae_row(0x80C48001, 0, 1, [0x10, 0x11], [(100, b"hello\0"), (200, b"\x01\x02\x03")])
REPLAY["70ae0100201c04000000000000000b00000003000000" "80c4800180c4800200000005"] = [
    (ae_reply(0, [TWO_COL_ROW, MEMO_ROWS[1], ae_row(5, 0, 0, [], [], present=0, err=5, table_index=0xFFFFFFFF)],
              ["MemoDBSchema"]), AE_EMPTY_END)]

# The 59-column AddressBookDBSchema reply is 1672 bytes; only its first
# three columns (Title, LastName, MiddleName) and the count are replayed.
# The tool reports a truncated list as an error after the rows it got.
ADDRESS_SCHEMA_ARG = bytes.fromhex(
    "0000003b"
    "00000064000001001000000000065469746c6500" "00000000"
    "000000c8000001001000000000094c6173744e616d6500" "00000000"
    "0000012c0000010010000000000b4d6964646c654e616d6500" "00000000")
ADDRESS_SCHEMA_HEAD = "f07601000000" + "a000" + struct.pack(">H", len(ADDRESS_SCHEMA_ARG)).hex() + ADDRESS_SCHEMA_ARG.hex()
REPLAY["707601002019010000001441646472657373426f6f6b4442536368656d6100"] = [ADDRESS_SCHEMA_HEAD]


def fake_cobalt_palm(port, unexpected, done):
    """Answers like the T|X: classic DLP by function code, Cobalt commands
    (first byte 0x70) by the exact request bytes."""
    s = socket.create_connection(("127.0.0.1", port))
    net = Net(s)
    net.send(PALM_HELLO)
    r = net.recv(); assert r and r[0] == 0x12 and len(r) == 50, r
    net.send(PALM_MSG2)
    r = net.recv(); assert r and r[0] == 0x13 and len(r) == 46, r
    net.send(PALM_MSG3)
    pending = {k: list(v) for k, v in REPLAY.items()}
    while True:
        req = net.recv()
        if req is None:
            break
        fn = req[0]
        if fn == 0x70:
            replies = pending.get(req.hex())
            if replies is None:
                unexpected.append(req.hex())
                # error 4 (bad parameter) with the command's reply word
                net.send(bytes([0xF0, req[1], 0, 0, 0, 4]))
            else:
                reply = replies[0] if len(replies) == 1 else replies.pop(0)
                for message in (reply if isinstance(reply, tuple) else (reply,)):
                    net.send(bytes.fromhex(message))
        elif fn == 0x12:
            net.send(SYSINFO_REPLY)
        elif fn == 0x10:
            net.send(dlp_reply(fn, USERINFO))
        elif fn in (0x2E, 0x2F):
            net.send(dlp_reply(fn))
            if fn == 0x2F:
                break
        else:
            net.send(dlp_reply(fn, error=5))
    s.close()
    done.set()


class Session:
    """The tool on net:, the fake Palm connected, commands in, events out."""

    def __init__(self, tool):
        self.palm_port = free_port()
        self.proc, self.events, self.event = start_tool(tool, self.palm_port, ["--dlp", "2.1"])
        assert self.event()["event"] == "listening"
        self.unexpected, self.done = [], threading.Event()
        threading.Thread(target=fake_cobalt_palm, args=(self.palm_port, self.unexpected, self.done),
                         daemon=True).start()
        ev = self.event()
        assert ev["event"] == "connected" and ev["dlpMajor"] == 2 and ev["dlpMinor"] == 1, ev
        assert self.event()["event"] == "syncInfo"

    def run(self, command, until):
        """Sends one command, collects events up to and including the first
        whose name is in `until`."""
        self.proc.stdin.write((command + "\n").encode())
        self.proc.stdin.flush()
        out = []
        while True:
            ev = self.event()
            out.append(ev)
            if ev["event"] in until:
                return out

    def end(self):
        self.proc.stdin.write(b"end\n")
        self.proc.stdin.flush()
        assert self.event()["event"] == "finished"
        self.proc.stdin.close()
        assert self.proc.wait(timeout=10) == 0
        assert self.done.wait(5), "the fake Palm did not finish"
        assert not self.unexpected, f"requests the T|X never saw: {self.unexpected}"


PIM = [("AddressDBS", "DATA", "adrs", 1, 308), ("DateBookDBS", "DATA", "dats", 6, 2),
       ("MemoDBS", "DATA", "mems", 6, 2), ("ToDoDBS", "DATA", "tdos", 6, 2)]
ALL_NAMES = ["AddressDBS", "DateBookDBS", "MemoDBS", "TrustedDtInfo", "DesktopInfo", "ApprovedSyncApps",
             "ToDoDBS", "timezones", "settings", "HotSyncLog", "PatchConfig", "CncPlugins", "CncProfiles",
             "AM_Storage_Vault", "AZM_Backup_Vault", "AZM_Vault", "DataMgr_Vault", "CertMgrVault"]


def test_list(s):
    evs = s.run("cobaltlist", {"cobaltListDone", "error"})
    assert evs[-1] == {"event": "cobaltListDone", "count": 18}, evs[-1]
    dbs = [e for e in evs if e["event"] == "cobaltDatabase"]
    assert [d["name"] for d in dbs] == ALL_NAMES, [d["name"] for d in dbs]
    by_name = {d["name"]: d for d in dbs}
    for name, type_, creator, version, modnum in PIM:
        d = by_name[name]
        assert (d["type"], d["creator"], d["attr"], d["version"], d["modnum"]) == (type_, creator, 0x1008, version, modnum), d
        assert d["schema"] == 1 and d["secure"] == 0, d
        assert d["misc"] == 0x40, d
    # dates: the T|X's local time on the modification date, creation unset (year 0)
    a = by_name["AddressDBS"]
    assert a["modified"] == "2026-11-27 01:02:01" and "created" not in a and "backedUp" not in a, a
    assert by_name["TrustedDtInfo"]["attr"] == 0x3000 and by_name["TrustedDtInfo"]["secure"] == 1
    assert by_name["AM_Storage_Vault"]["attr"] == 0x9000 and by_name["AM_Storage_Vault"]["type"] == "valt"
    print(f"ok: 18 databases listed, the PIM four at 0x1008, {sum(d['secure'] for d in dbs)} secure")


def test_address(s):
    evs = s.run("cobaltopen AddressDBS adrs 1", {"cobaltOpened", "error"})
    assert evs == [{"event": "cobaltOpened", "handle": 1, "name": "AddressDBS", "creator": "adrs", "mode": 1}], evs

    evs = s.run("cobalttables 1", {"cobaltTablesDone", "error"})
    tables = [(e["name"], e["columns"]) for e in evs if e["event"] == "cobaltTable"]
    assert tables == [("AddressBookDBSchema", 59), ("AddressBookAppInfo", 1)], tables
    assert evs[-1] == {"event": "cobaltTablesDone", "handle": 1, "count": 2}, evs[-1]
    # the same tables behind a long-form argument header (synthetic reply)
    evs2 = s.run("cobalttables 1", {"cobaltTablesDone", "error"})
    assert evs2 == evs, evs2

    evs = s.run("cobaltcategories 1", {"cobaltCategoriesDone", "error"})
    cats = [(e["id"], e["name"]) for e in evs if e["event"] == "cobaltCategory"]
    assert cats == [(0x10, "Business"), (0x11, "Personal"), (0x12, "QuickList")], cats

    evs = s.run("cobaltsyncstate 1", {"cobaltSyncState", "error"})
    assert evs == [{"event": "cobaltSyncState", "handle": 1, "syncable": 1, "format": 0x00010000,
                    "syncId": 0x23E2422E, "clock": 1, "rowsPurge": 0, "schemasPurge": 0, "categoryPurge": 0}], evs

    evs = s.run("cobaltschema 1 AddressBookAppInfo", {"cobaltSchemaDone", "error"})
    cols = [e for e in evs if e["event"] == "cobaltColumn"]
    assert len(cols) == 1 and evs[-1]["count"] == 1, evs
    assert cols[0] == {"event": "cobaltColumn", "handle": 1, "table": "AddressBookAppInfo", "id": 100,
                       "name": "Country", "type": 0x02, "attrib": 0, "maxSize": 2, "err": 0}, cols[0]

    # the 59-column schema is replayed cut after three columns: three
    # columns, then the truncation error, then the done event with 3
    evs = s.run("cobaltschema 1 AddressBookDBSchema", {"cobaltSchemaDone"})
    names = [(e["id"], e["name"], e["type"], e["maxSize"]) for e in evs if e["event"] == "cobaltColumn"]
    assert names == [(100, "Title", 0x10, 0x100), (200, "LastName", 0x10, 0x100), (300, "MiddleName", 0x10, 0x100)], names
    assert evs[-2]["event"] == "error" and "truncated" in evs[-2]["message"], evs[-2]
    assert evs[-1]["count"] == 3, evs[-1]

    evs = s.run("cobaltrowcount 1 AddressBookDBSchema", {"cobaltRowCount", "error"})
    assert evs == [{"event": "cobaltRowCount", "handle": 1, "table": "AddressBookDBSchema", "rows": 0}], evs
    evs = s.run("cobaltrowcount 1 AddressBookAppInfo", {"cobaltRowCount", "error"})
    assert evs[0]["rows"] == 1, evs

    # an unknown handle: error 50, mapped
    evs = s.run("cobalttables 9", {"cobaltTablesDone", "error"})
    assert evs == [{"event": "error", "stage": "cobalttables", "message": "Cobalt command 0x71 failed: unknown handle (50)",
                    "cmd": 0x71, "code": 50, "name": "unknown handle"}], evs

    # close with flag 0x20 (return the token) after a read-only open: 15
    evs = s.run("cobaltclose 1 0x20", {"cobaltClosed", "error"})
    assert evs[0]["event"] == "error" and evs[0]["code"] == 15 and evs[0]["name"] == "read-only", evs
    print("ok: AddressDBS opened as handle 1, 2 tables (59 and 1 columns), 3 categories, clock 1, error 15 on close 0x20")


def test_memo(s):
    evs = s.run("cobaltopen MemoDBS mems 1", {"cobaltOpened", "error"})
    assert evs[0]["handle"] == 4, evs
    evs = s.run("cobaltschema 4 MemoDBSchema", {"cobaltSchemaDone", "error"})
    assert evs == [{"event": "cobaltColumn", "handle": 4, "table": "MemoDBSchema", "id": 100, "name": "MemoText",
                    "type": 0x10, "attrib": 0, "maxSize": 0xFFFE, "err": 0},
                   {"event": "cobaltSchemaDone", "handle": 4, "table": "MemoDBSchema", "count": 1}], evs
    evs = s.run("cobaltcategories 4", {"cobaltCategoriesDone", "error"})
    assert [(e["id"], e["name"]) for e in evs if e["event"] == "cobaltCategory"] == [(0x10, "Business"), (0x11, "Personal")], evs
    evs = s.run("cobaltsyncstate 4", {"cobaltSyncState", "error"})
    assert evs[0]["syncId"] == 0x4E8D58BF and evs[0]["clock"] == 1, evs
    print("ok: MemoDBS handle 4, MemoText id 100 type 0x10 maxSize 0xFFFE, 2 categories, clock 1")


def test_rows_address(s):
    """0xAE scans replayed from the probe: an empty table, then the one
    AddressBookAppInfo row (handle 1 is still open: the close with 0x20
    failed with 15)."""
    evs = s.run("cobaltreadall 1 AddressBookDBSchema", {"cobaltRowsDone", "error"})
    assert evs == [{"event": "cobaltRowsDone", "handle": 1, "table": "AddressBookDBSchema", "rows": 0, "tables": 0}], evs

    evs = s.run("cobaltreadall 1 AddressBookAppInfo", {"cobaltRowsDone", "error"})
    assert evs == [
        {"event": "cobaltRow", "handle": 1, "table": "AddressBookAppInfo", "rowId": 0x807BE001, "attr": 0,
         "syncStatus": 3, "modified": 1, "deleted": 0, "archived": 0, "present": 0x0B, "err": 0,
         "categories": [], "columns": [{"id": 100, "size": 2, "err": 0, "hex": "5355"}]},
        {"event": "cobaltRowsDone", "handle": 1, "table": "AddressBookAppInfo", "rows": 1, "tables": 1}], evs
    # the next command still gets its own reply (the empty F0 AE was drained)
    evs = s.run("cobaltrowcount 1 AddressBookAppInfo", {"cobaltRowCount", "error"})
    assert evs[0] == {"event": "cobaltRowCount", "handle": 1, "table": "AddressBookAppInfo", "rows": 1}, evs
    print("ok: 0xAE scans from the probe: 0 rows, then the AppInfo row (0x807BE001, column 100 = 53 55)")


def test_rows_memo(s):
    """Synthesized MemoDBSchema streams on handle 4: the probe's empty
    answer, two rows (one new in Personal with "hello", one deleted), rows
    by id, and the X = 0x8000 error path."""
    evs = s.run("cobaltreadall 4 MemoDBSchema", {"cobaltRowsDone", "error"})
    assert evs[-1] == {"event": "cobaltRowsDone", "handle": 4, "table": "MemoDBSchema", "rows": 0, "tables": 0}, evs

    evs = s.run("cobaltreadall 4 MemoDBSchema all", {"cobaltRowsDone", "error"})
    assert evs == [
        {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 0x80C48001, "attr": 0, "syncStatus": 3,
         "modified": 1, "deleted": 0, "archived": 0, "present": 0x0B, "err": 0, "categories": [0x11],
         "columns": [{"id": 100, "size": 6, "err": 0, "hex": "68656c6c6f00"}]},
        {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 0x80C48002, "attr": 0x80, "syncStatus": 4,
         "modified": 0, "deleted": 1, "archived": 0, "present": 0x01, "err": 0, "categories": [], "columns": []},
        {"event": "cobaltRowsDone", "handle": 4, "table": "MemoDBSchema", "rows": 2, "tables": 1}], evs

    evs = s.run("cobaltreadrows 4 0x80C48001,2160361474,5", {"cobaltRowsDone", "error"})
    assert evs == [
        {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 0x80C48001, "attr": 0, "syncStatus": 1,
         "modified": 1, "deleted": 0, "archived": 0, "present": 0x0B, "err": 0, "categories": [0x10, 0x11],
         "columns": [{"id": 100, "size": 6, "err": 0, "hex": "68656c6c6f00"}, {"id": 200, "size": 3, "err": 0, "hex": "010203"}]},
        {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 0x80C48002, "attr": 0x80, "syncStatus": 4,
         "modified": 0, "deleted": 1, "archived": 0, "present": 0x01, "err": 0, "categories": [], "columns": []},
        {"event": "cobaltRow", "handle": 4, "table": "", "rowId": 5, "attr": 0, "syncStatus": 0,
         "modified": 0, "deleted": 0, "archived": 0, "present": 0, "err": 5, "categories": [], "columns": []},
        {"event": "cobaltRowsDone", "handle": 4, "table": "", "rows": 3, "tables": 1}], evs

    # a result that does not fit one message (X = 0x8000): one error, no
    # rows, no done event; the empty message is drained so the next
    # command still works
    evs = s.run("cobaltreadall 4 MemoDBSchema", {"cobaltRowsDone", "error"})
    assert len(evs) == 1 and evs[0]["event"] == "error" and evs[0]["stage"] == "cobaltreadall", evs
    assert "X=0x00008000" in evs[0]["message"] and "cobaltreadrows" in evs[0]["message"], evs[0]
    evs = s.run("cobaltsyncstate 4", {"cobaltSyncState", "error"})
    assert evs[0]["event"] == "cobaltSyncState" and evs[0]["syncId"] == 0x4E8D58BF, evs

    # the modified-rows filter is refused until its value is confirmed
    evs = s.run("cobaltreadall 4 MemoDBSchema modified", {"error"})
    assert "modified-rows filter" in evs[0]["message"], evs
    print("ok: synthesized memo rows (hello in Personal, one deleted), rows by id with an unknown id, X=0x8000 refused")


def test_usage(s):
    """Bad command lines never reach the Palm."""
    for line, stage in [("cobaltopen MemoDBS mems", "cobaltopen"), ("cobaltopen MemoDBS mem 1", "cobaltopen"),
                        ("cobaltopen MemoDBS mems 1 abc", "cobaltopen"), ("cobaltclose 0", "cobaltclose"),
                        ("cobaltschema 1", "cobaltschema"), ("cobaltrowcount x y", "cobaltrowcount"),
                        ("cobaltreadall 1", "cobaltreadall"), ("cobaltreadall 1 MemoDBSchema some", "cobaltreadall"),
                        ("cobaltreadrows 1", "cobaltreadrows"), ("cobaltreadrows 1 1,x", "cobaltreadrows"),
                        ("cobaltreadrows 1 0x100000000", "cobaltreadrows")]:
        evs = s.run(line, {"error"})
        assert evs[0]["stage"] == stage and any(w in evs[0]["message"] for w in ("usage", "hex", "row id")), (line, evs)
    print("ok: malformed command lines are refused before anything is sent")


def main():
    tool = sys.argv[1] if len(sys.argv) > 1 else ".build/release/hotsync-session"
    s = Session(tool)
    test_list(s)
    test_address(s)
    test_memo(s)
    test_rows_address(s)
    test_rows_memo(s)
    test_usage(s)
    s.end()
    print("all Cobalt tests passed")


if __name__ == "__main__":
    main()
