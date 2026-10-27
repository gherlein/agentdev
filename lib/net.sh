#!/bin/bash
# net.sh - egress isolation for agentdev (VISION §10).
#
# Modes (NET_MODE): off (host/default networking), none (no network at all),
# allowlist (only listed destinations reachable, via a filtering proxy sidecar).
#
# allowlist topology, which is what makes it safe under rootless podman:
#   - an INTERNAL podman network (no route out) that the agent container joins;
#   - a proxy sidecar joined to BOTH that internal network and a normal (egress)
#     network, so it alone can reach the outside;
#   - the agent is pointed at the proxy via HTTP(S)_PROXY and has no other route,
#     so a client that ignores the proxy cannot reach anything.
#
# Sets NET_ARGS (podman args for the agent container). Records PROXY_NAME /
# NET_INT / NET_EXT / NET_WORKDIR for teardown_network. Requires: podman,
# sha256sum, openssl (only for MITM); globals NET_MODE NET_ALLOW[] NET_LOG
# NET_MITM IMAGE RUN_ID PROFILE DRY_RUN.

NET_ARGS=()
PROXY_NAME=""; NET_INT=""; NET_EXT=""; NET_WORKDIR=""; EGRESS_LOG=""

# setup_network - resolve NET_ARGS and, unless --dry-run, bring up the network.
setup_network() {
  NET_ARGS=()
  case "$NET_MODE" in
    off)  return 0 ;;
    none) NET_ARGS=(--network none); return 0 ;;
    allowlist) : ;;
    *) echo "Error: unknown network mode '$NET_MODE'" >&2; exit 1 ;;
  esac

  if [[ ${#NET_ALLOW[@]} -eq 0 ]]; then
    echo "Error: network.mode=allowlist but network.allow is empty." >&2
    exit 1
  fi

  local id; id=$(printf '%s' "$RUN_ID" | sha256sum | cut -c1-10)
  NET_INT="agentdev-int-$id"
  NET_EXT="agentdev-ext-$id"
  PROXY_NAME="agentdev-proxy-$id"
  NET_WORKDIR="${XDG_RUNTIME_DIR:-/tmp}/agentdev-net-$id"
  EGRESS_LOG="$PROFILE/agentdev-egress.log"

  NET_ARGS=(
    --network "$NET_INT"
    -e "HTTPS_PROXY=http://$PROXY_NAME:8080" -e "HTTP_PROXY=http://$PROXY_NAME:8080"
    -e "https_proxy=http://$PROXY_NAME:8080" -e "http_proxy=http://$PROXY_NAME:8080"
    -e "NO_PROXY=localhost,127.0.0.1" -e "no_proxy=localhost,127.0.0.1"
  )
  if [[ "$NET_MITM" == true ]]; then
    # The agent must trust the MITM CA. Point the common toolchains' CA envs at it
    # (avoids colliding with the reserved host-CA mount target).
    NET_ARGS+=(
      -v "$NET_WORKDIR/ca.crt:/etc/agentdev/mitm-ca.crt:ro"
      -e "NODE_EXTRA_CA_CERTS=/etc/agentdev/mitm-ca.crt"
      -e "SSL_CERT_FILE=/etc/agentdev/mitm-ca.crt"
      -e "REQUESTS_CA_BUNDLE=/etc/agentdev/mitm-ca.crt"
      -e "CURL_CA_BUNDLE=/etc/agentdev/mitm-ca.crt"
    )
  fi

  [[ "$DRY_RUN" == yes ]] && return 0   # describe only; create nothing

  mkdir -p "$NET_WORKDIR"
  local allow_file="$NET_WORKDIR/allow.txt"
  printf '%s\n' "${NET_ALLOW[@]}" > "$allow_file"

  local proxy_env=(-e PROXY_ALLOW_FILE=/etc/agentdev/allow.txt -e PROXY_PORT=8080)
  # proxy.py is baked into the image (/usr/local/bin/agentdev-proxy.py), so the
  # sidecar is self-contained and pinned to the image digest — no host copy.
  local proxy_vols=(
    -v "$allow_file:/etc/agentdev/allow.txt:ro"
    -v "$PROFILE:/hostprofile:rw"
  )
  [[ "$NET_LOG" == true ]] && proxy_env+=(-e PROXY_LOG_FILE=/hostprofile/agentdev-egress.log)

  if [[ "$NET_MITM" == true ]]; then
    command -v openssl >/dev/null || { echo "Error: network.mitm=true needs openssl on the host." >&2; exit 1; }
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
      -keyout "$NET_WORKDIR/ca.key" -out "$NET_WORKDIR/ca.crt" \
      -subj "/CN=agentdev-mitm-$id" >/dev/null 2>&1
    proxy_vols+=(-v "$NET_WORKDIR/ca.crt:/etc/agentdev/ca.crt:ro" -v "$NET_WORKDIR/ca.key:/etc/agentdev/ca.key:ro")
    proxy_env+=(-e PROXY_MITM=1 -e PROXY_CA_CERT=/etc/agentdev/ca.crt -e PROXY_CA_KEY=/etc/agentdev/ca.key)
  fi

  podman network create --internal --label "agentdev.net=$id" "$NET_INT" >/dev/null
  podman network create          --label "agentdev.net=$id" "$NET_EXT" >/dev/null
  if ! podman run -d --pull=missing --name "$PROXY_NAME" --label "agentdev.proxy=$PROFILE" --label "agentdev.net=$id" \
         --network "$NET_INT" --network "$NET_EXT" \
         "${proxy_vols[@]}" "${proxy_env[@]}" "$IMAGE" python3 /usr/local/bin/agentdev-proxy.py >/dev/null; then
    echo "Error: failed to start egress proxy sidecar." >&2
    teardown_network
    exit 1
  fi
  echo "Network: allowlist via proxy ($PROXY_NAME), ${#NET_ALLOW[@]} rule(s)$( [[ "$NET_MITM" == true ]] && echo ', MITM on' )." >&2
}

# teardown_network - remove the proxy sidecar and networks. set -u-safe and
# idempotent; called from the launcher's EXIT trap.
teardown_network() {
  [[ "${NET_MODE:-off}" == allowlist ]] || return 0
  [[ -n "${PROXY_NAME:-}" ]] && podman rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
  [[ -n "${NET_INT:-}" ]] && podman network rm "$NET_INT" >/dev/null 2>&1 || true
  [[ -n "${NET_EXT:-}" ]] && podman network rm "$NET_EXT" >/dev/null 2>&1 || true
  [[ -n "${NET_WORKDIR:-}" && -d "$NET_WORKDIR" ]] && rm -rf "$NET_WORKDIR" || true
}

# The egress log (network.log=true) is a plain tab-separated file in the profile at
# <profile>/agentdev-egress.log:  ISO8601 <TAB> ALLOW|DENY <TAB> METHOD <TAB> host:port <TAB> path
# Read it with ordinary tools, e.g. a per-destination tally:
#   cut -f2,4 <profile>/agentdev-egress.log | sort | uniq -c | sort -rn
