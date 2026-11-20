#!/usr/bin/env python3
"""Tool-level test of "relay": a fake Palm and a fake airlock, both over
NET on 127.0.0.1, with the real hotsync-session between them.

    python3 -I Tools/hotsync-session/test-relay.py .build/release/hotsync-session

The fake Palm connects to the tool's net: listener and does the NetSync
handshake (libpisock's net_tx_handshake, byte for byte, as Cradle's
integration test does); it answers the tool's own ReadSysInfo, ReadUserInfo
and OpenConduit. The test then sends "relay 127.0.0.1:PORT": the fake
airlock expects the handshake a Palm sends, asks two things and ends the
session with EndOfSync; the replies must come back as the fake Palm sent
them, and the Palm must not hear a second EndOfSync from the tool."""

import json
import os
import socket
import struct
import subprocess
import sys
import threading

PALM_HELLO = bytes.fromhex("90010000000000000020000000" "0801000000000000" "00")
PALM_MSG2 = bytes.fromhex(
    "92010000000000000020000000" "24ffffffff003c003c40000000"
    "01000000c0a8a51e0401000000" "0000000000000000000000")
PALM_MSG3 = bytes.fromhex("9300000000000000")
DESK_MSG1 = bytes.fromhex(
    "12010000000000000020000000" "24ffffffff3c003c0000000000"
    "00000000c0a8a51f0427000000" "0000000000000000000000")
DESK_MSG2 = bytes.fromhex(
    "13010000000000000020000000" "20ffffffff003c003c00000000"
    "00000001000000000000000000" "00000000000000")

assert len(PALM_HELLO) == 22 and len(PALM_MSG2) == 50 and len(PALM_MSG3) == 8
assert len(DESK_MSG1) == 50 and len(DESK_MSG2) == 46


class Net:
    """One NET framing endpoint: 6-byte header (type 1, txid, length)."""

    def __init__(self, sock):
        self.sock = sock
        self.txid = 0

    def send(self, payload):
        self.txid = self.txid % 0xFE + 1
        self.sock.sendall(bytes([1, self.txid]) + struct.pack(">I", len(payload)) + payload)

    def recv(self):
        hdr = self._exact(6)
        if hdr is None:
            return None
        assert hdr[0] == 1, f"NET packet type {hdr[0]:#x}"
        return self._exact(struct.unpack(">I", hdr[2:])[0])

    def _exact(self, n):
        out = b""
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                return None
            out += chunk
        return out


def dlp_reply(fn, data=b"", error=0):
    """A DLP reply with one argument in the short form (16-bit length), or
    none when data is empty."""
    if not data:
        return bytes([fn | 0x80, 0]) + struct.pack(">H", error)
    return bytes([fn | 0x80, 1]) + struct.pack(">H", error) + bytes([0x80 | 0x20, 0]) \
        + struct.pack(">H", len(data)) + data


SYSINFO = struct.pack(">II", 0x03503000, 0) + b"\0" + bytes([4]) + b"ABCD"
NAME = b"Relay Palm\0"
USERINFO = struct.pack(">III", 4711, 0, 0) + bytes(16) + bytes([len(NAME), 0]) + NAME


def fake_palm(port, seen, done):
    """Answers like a Palm: everything by function code, until EndOfSync."""
    s = socket.create_connection(("127.0.0.1", port))
    net = Net(s)
    net.send(PALM_HELLO)
    r = net.recv(); assert r and r[0] == 0x12 and len(r) == 50, r
    net.send(PALM_MSG2)
    r = net.recv(); assert r and r[0] == 0x13 and len(r) == 46, r
    net.send(PALM_MSG3)
    while True:
        req = net.recv()
        if req is None:
            break
        seen.append(req[0])
        fn = req[0]
        if fn == 0x12:
            net.send(dlp_reply(fn, SYSINFO))
        elif fn == 0x10:
            net.send(dlp_reply(fn, USERINFO))
        elif fn in (0x2E, 0x2F):          # OpenConduit, EndOfSync
            net.send(dlp_reply(fn))
            if fn == 0x2F:
                break
        else:
            net.send(dlp_reply(fn, error=5))   # dlpErrNotFound
    # a Palm closes after EndOfSync; before, it waits for the desktop
    s.close()
    done.set()


