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
them, and the Palm must not hear a second EndOfSync from the tool.

Then the authenticator: with "relaykey" the tool answers the airlock's
CallApplication for CradleSync (creator CrSy) itself, with Cradle's test
vector (RFC 8032 test 1's key signing a fixed challenge), never asking the
Palm; a transport record and a pair code go the same way. Last, the Secure
transport: with "relaytls" the relay comes in over TLS 1.3 to a fake
airlock that presents a certificate made here, pinned by its SPKI, and a
wrong pin is refused. That case needs a Python whose ssl has TLS 1.3
(Homebrew's python3.12; the system's LibreSSL lacks it) and is skipped
otherwise."""

import hashlib
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
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


# Cradle's authenticator vector (palm/sync/auth/handler.c selfTest,
# internal/hotsync/auth_test.go): RFC 8032 test 1's key signing a fixed
# SIGN parameter.
SEED = "9d61b19deffd5a60ba844af492ec2cc44449c5697b32691970 3bac031cae7f60".replace(" ", "")
PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
CHALLENGE = bytes.fromhex("43524131" "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
                          "01f7d3bf" "0a0b0c0d")
SIGNATURE = bytes.fromhex(
    "085b9c333015885ed274e8f431a50d088ca4673f9f5f1f4f305037a0420bf03a"
    "c6d5db6e494765b655a7eea3df68fa530582a8f82e5d714963cc286c9dc45408")
FINGERPRINT = hashlib.sha512(PUB).hexdigest()[:16]
assert len(CHALLENGE) == 44


def call_app(action, param=b""):
    """DLP CallApplication for CradleSync as libpisock sends it (the Palm OS
    2.0 encoding: argument 0x21 with creator, type, action, length, two
    reserved longs and the parameter)."""
    arg = b"CrSy" + b"appl" + struct.pack(">HI", action, len(param)) + bytes(8) + param
    assert len(arg) < 256
    return bytes([0x28, 1, 0x21, len(arg)]) + arg


def app_reply(code, result=b""):
    """What a Palm (or the tool) answers: result code, size, reserved, result."""
    arg = struct.pack(">IIII", code, len(result), 0, 0) + result
    return bytes([0xA8, 1, 0, 0, 0x21, len(arg)]) + arg


def airlock_auth(net, result, pin, secure):
    """The airlock's authenticator calls, after the handshake, in the order a
    session makes them: the pair code and its outcome (an unknown Palm), then
    enrol, sign, info and the transport record, then EndOfSync. Once the
    record is held, a plain session gets no pair code and no signature, so
    the order matters here as it does on a Palm."""
    result["pair"] = (net.send(call_app(5)), net.recv())[1]
    result["paired"] = (net.send(call_app(6, b"CRA1\x01")), net.recv())[1]
    result["enrol"] = (net.send(call_app(1, bytes(range(32)))), net.recv())[1]
    result["sign"] = (net.send(call_app(2, CHALLENGE)), net.recv())[1]
    result["info"] = (net.send(call_app(3)), net.recv())[1]
    record = b"CRA1" + struct.pack(">HB", 14243, len(b"airlock.cradle")) + b"airlock.cradle" + pin
    result["transport"] = (net.send(call_app(4, record)), net.recv())[1]
    if not secure:
        # the record is held now: a plain session's asker could be anyone
        result["sign_plain"] = (net.send(call_app(2, CHALLENGE)), net.recv())[1]
    net.send(bytes([0x2F, 1, 0x20, 2, 0, 0]))
    result["end"] = net.recv()


def check_auth(result, pin, events):
    assert result["enrol"] == app_reply(0, b"CRA1" + PUB), result["enrol"].hex()
    assert result["sign"] == app_reply(0, SIGNATURE), result["sign"].hex()
    assert result["info"] == app_reply(0, b"CRA1\x00\x01" + bytes.fromhex(FINGERPRINT)), result["info"].hex()
    assert result["transport"] == app_reply(0, b"CRA1"), result["transport"].hex()
    assert result["pair"] == app_reply(0, b"CRA1ABCD-EFGH"), result["pair"].hex()
    assert result["paired"] == app_reply(0, b"CRA1"), result["paired"].hex()
    assert result["end"] == dlp_reply(0x2F), result
    auth = [e for e in events if e["event"] == "relayAuth"]
    expected = [(5, 0), (6, 0), (1, 0), (2, 0), (4, 0)]
    if "sign_plain" in result:
        assert result["sign_plain"] == app_reply(7), result["sign_plain"].hex()
        expected.append((2, 7))
    assert [(e["action"], e["code"]) for e in auth] == expected, auth
    assert auth[1]["accepted"] == 1, auth[1]
    assert auth[2]["fingerprint"] == FINGERPRINT, auth[2]
    assert auth[4]["tlsPort"] == 14243 and auth[4]["name"] == "airlock.cradle" and auth[4]["pin"] == pin.hex(), auth[4]


def fake_airlock_auth(listener, result, pin, wrap=None):
    c, _ = listener.accept()
    try:
        if wrap is not None:
            c = wrap(c)
        net = Net(c)
        r = net.recv(); assert r == PALM_HELLO, r
        net.send(DESK_MSG1)
        r = net.recv(); assert r == PALM_MSG2, r
        net.send(DESK_MSG2)
        r = net.recv(); assert r == PALM_MSG3, r
        airlock_auth(net, result, pin, wrap is not None)
    except (ssl.SSLError, ConnectionError, OSError) as e:
        result["error"] = e
    finally:
        c.close()
        listener.close()


def test_auth_plain(tool):
    """The Mac answers the authenticator; the Palm never hears the calls."""
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    airlock_port = listener.getsockname()[1]
    palm_port = free_port()
    proc, events, event = start_tool(tool, palm_port)
    assert event()["event"] == "listening"
    seen, palm_done, result = [], threading.Event(), {}
    pin = hashlib.sha256(b"some server key").digest()
    threading.Thread(target=fake_palm, args=(palm_port, seen, palm_done), daemon=True).start()
    threading.Thread(target=fake_airlock_auth, args=(listener, result, pin), daemon=True).start()
    assert event()["event"] == "connected"
    assert event()["event"] == "syncInfo"
    proc.stdin.write(f"relaykey {SEED}\nrelaypair ABCD-EFGH\nrelay 127.0.0.1:{airlock_port}\n".encode())
    proc.stdin.flush()
    ev = event()
    assert ev["event"] == "relayKey" and ev["fingerprint"] == FINGERPRINT, ev
    ev = event()
    assert ev["event"] == "relayStarted" and ev["secure"] == 0, ev
    while event()["event"] != "relayFinished":
        pass
    ev = events[-1]
    assert ev["packets"] == 8 and ev["answered"] == 7 and ev["ended"] == 1, ev
    assert event()["event"] == "finished"
    proc.stdin.close()
    assert proc.wait(timeout=10) == 0
    assert palm_done.wait(5), "the fake Palm did not finish"
    check_auth(result, pin, events)
    assert 0x28 not in seen, seen
    print(f"ok: the Mac answered {ev['answered']} authenticator calls for the Palm; the Palm saw {[hex(f) for f in seen]}")


def make_cert(directory):
    """An ECDSA P-256 server certificate as the airlock's (tlskeys.go), and
    the SPKI pin the Palms hold for it: SHA-256 of the SubjectPublicKeyInfo."""
    key, crt = os.path.join(directory, "server.key"), os.path.join(directory, "server.crt")
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key], check=True)
    subprocess.run(["openssl", "req", "-x509", "-new", "-key", key, "-out", crt, "-days", "2",
                    "-subj", "/CN=airlock.cradle"], check=True, capture_output=True)
    pem = subprocess.run(["openssl", "x509", "-in", crt, "-pubkey", "-noout"], check=True, capture_output=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=pem, check=True, capture_output=True).stdout
    return key, crt, hashlib.sha256(der).digest()


def test_auth_tls(tool):
    """With the transport record held, the relay comes in over TLS to the
    record's port, pinned; a wrong pin is refused before any byte of NetSync."""
    if not ssl.HAS_TLSv1_3:
        print(f"skipped: this Python's {ssl.OPENSSL_VERSION} has no TLS 1.3 (try /opt/homebrew/bin/python3.12)")
        return
    if shutil.which("openssl") is None:
        print("skipped: no openssl to make a certificate with")
        return
    with tempfile.TemporaryDirectory() as directory:
        key, crt, pin = make_cert(directory)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.set_alpn_protocols(["cradle-hotsync/1"])
        ctx.load_cert_chain(crt, key)

        def wrap(c):
            return ctx.wrap_socket(c, server_side=True)

        # the wrong pin first: refused, and the session stays with the tool
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        tls_port = listener.getsockname()[1]
        palm_port = free_port()
        proc, events, event = start_tool(tool, palm_port)
        assert event()["event"] == "listening"
        seen, palm_done, result = [], threading.Event(), {}
        threading.Thread(target=fake_palm, args=(palm_port, seen, palm_done), daemon=True).start()
        threading.Thread(target=fake_airlock_auth, args=(listener, result, pin, wrap), daemon=True).start()
        assert event()["event"] == "connected"
        assert event()["event"] == "syncInfo"
        proc.stdin.write(f"relaykey {SEED}\nrelaytls {tls_port} airlock.cradle {'00' * 32}\nrelay 127.0.0.1:1\n".encode())
        proc.stdin.flush()
        assert event()["event"] == "relayKey"
        ev = event()
        assert ev["event"] == "error" and ev["stage"] == "relay" and "pin" in ev["message"], ev
        proc.stdin.write(b"end\n")
        proc.stdin.flush()
        assert event()["event"] == "finished"
        proc.stdin.close()
        assert proc.wait(timeout=10) == 0
        assert palm_done.wait(5)
        assert "sign" not in result, result
        print(f"ok: a server off the pin is refused ({ev['message']})")

        # the right pin: the whole exchange, inside TLS
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        tls_port = listener.getsockname()[1]
        palm_port = free_port()
        proc, events, event = start_tool(tool, palm_port)
        assert event()["event"] == "listening"
        seen, palm_done, result = [], threading.Event(), {}
        threading.Thread(target=fake_palm, args=(palm_port, seen, palm_done), daemon=True).start()
        threading.Thread(target=fake_airlock_auth, args=(listener, result, pin, wrap), daemon=True).start()
        assert event()["event"] == "connected"
        assert event()["event"] == "syncInfo"
        proc.stdin.write(f"relaykey {SEED}\nrelaypair ABCD-EFGH\nrelaytls {tls_port} airlock.cradle {pin.hex()}\n"
                         f"relay 127.0.0.1:1\n".encode())
        proc.stdin.flush()
        assert event()["event"] == "relayKey"
        ev = event()
        assert ev["event"] == "relayStarted" and ev["secure"] == 1 and ev["tlsPort"] == tls_port, ev
        while event()["event"] != "relayFinished":
            pass
        ev = events[-1]
        assert ev["packets"] == 7 and ev["answered"] == 6 and ev["ended"] == 1, ev
        assert event()["event"] == "finished"
        proc.stdin.close()
        assert proc.wait(timeout=10) == 0
        assert palm_done.wait(5)
        assert "error" not in result, result["error"]
        check_auth(result, pin, events)
        assert 0x28 not in seen, seen
        print(f"ok: the Secure session over TLS 1.3 answered {ev['answered']} calls; the Palm saw {[hex(f) for f in seen]}")


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
    test_auth_plain(tool)
    test_auth_tls(tool)
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
    assert ev["packets"] == 3 and ev["answered"] == 0 and ev["ended"] == 1, ev
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
