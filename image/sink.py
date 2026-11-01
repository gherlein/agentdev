#!/usr/bin/env python3
"""agentdev network sink.

Runs in a sidecar container whose network namespace the agent container joins
(podman --network container:<sink>). It owns that namespace's routing, because the
agent never gets NET_ADMIN, and turns every way out that bypasses the proxy into a
logged, immediate failure:

  - Routing: `ip route add local default dev lo` (and the IPv6 equivalent) makes
    every address that is not on an attached network "local". A connection to an
    outside address therefore loops back inside the namespace and is refused at
    once (TCP RST, ICMP port unreachable) instead of leaving or hanging. The real
    networks keep their own, more specific routes, so the proxy stays reachable.
  - Capture: a raw socket on every interface records each new flow: a TCP SYN, a
    UDP datagram or an ICMP echo request. On lo it records looped-back attempts
    to outside addresses; on a real interface, every flow except the one to the
    proxy (SINK_EXEMPT).
  - DNS: the agent's resolv.conf points at 127.0.0.1, where this sink answers
    every query with NXDOMAIN after logging the name and type. Names never reach a
    real resolver, so a name cannot carry data out. It also listens on every
    address, so a query sent straight to some outside resolver (dig @8.8.8.8 ...)
    loops back here and is logged by name too.

Every attempt is appended to $SINK_LOG_FILE in the egress log format the proxy uses:
    ISO8601<TAB>DENY<TAB>KIND<TAB>destination<TAB>detail
KIND is DNS (destination = the name, detail = the query type), TCP or UDP
(destination = address:port), ICMP (detail = the ICMP type) or IP (detail = the
protocol number).
"""
import os
import socket
import struct
import subprocess
import sys
import threading
from datetime import datetime, timezone

# ----------------------------------------------------------------------------
# DNS and frame parsing — PURE, unit-tested (see tests/test_sink.py).
# ----------------------------------------------------------------------------

DNS_HEADER_LEN = 12
DNS_MAX_NAME = 255
DNS_FLAG_QR = 0x8000
DNS_FLAG_RD = 0x0100
DNS_FLAG_RA = 0x0080
DNS_OPCODE_MASK = 0x7800
DNS_RCODE_NXDOMAIN = 3

QTYPE_NAMES = {1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX", 16: "TXT",
               28: "AAAA", 33: "SRV", 64: "SVCB", 65: "HTTPS", 255: "ANY"}


def _question(packet):
    """Return (name, qtype, end offset of the first question) or raise ValueError."""
    if len(packet) < DNS_HEADER_LEN:
        raise ValueError("shorter than a DNS header")
    flags, qdcount = struct.unpack("!HH", packet[2:6])
    if flags & DNS_FLAG_QR:
        raise ValueError("a response, not a query")
    if qdcount < 1:
        raise ValueError("no question")
    labels, i, length = [], DNS_HEADER_LEN, 0
    while True:
        if i >= len(packet):
            raise ValueError("name runs past the packet")
        size = packet[i]
        if size == 0:
            i += 1
            break
        if size & 0xC0:
            raise ValueError("compression pointer in a question")
        label = packet[i + 1:i + 1 + size]
        if len(label) != size:
            raise ValueError("label runs past the packet")
        length += size + 1
        if length > DNS_MAX_NAME:
            raise ValueError("name longer than 255 bytes")
        labels.append(label.decode("ascii", "backslashreplace"))
        i += 1 + size
    if i + 4 > len(packet):
        raise ValueError("question has no type and class")
    qtype = struct.unpack("!H", packet[i:i + 2])[0]
    return ".".join(labels), qtype, i + 4


def parse_dns_query(packet):
    """Return (name, qtype) of a DNS query's first question; ValueError if malformed."""
    name, qtype, _ = _question(packet)
    return name, qtype


def nxdomain_reply(packet):
    """An NXDOMAIN response to a well-formed query: same id and question, no answers."""
    _, _, end = _question(packet)
    qid, flags = struct.unpack("!HH", packet[:4])
    reply_flags = (DNS_FLAG_QR | (flags & DNS_OPCODE_MASK) | (flags & DNS_FLAG_RD)
                   | DNS_FLAG_RA | DNS_RCODE_NXDOMAIN)
    return struct.pack("!HHHHHH", qid, reply_flags, 1, 0, 0, 0) + packet[DNS_HEADER_LEN:end]


def qtype_name(qtype):
    return QTYPE_NAMES.get(qtype, "TYPE%d" % qtype)


ETH_HEADER_LEN = 14
ETHERTYPE_IPV4 = 0x0800
ETHERTYPE_IPV6 = 0x86DD
PROTO_ICMP, PROTO_IGMP, PROTO_TCP, PROTO_UDP, PROTO_ICMPV6 = 1, 2, 6, 17, 58
TCP_SYN, TCP_ACK = 0x02, 0x10
ICMP_ECHO_REQUEST, ICMPV6_ECHO_REQUEST = 8, 128