def fake_airlock(listener, result):
    """The desktop side: the handshake libpisock's accept does, two
    requests, EndOfSync, hang up."""
    c, _ = listener.accept()
    net = Net(c)
    r = net.recv(); assert r == PALM_HELLO, r
    net.send(DESK_MSG1)
    r = net.recv(); assert r == PALM_MSG2, r
    net.send(DESK_MSG2)
    r = net.recv(); assert r == PALM_MSG3, r
    net.send(bytes([0x12, 1, 0x20, 4, 1, 4, 0, 0]))     # ReadSysInfo
    result["sysinfo"] = net.recv()
    net.send(bytes([0x10, 0]))                           # ReadUserInfo
    result["userinfo"] = net.recv()
    net.send(bytes([0x2F, 1, 0x20, 2, 0, 0]))            # EndOfSync(normal)
    result["end"] = net.recv()
    c.close()
    listener.close()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def start_tool(tool, palm_port):
    """The tool listening on net:, with a reader for its events."""
    proc = subprocess.Popen([tool, "--port", f"net:any:{palm_port}", "--timeout", "15"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    events = []

    def event():
        line = proc.stdout.readline()
        if not line:
            raise SystemExit(f"tool ended early; events so far: {events}\nstderr: {proc.stderr.read().decode()}")
        ev = json.loads(line)
        events.append(ev)
        return ev

    return proc, events, event


def test_refused(tool):
    """No airlock at the address: an error, and the session goes on here
    (the Palm gets the tool's own EndOfSync once "end" is sent)."""
    palm_port = free_port()
    closed = free_port()
    proc, events, event = start_tool(tool, palm_port)
    assert event()["event"] == "listening"
    seen, palm_done = [], threading.Event()
    threading.Thread(target=fake_palm, args=(palm_port, seen, palm_done), daemon=True).start()
    assert event()["event"] == "connected"
    assert event()["event"] == "syncInfo"
    proc.stdin.write(f"relay 127.0.0.1:{closed}\n".encode())
    proc.stdin.flush()
    ev = event()
    assert ev["event"] == "error" and ev["stage"] == "relay" and "cannot connect" in ev["message"], ev
    proc.stdin.write(b"end\n")
    proc.stdin.flush()
    assert event()["event"] == "finished"
    proc.stdin.close()
    assert proc.wait(timeout=10) == 0
    assert palm_done.wait(5), "the fake Palm did not finish"
    assert seen[-1] == 0x2F and seen.count(0x2F) == 1, seen
    print(f"ok: a refused relay leaves the session to the tool; the Palm saw {[hex(f) for f in seen]}")


def main():
    tool = sys.argv[1] if len(sys.argv) > 1 else ".build/release/hotsync-session"
    test_refused(tool)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    airlock_port = listener.getsockname()[1]
    palm_port = free_port()

    proc, events, event = start_tool(tool, palm_port)
    ev = event()
    assert ev["event"] == "listening", ev

    seen, palm_done, result = [], threading.Event(), {}
    threading.Thread(target=fake_palm, args=(palm_port, seen, palm_done), daemon=True).start()
    threading.Thread(target=fake_airlock, args=(listener, result), daemon=True).start()

    ev = event()
    assert ev["event"] == "connected" and ev["user"] == "Relay Palm" and ev["userId"] == 4711, ev
    ev = event()
    assert ev["event"] == "syncInfo", ev

    proc.stdin.write(f"relay 127.0.0.1:{airlock_port}\n".encode())
    proc.stdin.flush()
    ev = event()
    assert ev["event"] == "relayStarted" and ev["target"] == f"127.0.0.1:{airlock_port}", ev
    ev = event()
    assert ev["event"] == "relayFinished", ev
    assert ev["packets"] == 3 and ev["ended"] == 1, ev
    assert ev["bytes"] == 8 + len(dlp_reply(0x12, SYSINFO)) + 2 + len(dlp_reply(0x10, USERINFO)) + 6 + 4, ev
    ev = event()
    assert ev["event"] == "finished", ev
    proc.stdin.close()
    code = proc.wait(timeout=10)
    assert code == 0, (code, proc.stderr.read().decode())
    assert palm_done.wait(5), "the fake Palm did not finish"

    assert result["sysinfo"] == dlp_reply(0x12, SYSINFO), result
    assert result["userinfo"] == dlp_reply(0x10, USERINFO), result
    assert result["end"] == dlp_reply(0x2F), result
    # the tool's own questions, OpenConduit, then exactly what the airlock asked
    assert seen[:2] == [0x12, 0x10], seen
    assert seen[-3:] == [0x12, 0x10, 0x2F], seen
    assert seen.count(0x2F) == 1, seen
    print(f"ok: relayed {events[-2]['packets']} packets, {events[-2]['bytes']} bytes; the Palm saw {[hex(f) for f in seen]}")


if __name__ == "__main__":
    main()
