import os, sys, importlib.util
spec = importlib.util.spec_from_file_location("proxy", os.path.join(os.path.dirname(__file__), "..", "image", "proxy.py"))
proxy = importlib.util.module_from_spec(spec); spec.loader.exec_module(proxy)

def rules(text): return proxy.parse_rules(text)
def ok(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg); assert cond, msg

ALLOW = """
# comment
api.anthropic.com
registry.npmjs.org:443
*.githubusercontent.com
example.com/skills/
"""
r = rules(ALLOW)
ok(len(r) == 4, "parsed 4 rules")

# exact host, any path/port (CONNECT path=None allowed)
ok(proxy.decide(r, "api.anthropic.com", 443, None)[0], "exact host CONNECT allowed")
ok(proxy.decide(r, "api.anthropic.com", 443, "/v1/messages")[0], "exact host HTTP allowed")

# wildcard
ok(proxy.decide(r, "raw.githubusercontent.com", 443, None)[0], "wildcard sub allowed")
ok(not proxy.decide(r, "githubusercontent.com", 443, None)[0], "wildcard bare domain denied")
ok(not proxy.decide(r, "evilgithubusercontent.com", 443, None)[0], "wildcard no-dot-suffix denied")

# port-specific
ok(proxy.decide(r, "registry.npmjs.org", 443, None)[0], "npm:443 allowed")
ok(not proxy.decide(r, "registry.npmjs.org", 80, None)[0], "npm:80 denied (port mismatch)")

# path prefix: HTTP enforced; CONNECT (path None) denied since only a path rule matches
ok(proxy.decide(r, "example.com", 443, "/skills/foo")[0], "path-prefix match allowed")
ok(not proxy.decide(r, "example.com", 443, "/other")[0], "path-prefix miss denied")
ok(not proxy.decide(r, "example.com", 443, None)[0], "path-only rule denies CONNECT (no path)")

# not listed
ok(not proxy.decide(r, "evil.com", 443, None)[0], "unlisted host denied")


# --- plain-HTTP keep-alive: every request upstream must be checked and origin-form ----------
# A keep-alive client (LiteLLM's OpenAI/Anthropic clients) reuses one proxied connection. The
# proxy must not relay a second absolute-form request raw: upstream would 404 it, and it would
# skip the allowlist's path rules. The fake upstream behaves like a real HTTP/1.1 server: it
# keeps the connection open unless the request says "Connection: close".
import socket, threading, time

# Every request head the upstream saw, across all connections.
received = []

def _read_head(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(1)
        if not chunk:
            return None
        data += chunk
    return data

def _upstream_conn(conn):
    conn.settimeout(5)
    try:
        while True:
            head = _read_head(conn)
            if head is None:
                return
            received.append(head)
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            if b"connection: close" in head.lower():
                return
    except OSError:
        return
    finally:
        conn.close()

upstream = socket.socket(); upstream.bind(("127.0.0.1", 0)); upstream.listen(4)
up_port = upstream.getsockname()[1]
def _serve():
    while True:
        try:
            c, _ = upstream.accept()
        except OSError:
            return
        threading.Thread(target=_upstream_conn, args=(c,), daemon=True).start()
threading.Thread(target=_serve, daemon=True).start()

proxy._rules = rules("127.0.0.1:%d\n" % up_port)
client, proxy_side = socket.socketpair()
client.settimeout(5)
threading.Thread(target=proxy.handle, args=(proxy_side,), daemon=True).start()

def _req(path):
    return ("GET http://127.0.0.1:%d%s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"
            "Proxy-Connection: keep-alive\r\nConnection: keep-alive\r\n\r\n"
            % (up_port, path, up_port)).encode()

client.sendall(_req("/one"))
first = b""
while not first.endswith(b"ok"):
    chunk = client.recv(4096)
    if not chunk:
        break
    first += chunk
ok(first.startswith(b"HTTP/1.1 200"), "first keep-alive request answered")
try:
    client.sendall(_req("/two"))
    # Either an answer or EOF; what matters is what upstream saw.
    client.recv(4096)
except OSError:
    pass
client.close()
deadline = time.monotonic() + 1.0
# Let a raw-relayed second request land before inspecting what upstream saw.
while len(received) < 2 and time.monotonic() < deadline:
    time.sleep(0.05)

lines = [h.split(b"\r\n", 1)[0] for h in received]
ok(lines and lines[0] == b"GET /one HTTP/1.1", "first request forwarded in origin form")
ok(all(not ln.split(b" ")[1].startswith(b"http://") for ln in lines),
   "no absolute-form request ever reaches upstream (got %r)" % lines)
ok(b"connection: close" in received[0].lower(), "forwarded request carries Connection: close")
ok(b"keep-alive" not in received[0].lower(), "keep-alive / Proxy-Connection headers stripped")
upstream.close()


# --- a slow upstream must not be cut off: the timeout bounds the connect only ----------------
# A large local model can take minutes before its first response byte. A read timeout on the
# upstream socket made the proxy drop every such request (the agent saw ECONNRESET).
SLOW_SECONDS = 1.5
proxy.UPSTREAM_CONNECT_TIMEOUT = 0.5

def _slow_upstream_conn(conn):
    try:
        _read_head(conn)
        time.sleep(SLOW_SECONDS)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nslow")
    except OSError:
        pass
    finally:
        conn.close()

slow = socket.socket(); slow.bind(("127.0.0.1", 0)); slow.listen(1)
slow_port = slow.getsockname()[1]
def _serve_slow():
    c, _ = slow.accept()
    _slow_upstream_conn(c)
threading.Thread(target=_serve_slow, daemon=True).start()

proxy._rules = rules("127.0.0.1:%d\n" % slow_port)
client, proxy_side = socket.socketpair()
client.settimeout(10)
threading.Thread(target=proxy.handle, args=(proxy_side,), daemon=True).start()
client.sendall(("GET http://127.0.0.1:%d/slow HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"
                % (slow_port, slow_port)).encode())
answer = b""
try:
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        answer += chunk
except OSError:
    pass
ok(answer.endswith(b"slow"),
   "response slower than the connect timeout still delivered (got %r)" % answer[-40:])
client.close(); slow.close()
print("ALL PROXY LOGIC TESTS PASSED")
