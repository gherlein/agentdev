import os, sys, socket, struct, importlib.util
spec = importlib.util.spec_from_file_location("sink", os.path.join(os.path.dirname(__file__), "..", "image", "sink.py"))
sink = importlib.util.module_from_spec(spec); spec.loader.exec_module(sink)

def ok(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg); assert cond, msg

def raises(fn, exc, msg):
    try:
        fn()
    except exc:
        ok(True, msg); return
    ok(False, msg)

# --- DNS -----------------------------------------------------------------------------------

def query(name, qtype, qid=0x1234, flags=0x0100):
    q = struct.pack("!HHHHHH", qid, flags, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    return q + b"\0" + struct.pack("!HH", qtype, 1)

ok(sink.parse_dns_query(query("secret123.attacker.example", 1)) == ("secret123.attacker.example", 1),
   "A query: name and type parsed")
ok(sink.parse_dns_query(query("x.example", 28)) == ("x.example", 28), "AAAA query parsed")
raises(lambda: sink.parse_dns_query(b"\x12\x34\x01"), ValueError, "truncated header refused")
raises(lambda: sink.parse_dns_query(query("a.example", 1)[:-3]), ValueError, "truncated question refused")
compressed = struct.pack("!HHHHHH", 1, 0x0100, 1, 0, 0, 0) + b"\xc0\x0c" + struct.pack("!HH", 1, 1)
raises(lambda: sink.parse_dns_query(compressed), ValueError, "compression pointer in a question refused")
response = query("a.example", 1, flags=0x8180)
raises(lambda: sink.parse_dns_query(response), ValueError, "a response (QR=1) is not a query")

q = query("secret123.attacker.example", 1, qid=0xBEEF)
r = sink.nxdomain_reply(q)
rid, rflags, qd, an, ns, ar = struct.unpack("!HHHHHH", r[:12])
ok(rid == 0xBEEF, "reply keeps the query id")
ok(rflags & 0x8000 and rflags & 0x000F == 3, "reply is a response with rcode NXDOMAIN")
ok(rflags & 0x0100, "reply copies RD")
ok((qd, an, ns, ar) == (1, 0, 0, 0), "reply carries the question and no answers")
ok(r[12:] == q[12:], "reply echoes the question section")

ok(sink.qtype_name(1) == "A" and sink.qtype_name(28) == "AAAA" and sink.qtype_name(16) == "TXT",
   "common query types named")
ok(sink.qtype_name(4242) == "TYPE4242", "unknown query type numbered")

# --- frames --------------------------------------------------------------------------------

ETH4 = b"\0" * 12 + b"\x08\x00"
ETH6 = b"\0" * 12 + b"\x86\xdd"

def ip4(proto, dst, payload, src="10.0.0.2"):
    head = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(payload), 0, 0, 64, proto, 0,
                       socket.inet_aton(src), socket.inet_aton(dst))
    return ETH4 + head + payload

def ip6(next_header, dst, payload, src="fd00::2"):
    head = struct.pack("!IHBB16s16s", 6 << 28, len(payload), next_header, 64,
                       socket.inet_pton(socket.AF_INET6, src), socket.inet_pton(socket.AF_INET6, dst))
    return ETH6 + head + payload

def tcp(dport, flags):
    return struct.pack("!HHIIBBHHH", 40000, dport, 0, 0, 5 << 4, flags, 1024, 0, 0)

def udp(dport):
    return struct.pack("!HHHH", 40000, dport, 8, 0)

SYN, SYN_ACK, ACK, RST = 0x02, 0x12, 0x10, 0x04
NO_EXEMPT = set()
PROXY = {("10.89.0.3", 8080)}

c = sink.classify
# AnyIP: an off-network attempt arrives on lo (incoming copy) with its real destination.
ok(c(ip4(6, "1.2.3.4", tcp(443, SYN)), True, False, NO_EXEMPT) == ("TCP", "1.2.3.4", 443),
   "TCP SYN to an outside address on lo is an attempt")
ok(c(ip4(6, "1.2.3.4", tcp(443, SYN)), True, True, NO_EXEMPT) is None,
   "the outgoing copy on lo is not counted twice")
