#!/usr/bin/env python3
"""agentdev egress allowlist proxy.

Runs in a sidecar container on an internal (no-egress) podman network together
with the agent container. The agent is pointed at this proxy via HTTP(S)_PROXY
and can reach *only* destinations on the allowlist; everything else is refused.
Because the agent's own network has no route out, a client that ignores the
proxy and opens a raw socket simply cannot reach anything.

Allowlist entries (one per line in $PROXY_ALLOW_FILE; '#' comments, blanks
ignored):

    api.anthropic.com                 # host, any port, any path
    registry.npmjs.org:443            # host + explicit port
    *.githubusercontent.com           # leading-wildcard host (one or more labels)
    example.com/skills/               # host + path prefix (HTTP always; HTTPS needs MITM)

Modes:
  - Domain level (default): CONNECT tunnels are allowed/denied by host[:port];
    HTTPS is not decrypted. A path-scoped rule cannot be enforced on a CONNECT
    tunnel, so such a rule is refused for HTTPS unless MITM is on.
  - MITM ($PROXY_MITM=1, with $PROXY_CA_CERT/$PROXY_CA_KEY): HTTPS is terminated
    and the full URL (host + path) is matched. Requires the agent to trust the
    CA (agentdev injects it via its CA passthrough).

Every decision is appended to $PROXY_LOG_FILE as:  ISO8601<TAB>ALLOW|DENY<TAB>METHOD<TAB>host:port<TAB>path
"""
import os
import sys
import socket
import ssl
import threading
import subprocess
import tempfile
import time
from datetime import datetime, timezone

# ----------------------------------------------------------------------------
# Allowlist parsing + decision — PURE, unit-tested (see tests/test_proxy.py).
# ----------------------------------------------------------------------------


class Rule:
    __slots__ = ("host", "port", "path")

    def __init__(self, host, port, path):
        self.host = host          # lowercased; may start with "*." for wildcard
        self.port = port          # int or None (any)
        self.path = path          # str prefix or None (any path)

    def host_matches(self, host):
        host = host.lower()
        if self.host.startswith("*."):
            suffix = self.host[1:]          # ".example.com"
            return host.endswith(suffix) and host != suffix[1:]
        return host == self.host


def parse_rules(text):
    """Parse allowlist text into a list of Rule. Ignores blanks and '#' lines."""
    rules = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        hostport, _, path = line.partition("/")
        host, _, port_s = hostport.partition(":")
        host = host.strip().lower()
        if not host:
            continue
        port = int(port_s) if port_s.strip().isdigit() else None
        path = ("/" + path) if path != "" else None
        rules.append(Rule(host, port, path))
    return rules


def decide(rules, host, port, path):
    """Return (allowed: bool, reason: str).

    path is None for a CONNECT tunnel (host-level only). A path-scoped rule
    never matches a None path, so a destination only reachable via a path rule
    is refused for plain CONNECT — which is the safe default.
    """
    host_seen = False
    for r in rules:
        if not r.host_matches(host):
            continue
        if r.port is not None and port is not None and r.port != port:
            host_seen = True
            continue
        host_seen = True
        if r.path is None:
            return True, "host-allow"
        if path is not None and path.startswith(r.path):
            return True, "path-allow(%s)" % r.path
    if host_seen:
        return False, "host-listed-but-path/port-mismatch"
    return False, "not-in-allowlist"


# ----------------------------------------------------------------------------
# I/O glue (conventional; verify against a live run).
# ----------------------------------------------------------------------------

ALLOW_FILE = os.environ.get("PROXY_ALLOW_FILE", "/etc/agentdev/allow.txt")
LOG_FILE = os.environ.get("PROXY_LOG_FILE", "")
PORT = int(os.environ.get("PROXY_PORT", "8080"))
MITM = os.environ.get("PROXY_MITM", "0") == "1"
CA_CERT = os.environ.get("PROXY_CA_CERT", "")
CA_KEY = os.environ.get("PROXY_CA_KEY", "")

_log_lock = threading.Lock()
_rules = []


def log(decision, method, host, port, path):
    line = "%s\t%s\t%s\t%s:%s\t%s\n" % (
        datetime.now(timezone.utc).isoformat(timespec="seconds"),
        decision, method, host, port, path if path is not None else "-")
    sys.stderr.write(line)
    if not LOG_FILE:
        return
    with _log_lock:
        try:
            with open(LOG_FILE, "a") as fh:
                fh.write(line)
        except OSError:
            pass


def _pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def _recv_line(sock, maxlen=8192):
    buf = b""
    while b"\n" not in buf and len(buf) < maxlen:
        chunk = sock.recv(1)
        if not chunk:
            break
        buf += chunk
    return buf


def _read_headers(sock):
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 65536:
        chunk = sock.recv(1)
        if not chunk:
            break
        data += chunk
    return data


# Hop-by-hop headers that negotiate connection reuse; replaced by "Connection: close".
_REUSE_HEADERS = (b"connection", b"proxy-connection", b"keep-alive")


