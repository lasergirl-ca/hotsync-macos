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
OpenConduit, EndOfSync) come from test-relay.py."""

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
                net.send(bytes.fromhex(replies[0] if len(replies) == 1 else replies.pop(0)))
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


def test_usage(s):
    """Bad command lines never reach the Palm."""
    for line, stage in [("cobaltopen MemoDBS mems", "cobaltopen"), ("cobaltopen MemoDBS mem 1", "cobaltopen"),
                        ("cobaltopen MemoDBS mems 1 abc", "cobaltopen"), ("cobaltclose 0", "cobaltclose"),
                        ("cobaltschema 1", "cobaltschema"), ("cobaltrowcount x y", "cobaltrowcount")]:
        evs = s.run(line, {"error"})
        assert evs[0]["stage"] == stage and ("usage" in evs[0]["message"] or "hex" in evs[0]["message"]), (line, evs)
    print("ok: malformed command lines are refused before anything is sent")


def main():
    tool = sys.argv[1] if len(sys.argv) > 1 else ".build/release/hotsync-session"
    s = Session(tool)
    test_list(s)
    test_address(s)
    test_memo(s)
    test_usage(s)
    s.end()
    print("all Cobalt tests passed")


if __name__ == "__main__":
    main()
