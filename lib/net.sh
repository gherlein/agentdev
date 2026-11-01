#!/bin/bash
# net.sh - egress isolation for agentdev (VISION §5).
#
# Modes (NET_MODE): off (host/default networking), none (no network at all),
# allowlist (only listed destinations reachable, via a filtering proxy sidecar).
#
# allowlist topology, which is what makes it safe under rootless podman:
#   - an INTERNAL podman network (no route out, no DNS server) for the proxy and the sink;
#   - a proxy sidecar joined to BOTH that internal network and a normal (egress)
#     network, so it alone can reach the outside;
#   - a sink sidecar on the internal network whose network namespace the agent JOINS
#     (--network container:<sink>). The sink holds NET_ADMIN, the agent never does: it
#     routes every outside address back into the namespace, records each attempt, and
#     answers every DNS query with NXDOMAIN (image/sink.py);
#   - the agent is pointed at the proxy via HTTP(S)_PROXY, with the proxy's address in its
#     /etc/hosts, so it needs no DNS and has no other way out.
# Without the sink, podman's network DNS forwarded any name the agent looked up to the
# host's resolver: a channel out that the proxy never saw.
#
# none + network.log: the agent joins a sink that has no network at all, so code that
# tries to reach out (an agent, or tests it wrote) is recorded instead of failing silently.
# Plain none (no log) is --network none.
#
# Model routing lives in .env/.envrc, so agentdev does not derive the model endpoint:
# under allowlist you add the model host to network.allow yourself.
#
# Sets NET_ARGS (podman args for the agent). Records PROXY_NAME / SINK_NAME / NET_INT /
# NET_EXT / NET_WORKDIR for teardown. The egress log (network.log) is written into the agent
# home (mounts.agent_folder); without an agent_folder it is ephemeral. Requires:
# podman, sha256sum, openssl (MITM only); globals NET_MODE NET_ALLOW[] NET_LOG
# NET_MITM IMAGE RUN_ID MNT_AGENT_FOLDER DRY_RUN.

NET_ARGS=()
PROXY_NAME=""; SINK_NAME=""; NET_INT=""; NET_EXT=""; NET_WORKDIR=""

# How long the sink may take to set up its routes and sockets before the run is refused.
SINK_READY_SECONDS=20
PROXY_PORT=8080
AGENT_HOSTNAME=agentdev
EGRESS_LOG_NAME=agentdev-egress.log

