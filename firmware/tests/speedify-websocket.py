#!/usr/bin/env python3
"""Real nginx + vendor auth proxy; only the VPN daemon/ubus are fixtures."""
import base64
import hashlib
import json
import socket
import socketserver
import ssl
import threading

seen = []


def headers(sock):
    data = b""
    while not data.endswith(b"\r\n\r\n"):
        part = sock.recv(1)
        assert part, data
        data += part
    return data


class Daemon(socketserver.BaseRequestHandler):
    def handle(self):
        request = headers(self.request)
        seen.append(request)
        fields = dict(line.split(b": ", 1) for line in request.split(b"\r\n")[1:-2])
        fields = {key.lower(): value for key, value in fields.items()}
        accept = base64.b64encode(hashlib.sha1(fields[b"sec-websocket-key"] +
            b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        self.request.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            b"Connection: Upgrade\r\nSec-WebSocket-Protocol: event-protocol\r\n"
            b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        stream = self.request.makefile("rb")
        frame = stream.read(2)
        assert frame[0] == 0x81 and frame[1] & 0x80
        mask = stream.read(4)
        payload = stream.read(frame[1] & 0x7f)
        message = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
        assert json.loads(message) == ["request_current_state", {}, "speedify_ui"]
        reply = json.dumps(["report_current_state", {"state": 2}]).encode()
        self.request.sendall(bytes([0x81, len(reply)]) + reply)


with socketserver.ThreadingTCPServer(("127.0.0.1", 9330), Daemon) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    context = ssl._create_unverified_context()  # Disposable self-signed fixture.
    for cookie in (None, "invalidSession", "zbtTestAdminSession"):
        with context.wrap_socket(socket.socket(), server_hostname="127.0.0.1") as client:
            client.settimeout(5)
            client.connect(("127.0.0.1", 8443))
            request = ("GET /luci-app-speedify/api/ws HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: event-protocol\r\n")
            if cookie:
                request += "Cookie: sfy-session=" + cookie + "\r\n"
            client.sendall((request + "\r\n").encode())
            response = headers(client)
            if cookie != "zbtTestAdminSession":
                assert b" 401 " in response, response
                continue
            assert b" 101 " in response, response
            payload = json.dumps(["request_current_state", {}, "speedify_ui"]).encode()
            mask = b"abcd"
            client.sendall(bytes([0x81, len(payload) | 0x80]) + mask +
                bytes(value ^ mask[i % 4] for i, value in enumerate(payload)))
            stream = client.makefile("rb")
            frame = stream.read(2)
            assert frame[0] == 0x81
            assert json.loads(stream.read(frame[1])) == ["report_current_state", {"state": 2}]
    server.shutdown()
assert len(seen) == 1, "Unauthenticated clients must never reach the daemon"
assert b"wsToken" not in seen[0].split(b"\r\n", 1)[0]
print("Speedify WebSocket: missing/invalid cookie rejected; scoped cookie alone authenticates; native messages cross nginx + official proxy")