def _origin_request(method, path, header_block):
    """Rebuild an absolute-form request head as origin form with Connection: close.

    After the head, the client's bytes are relayed raw, so a second request on a kept-alive
    connection would reach upstream unchecked and still in absolute form. Forcing close makes
    the upstream end the connection after one response; the client must reconnect, and its
    next request comes back through handle() and the allowlist.
    """
    kept = []
    for line in header_block.split(b"\r\n"):
        if not line:
            continue
        name = line.split(b":", 1)[0].strip().lower()
        if name in _REUSE_HEADERS:
            continue
        kept.append(line)
    head = [("%s %s HTTP/1.1" % (method, path)).encode("latin1")] + kept + [b"Connection: close"]
    return b"\r\n".join(head) + b"\r\n\r\n"


def handle(client):
    try:
        first = _recv_line(client)
        if not first:
            return
        parts = first.split()
        if len(parts) < 2:
            return
        method, target = parts[0].decode("latin1"), parts[1].decode("latin1")

        if method == "CONNECT":
            host, _, port_s = target.partition(":")
            port = int(port_s) if port_s.isdigit() else 443
            # drain the rest of the CONNECT headers
            while True:
                line = _recv_line(client)
                if line in (b"\r\n", b"\n", b""):
                    break
            if MITM:
                return handle_connect_mitm(client, host, port)
            allowed, reason = decide(_rules, host, port, None)
            log("ALLOW" if allowed else "DENY", "CONNECT", host, port, None)
            if not allowed:
                client.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                return
            upstream = socket.create_connection((host, port), timeout=30)
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            t = threading.Thread(target=_pipe, args=(upstream, client), daemon=True)
            t.start()
            _pipe(client, upstream)
            return

        # Absolute-form HTTP request: GET http://host/path HTTP/1.1
        rest = _read_headers(client)
        scheme, _, remainder = target.partition("://")
        hostport, _, path = remainder.partition("/")
        path = "/" + path
        host, _, port_s = hostport.partition(":")
        port = int(port_s) if port_s.isdigit() else 80
        allowed, reason = decide(_rules, host, port, path)
        log("ALLOW" if allowed else "DENY", method, host, port, path)
        if not allowed:
            client.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            return
        upstream = socket.create_connection((host, port), timeout=30)
        upstream.sendall(_origin_request(method, path, rest))
        t = threading.Thread(target=_pipe, args=(upstream, client), daemon=True)
        t.start()
        _pipe(client, upstream)
    except Exception as exc:  # noqa: BLE001 - a proxy must never crash the server
        try:
            sys.stderr.write("proxy error: %r\n" % exc)
        except OSError:
            pass
    finally:
        try:
            client.close()
        except OSError:
            pass


# --- MITM (experimental; HTTPS path-level filtering) ------------------------

_cert_lock = threading.Lock()
_cert_cache = {}


def _leaf_cert(host):
    """Sign a leaf cert for host with the CA, via openssl. Cached per host."""
    with _cert_lock:
        if host in _cert_cache:
            return _cert_cache[host]
        d = tempfile.mkdtemp(prefix="mitm-")
        key = os.path.join(d, "k.pem")
        csr = os.path.join(d, "c.csr")
        crt = os.path.join(d, "c.pem")
        ext = os.path.join(d, "ext")
        with open(ext, "w") as fh:
            fh.write("subjectAltName=DNS:%s\n" % host)
        subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "req", "-new", "-key", key, "-out", csr,
                        "-subj", "/CN=%s" % host], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "x509", "-req", "-in", csr, "-CA", CA_CERT,
                        "-CAkey", CA_KEY, "-CAcreateserial", "-out", crt,
                        "-days", "1", "-extfile", ext], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _cert_cache[host] = (crt, key)
        return crt, key


def handle_connect_mitm(client, host, port):
    # Host must at least be listed before we terminate TLS.
    allowed_host, _ = decide(_rules, host, port, "/")
    host_listed = any(r.host_matches(host) for r in _rules)
    if not host_listed:
        log("DENY", "CONNECT", host, port, None)
        client.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
        return
    client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    crt, key = _leaf_cert(host)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    try:
        tls_client = ctx.wrap_socket(client, server_side=True)
    except ssl.SSLError as exc:
        sys.stderr.write("mitm handshake failed for %s: %r\n" % (host, exc))
        return
    req = _recv_line(tls_client) + _read_headers(tls_client)
    try:
        line0 = req.split(b"\r\n", 1)[0].split()
        method, path = line0[0].decode(), line0[1].decode()
    except Exception:
        tls_client.close()
        return
    allowed, reason = decide(_rules, host, port, path)
    log("ALLOW" if allowed else "DENY", method, host, port, path)
    if not allowed:
        tls_client.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
        tls_client.close()
        return
    up = ssl.create_default_context().wrap_socket(
        socket.create_connection((host, port), timeout=30), server_hostname=host)
    up.sendall(req)
    t = threading.Thread(target=_pipe, args=(up, tls_client), daemon=True)
    t.start()
    _pipe(tls_client, up)


def main():
    global _rules
    try:
        with open(ALLOW_FILE) as fh:
            _rules = parse_rules(fh.read())
    except OSError as exc:
        sys.stderr.write("cannot read allowlist %s: %r\n" % (ALLOW_FILE, exc))
        sys.exit(1)
    if MITM and not (CA_CERT and CA_KEY):
        sys.stderr.write("PROXY_MITM=1 requires PROXY_CA_CERT and PROXY_CA_KEY\n")
        sys.exit(1)
    sys.stderr.write("agentdev proxy: %d rule(s), mitm=%s, port=%d\n"
                     % (len(_rules), MITM, PORT))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(128)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
