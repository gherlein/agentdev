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
print("ALL PROXY LOGIC TESTS PASSED")