def _transport(proto, payload, dst, exempt):
    """(kind, dst, port_or_type) for a new flow in an IP payload, or None."""
    if proto == PROTO_TCP:
        if len(payload) < 14:
            return None
        flags = payload[13]
        if not (flags & TCP_SYN) or flags & TCP_ACK:
            return None
        port = struct.unpack("!H", payload[2:4])[0]
        return None if (dst, port) in exempt else ("TCP", dst, port)
    if proto == PROTO_UDP:
        if len(payload) < 4:
            return None
        port = struct.unpack("!H", payload[2:4])[0]
        return None if (dst, port) in exempt else ("UDP", dst, port)
    if proto in (PROTO_ICMP, PROTO_ICMPV6):
        if not payload:
            return None
        echo = ICMP_ECHO_REQUEST if proto == PROTO_ICMP else ICMPV6_ECHO_REQUEST
        return ("ICMP", dst, echo) if payload[0] == echo else None
    if proto == PROTO_IGMP:
        return None
    return ("IP", dst, proto)


def classify(frame, on_loopback, outgoing, exempt):
    """Return (kind, destination address, port or type) if FRAME starts a flow out.

    On lo, attempts to outside addresses arrive as the incoming copy of a looped-back
    packet. On a real interface the agent's own packets are the outgoing ones.
    EXEMPT is a set of (address, port) pairs that are allowed traffic (the proxy).
    """
    if on_loopback == outgoing:
        return None
    if len(frame) < ETH_HEADER_LEN:
        return None
    ethertype = struct.unpack("!H", frame[12:14])[0]
    ip = frame[ETH_HEADER_LEN:]
    if ethertype == ETHERTYPE_IPV4:
        if len(ip) < 20:
            return None
        header_len = (ip[0] & 0x0F) * 4
        dst = socket.inet_ntoa(ip[16:20])
        first_octet = ip[16]
        if first_octet == 127 or first_octet >= 224 or len(ip) < header_len:
            return None
        return _transport(ip[9], ip[header_len:], dst, exempt)
    if ethertype == ETHERTYPE_IPV6:
        if len(ip) < 40:
            return None
        dst_bytes = ip[24:40]
        if dst_bytes == socket.inet_pton(socket.AF_INET6, "::1") or dst_bytes[0] == 0xFF:
            return None
        return _transport(ip[6], ip[40:], socket.inet_ntop(socket.AF_INET6, dst_bytes), exempt)
    return None


def format_dest(address, port):
    return "[%s]:%d" % (address, port) if ":" in address else "%s:%d" % (address, port)


def _clean(text):
    return "".join(ch if 0x20 <= ord(ch) < 0x7F else "?" for ch in text)


def log_line(kind, dest, detail, now):
    return "%s\tDENY\t%s\t%s\t%s\n" % (now, kind, _clean(dest), _clean(detail))


# ----------------------------------------------------------------------------
# I/O glue.
# ----------------------------------------------------------------------------

LOG_FILE = os.environ.get("SINK_LOG_FILE", "")
READY_FILE = "/run/agentdev-sink.ready"
DNS_PORT = 53
ETH_P_ALL = 0x0003
_log_lock = threading.Lock()


def parse_exempt(text):
    pairs = set()
    for item in filter(None, (part.strip() for part in text.split(","))):
        address, _, port = item.rpartition(":")
        pairs.add((address.strip("[]"), int(port)))
    return pairs


def log(kind, dest, detail):
    line = log_line(kind, dest, detail, datetime.now(timezone.utc).isoformat(timespec="seconds"))
    sys.stderr.write(line)
    if not LOG_FILE:
        return
    with _log_lock, open(LOG_FILE, "a") as fh:
        fh.write(line)


def ipv6_enabled():
    try:
        with open("/proc/sys/net/ipv6/conf/lo/disable_ipv6") as fh:
            return fh.read().strip() == "0"
    except OSError:
        return False


def setup_routes(with_ipv6):
    subprocess.run(["ip", "route", "add", "local", "default", "dev", "lo"], check=True)
    if with_ipv6:
        subprocess.run(["ip", "-6", "route", "add", "local", "default", "dev", "lo"], check=True)


def serve_dns(sock):
    while True:
        packet, client = sock.recvfrom(4096)
        try:
            name, qtype = parse_dns_query(packet)
        except ValueError as exc:
            log("DNS", "(unparseable query)", str(exc))
            continue
        log("DNS", name, qtype_name(qtype))
        sock.sendto(nxdomain_reply(packet), client)


def dns_socket(family, address):
    sock = socket.socket(family, socket.SOCK_DGRAM)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    sock.bind((address, DNS_PORT))
    return sock


def sniff(sock, exempt):
    while True:
        frame, info = sock.recvfrom(65535)
        found = classify(frame, info[0] == "lo", info[2] == socket.PACKET_OUTGOING, exempt)
        if found is None:
            continue
        kind, address, number = found
        if kind in ("TCP", "UDP"):
            log(kind, format_dest(address, number), "-")
        elif kind == "ICMP":
            log(kind, address, "type %d" % number)
        else:
            log(kind, address, "proto %d" % number)


def main():
    exempt = parse_exempt(os.environ.get("SINK_EXEMPT", ""))
    with_ipv6 = ipv6_enabled()
    setup_routes(with_ipv6)
    dns_sockets = [dns_socket(socket.AF_INET, "0.0.0.0")]
    if with_ipv6:
        dns_sockets.append(dns_socket(socket.AF_INET6, "::"))
    capture = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    for sock in dns_sockets:
        threading.Thread(target=serve_dns, args=(sock,), daemon=True).start()
    with open(READY_FILE, "w") as fh:
        fh.write("ready\n")
    sys.stderr.write("agentdev sink: ready (ipv6=%s, exempt=%s)\n" % (with_ipv6, sorted(exempt)))
    sniff(capture, exempt)


if __name__ == "__main__":
    main()