setup_network() {
  NET_ARGS=()
  case "$NET_MODE" in
    off)  return 0 ;;
    none) [[ "$NET_LOG" == true ]] || { NET_ARGS=(--network none); return 0; } ;;
    allowlist)
      if [[ ${#NET_ALLOW[@]} -eq 0 ]]; then
        echo "Error: network.mode=allowlist but network.allow is empty." >&2
        echo "       Add hosts to network.allow, or set network.mode to none for no egress." >&2
        exit 1
      fi ;;
    *) echo "Error: unknown network mode '$NET_MODE'" >&2; exit 1 ;;
  esac

  local id; id=$(printf '%s' "$RUN_ID" | sha256sum | cut -c1-10)
  SINK_NAME="agentdev-sink-$id"
  NET_WORKDIR="${XDG_RUNTIME_DIR:-/tmp}/agentdev-net-$id"
  # The agent's own name goes in its /etc/hosts too, so sudo can resolve it.
  NET_ARGS=(--network "container:$SINK_NAME" --hostname "$AGENT_HOSTNAME"
            -v "$NET_WORKDIR/resolv.conf:/etc/resolv.conf:ro" -v "$NET_WORKDIR/hosts:/etc/hosts:ro")

  if [[ "$NET_MODE" == allowlist ]]; then
    NET_INT="agentdev-int-$id"
    NET_EXT="agentdev-ext-$id"
    PROXY_NAME="agentdev-proxy-$id"
    NET_ARGS+=(
      -e "HTTPS_PROXY=http://$PROXY_NAME:$PROXY_PORT" -e "HTTP_PROXY=http://$PROXY_NAME:$PROXY_PORT"
      -e "https_proxy=http://$PROXY_NAME:$PROXY_PORT" -e "http_proxy=http://$PROXY_NAME:$PROXY_PORT"
      -e "NO_PROXY=localhost,127.0.0.1" -e "no_proxy=localhost,127.0.0.1"
    )
    if [[ "$NET_MITM" == true ]]; then
      NET_ARGS+=(
        -v "$NET_WORKDIR/ca.crt:/etc/agentdev/mitm-ca.crt:ro"
        -e "NODE_EXTRA_CA_CERTS=/etc/agentdev/mitm-ca.crt"
        -e "SSL_CERT_FILE=/etc/agentdev/mitm-ca.crt"
        -e "REQUESTS_CA_BUNDLE=/etc/agentdev/mitm-ca.crt"
        -e "CURL_CA_BUNDLE=/etc/agentdev/mitm-ca.crt"
      )
    fi
  fi

  [[ "$DRY_RUN" == yes ]] && return 0   # describe only; create nothing

  mkdir -p "$NET_WORKDIR"
  printf 'nameserver 127.0.0.1\noptions attempts:1 timeout:2\n' > "$NET_WORKDIR/resolv.conf"
  printf '127.0.0.1\tlocalhost %s\n::1\tlocalhost %s\n' "$AGENT_HOSTNAME" "$AGENT_HOSTNAME" > "$NET_WORKDIR/hosts"

  # Egress log: into the agent home if there is one, else ephemeral under NET_WORKDIR. The
  # proxy and the sink append to the same file.
  local log_home=""
  if [[ "$NET_LOG" == true ]]; then
    log_home="$MNT_AGENT_FOLDER"
    if [[ -z "$log_home" ]]; then
      log_home="$NET_WORKDIR/egress-home"
      echo "Note: network.log is on but mounts.agent_folder is unset; the egress log will be ephemeral." >&2
    fi
    mkdir -p "$log_home"
  fi

  local sink_net=(--network none) sink_env=()
  if [[ "$NET_MODE" == allowlist ]]; then
    start_proxy "$id" "$log_home"
    local proxy_ip
    proxy_ip=$(podman inspect --format "{{(index .NetworkSettings.Networks \"$NET_INT\").IPAddress}}" "$PROXY_NAME")
    if [[ ! "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Error: cannot find the proxy's address on $NET_INT (got '$proxy_ip')." >&2
      teardown_network; exit 1
    fi
    printf '%s\t%s\n' "$proxy_ip" "$PROXY_NAME" >> "$NET_WORKDIR/hosts"
    sink_net=(--network "$NET_INT")
    sink_env=(-e "SINK_EXEMPT=$proxy_ip:$PROXY_PORT")
  fi
  start_sink "$id" "$log_home" "${sink_net[@]}" "${sink_env[@]}"

  if [[ "$NET_MODE" == allowlist ]]; then
    echo "Network: allowlist via proxy ($PROXY_NAME) and sink ($SINK_NAME), ${#NET_ALLOW[@]} rule(s)$( [[ "$NET_MITM" == true ]] && echo ', MITM on' )." >&2
  else
    echo "Network: none; every attempt is logged by the sink ($SINK_NAME)." >&2
  fi
}

# start_proxy ID LOG_HOME - the allowlist networks and the proxy sidecar.
start_proxy() {
  local id="$1" log_home="$2"
  local allow_file="$NET_WORKDIR/allow.txt"
  printf '%s\n' "${NET_ALLOW[@]}" > "$allow_file"

  local proxy_env=(-e PROXY_ALLOW_FILE=/etc/agentdev/allow.txt -e "PROXY_PORT=$PROXY_PORT")
  local proxy_vols=(-v "$allow_file:/etc/agentdev/allow.txt:ro")
  if [[ -n "$log_home" ]]; then
    proxy_vols+=(-v "$log_home:/egress-home:rw")
    proxy_env+=(-e "PROXY_LOG_FILE=/egress-home/$EGRESS_LOG_NAME")
  fi

  if [[ "$NET_MITM" == true ]]; then
    command -v openssl >/dev/null || { echo "Error: network.mitm=true needs openssl on the host." >&2; exit 1; }
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
      -keyout "$NET_WORKDIR/ca.key" -out "$NET_WORKDIR/ca.crt" \
      -subj "/CN=agentdev-mitm-$id" >/dev/null 2>&1
    proxy_vols+=(-v "$NET_WORKDIR/ca.crt:/etc/agentdev/ca.crt:ro" -v "$NET_WORKDIR/ca.key:/etc/agentdev/ca.key:ro")
    proxy_env+=(-e PROXY_MITM=1 -e PROXY_CA_CERT=/etc/agentdev/ca.crt -e PROXY_CA_KEY=/etc/agentdev/ca.key)
  fi

  # Run the proxy as the host user, like the agent: otherwise the entrypoint drops it to the
  # image's developer, an unmapped subuid on the host that cannot write the egress log into
  # the host-owned agent folder (and the proxy swallows that write error).
  local proxy_userns=()
  [[ "$(uname -s)" == "Linux" ]] && proxy_userns=("--userns=keep-id")

  # --disable-dns: podman's network DNS forwards unknown names to the host's resolver, which
  # would let the agent send data out inside names. The agent finds the proxy via /etc/hosts.
  podman network create --internal --disable-dns --label "agentdev.net=$id" "$NET_INT" >/dev/null
  podman network create                          --label "agentdev.net=$id" "$NET_EXT" >/dev/null
  if ! podman run -d --pull=missing --name "$PROXY_NAME" --label "agentdev.proxy=$id" --label "agentdev.net=$id" \
         "${proxy_userns[@]}" --network "$NET_INT" --network "$NET_EXT" \
         "${proxy_vols[@]}" "${proxy_env[@]}" "$IMAGE" python3 /usr/local/bin/agentdev-proxy.py >/dev/null; then
    echo "Error: failed to start egress proxy sidecar." >&2
    teardown_network
    exit 1
  fi
}

# start_sink ID LOG_HOME PODMAN_ARGS... - the sink sidecar, then wait until its routes and
# sockets are in place: an agent started earlier could slip a packet past it.
start_sink() {
  local id="$1" log_home="$2"; shift 2
  local sink_vols=() sink_env=()
  if [[ -n "$log_home" ]]; then
    sink_vols=(-v "$log_home:/egress-home:rw")
    sink_env=(-e "SINK_LOG_FILE=/egress-home/$EGRESS_LOG_NAME")
  fi
  # Root in a rootless container is the host user, so the sink writes the log as the host
  # user. NET_ADMIN sets the routes, NET_RAW captures; both stay in the sink's container.
  if ! podman run -d --pull=missing --name "$SINK_NAME" --label "agentdev.sink=$id" --label "agentdev.net=$id" \
         --user 0 --cap-add NET_ADMIN --cap-add NET_RAW "$@" \
         "${sink_vols[@]}" "${sink_env[@]}" --entrypoint python3 "$IMAGE" -u /usr/local/bin/agentdev-sink.py >/dev/null; then
    echo "Error: failed to start the network sink sidecar." >&2
    teardown_network
    exit 1
  fi
  local waited
  for (( waited = 0; waited < SINK_READY_SECONDS * 4; waited++ )); do
    podman exec "$SINK_NAME" test -e /run/agentdev-sink.ready 2>/dev/null && return 0
    if [[ "$(podman inspect --format '{{.State.Running}}' "$SINK_NAME" 2>/dev/null)" != true ]]; then
      break
    fi
    sleep 0.25
  done
  echo "Error: the network sink did not come up; its log:" >&2
  podman logs "$SINK_NAME" 2>&1 | tail -n 20 >&2
  teardown_network
  exit 1
}

# teardown_network - remove the sidecars and networks. set -u-safe, idempotent.
teardown_network() {
  [[ -n "${SINK_NAME:-}" ]] && podman rm -f -t 0 "$SINK_NAME" >/dev/null 2>&1 || true
  [[ -n "${PROXY_NAME:-}" ]] && podman rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
  [[ -n "${NET_INT:-}" ]] && podman network rm "$NET_INT" >/dev/null 2>&1 || true
  [[ -n "${NET_EXT:-}" ]] && podman network rm "$NET_EXT" >/dev/null 2>&1 || true
  [[ -n "${NET_WORKDIR:-}" && -d "$NET_WORKDIR" ]] && rm -rf "$NET_WORKDIR" || true
}

# The egress log (network.log=true) is a plain tab-separated file at
# <agent_folder>/agentdev-egress.log:  ISO8601 <TAB> ALLOW|DENY <TAB> KIND <TAB> destination <TAB> detail
# The proxy writes HTTP methods and CONNECT (destination host:port, detail the path); the sink
# writes DNS (the name, the query type), TCP and UDP (address:port), ICMP and IP.
# Read it with ordinary tools, e.g. a per-destination tally:
#   cut -f2,3,4 <agent_folder>/agentdev-egress.log | sort | uniq -c | sort -rn