ok(c(ip4(6, "1.2.3.4", tcp(443, SYN_ACK)), True, False, NO_EXEMPT) is None, "SYN-ACK is not an attempt")
ok(c(ip4(6, "1.2.3.4", tcp(443, RST)), True, False, NO_EXEMPT) is None, "RST is not an attempt")
ok(c(ip4(6, "1.2.3.4", tcp(443, ACK)), True, False, NO_EXEMPT) is None, "ACK is not an attempt")
ok(c(ip4(17, "8.8.8.8", udp(53)), True, False, NO_EXEMPT) == ("UDP", "8.8.8.8", 53),
   "UDP to an outside address on lo is an attempt")
ok(c(ip4(1, "9.9.9.9", b"\x08\x00\0\0\0\0\0\0"), True, False, NO_EXEMPT) == ("ICMP", "9.9.9.9", 8),
   "ICMP echo to an outside address is an attempt")
ok(c(ip4(1, "9.9.9.9", b"\x03\x03\0\0\0\0\0\0"), True, False, NO_EXEMPT) is None,
   "an ICMP error (the kernel's own reply) is not an attempt")
ok(c(ip4(6, "127.0.0.1", tcp(53, SYN)), True, False, NO_EXEMPT) is None,
   "loopback-to-loopback traffic is the agent's own business")
ok(c(ip6(6, "2001:db8::1", tcp(443, SYN)), True, False, NO_EXEMPT) == ("TCP", "2001:db8::1", 443),
   "IPv6 TCP SYN to an outside address is an attempt")
ok(c(ip6(6, "::1", tcp(80, SYN)), True, False, NO_EXEMPT) is None, "IPv6 loopback ignored")
ok(c(ip6(58, "ff02::2", b"\x85\x00\0\0\0\0\0\0"), False, True, NO_EXEMPT) is None,
   "IPv6 neighbour discovery is not an attempt")

# A real interface (allowlist mode): every new flow leaving it, except the one to the proxy.
ok(c(ip4(6, "10.89.0.3", tcp(8080, SYN)), False, True, PROXY) is None, "SYN to the proxy is allowed traffic")
ok(c(ip4(6, "10.89.0.3", tcp(22, SYN)), False, True, PROXY) == ("TCP", "10.89.0.3", 22),
   "SYN to the proxy's other ports is an attempt")
ok(c(ip4(6, "10.89.0.1", tcp(80, SYN)), False, True, PROXY) == ("TCP", "10.89.0.1", 80),
   "SYN to the network gateway is an attempt")
ok(c(ip4(6, "10.89.0.1", tcp(80, SYN)), False, False, PROXY) is None,
   "incoming packets on a real interface are not the agent's attempts")
ok(c(ip4(2, "224.0.0.22", b"\0" * 8), False, True, PROXY) is None, "IGMP noise is ignored")
ok(c(ip4(17, "224.0.0.251", udp(5353)), False, True, PROXY) is None, "multicast is ignored")
ok(c(b"\0" * 12 + b"\x08\x06" + b"\0" * 28, False, True, PROXY) is None, "ARP is ignored")
ok(c(ETH4 + b"\x45\x00", True, False, NO_EXEMPT) is None, "a truncated frame is ignored")

# --- log lines -----------------------------------------------------------------------------

line = sink.log_line("TCP", sink.format_dest("1.2.3.4", 443), "-", "2026-11-01T00:00:00+00:00")
ok(line == "2026-11-01T00:00:00+00:00\tDENY\tTCP\t1.2.3.4:443\t-\n", "TCP line matches the egress log format")
ok(sink.format_dest("2001:db8::1", 443) == "[2001:db8::1]:443", "IPv6 destination bracketed")
line = sink.log_line("DNS", "secret123.attacker.example", "A", "2026-11-01T00:00:00+00:00")
ok(line.split("\t")[1:] == ["DENY", "DNS", "secret123.attacker.example", "A\n"], "DNS line: name and type")
ok(sink.log_line("DNS", "a\tb\nc", "A", "t").count("\t") == 4 and sink.log_line("DNS", "a\tb\nc", "A", "t").count("\n") == 1,
   "control characters in a name cannot break the log format")

print("SINK: all passed")
