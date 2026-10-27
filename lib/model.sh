#!/bin/bash
# model.sh - which model the agent uses and where it reaches it (model.* config).
#
# For Claude Code (the only agent so far) the model is selected entirely through
# environment variables, so the same settings apply to an interactive `claude` and
# to a headless --prompt run:
#
#   model.id        -> ANTHROPIC_MODEL
#   model.provider  anthropic (default) | bedrock (CLAUDE_CODE_USE_BEDROCK=1)
#                                       | vertex  (CLAUDE_CODE_USE_VERTEX=1)
#   model.base_url  -> ANTHROPIC_BASE_URL / ANTHROPIC_BEDROCK_BASE_URL /
#                      ANTHROPIC_VERTEX_BASE_URL, per provider
#   model.pass_env  host variables forwarded by name (provider credentials, region)
#
# Sets MODEL_ARGS (podman args) and MODEL_ENDPOINT_HOST / MODEL_ENDPOINT_PORT, the
# destination the agent must reach; under network.mode=allowlist that destination
# must be allowed (assert_model_endpoint_allowed). Requires the config globals.

# Variables agentdev sets itself; forwarding a host value for them would silently
# override (or be overridden by) agentdev's own wiring.
MODEL_RESERVED_ENV=(
  ANTHROPIC_MODEL ANTHROPIC_BASE_URL ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
  HOST_UID HOST_GID HOST_HOME HOST_USER WORKSPACE AGENTDEV_WORKDIR SSH_AUTH_SOCK
  HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY no_proxy
  REFRESH_CA_CERTS NODE_EXTRA_CA_CERTS SSL_CERT_FILE REQUESTS_CA_BUNDLE CURL_CA_BUNDLE
)

ANTHROPIC_DEFAULT_HOST="api.anthropic.com"
HTTPS_PORT=443
HTTP_PORT=80

# _url_host_port URL - print "host port" for an http(s) URL (validated by the schema).
_url_host_port() {
  local url="$1" scheme rest hostport host port
  scheme="${url%%://*}"
  rest="${url#*://}"
  hostport="${rest%%/*}"
  host="${hostport%%:*}"
  if [[ "$hostport" == *:* ]]; then port="${hostport##*:}"
  elif [[ "$scheme" == https ]]; then port=$HTTPS_PORT
  else port=$HTTP_PORT; fi
  printf '%s %s\n' "$host" "$port"
}

# _require_passed_env NAME - the provider needs NAME from the host, via pass_env.
_require_passed_env() {
  local name="$1" entry
  for entry in "${MODEL_PASS_ENV[@]:-}"; do
    [[ "$entry" == "$name" ]] && return 0
  done
  echo "Error: model.provider=$MODEL_PROVIDER without model.base_url needs $name; add it to model.pass_env." >&2
  exit 1
}

setup_model() {
  MODEL_ARGS=()
  local name reserved
  for name in "${MODEL_PASS_ENV[@]:-}"; do
    [[ -n "$name" ]] || continue
    for reserved in "${MODEL_RESERVED_ENV[@]}"; do
      if [[ "$name" == "$reserved" ]]; then
        echo "Error: model.pass_env: $name is set by agentdev itself; remove it." >&2
        exit 1
      fi
    done
    if [[ -z "${!name+set}" ]]; then
      echo "Error: model.pass_env: $name is not set in the host environment." >&2
      exit 1
    fi
    # "-e NAME" without a value makes podman copy the host value, so the secret
    # never appears in agentdev's argv or --dry-run output.
    MODEL_ARGS+=(-e "$name")
  done

  [[ -n "$MODEL_ID" ]] && MODEL_ARGS+=(-e "ANTHROPIC_MODEL=$MODEL_ID")

  local endpoint=""
  case "$MODEL_PROVIDER" in
    anthropic)
      if [[ -n "$MODEL_BASE_URL" ]]; then
        MODEL_ARGS+=(-e "ANTHROPIC_BASE_URL=$MODEL_BASE_URL")
        endpoint=$(_url_host_port "$MODEL_BASE_URL")
      else
        endpoint="$ANTHROPIC_DEFAULT_HOST $HTTPS_PORT"
      fi ;;
    bedrock)
      MODEL_ARGS+=(-e "CLAUDE_CODE_USE_BEDROCK=1")
      if [[ -n "$MODEL_BASE_URL" ]]; then
        MODEL_ARGS+=(-e "ANTHROPIC_BEDROCK_BASE_URL=$MODEL_BASE_URL")
        endpoint=$(_url_host_port "$MODEL_BASE_URL")
      else
        _require_passed_env AWS_REGION
        endpoint="bedrock-runtime.${AWS_REGION}.amazonaws.com $HTTPS_PORT"
      fi ;;
    vertex)
      MODEL_ARGS+=(-e "CLAUDE_CODE_USE_VERTEX=1")
      if [[ -n "$MODEL_BASE_URL" ]]; then
        MODEL_ARGS+=(-e "ANTHROPIC_VERTEX_BASE_URL=$MODEL_BASE_URL")
        endpoint=$(_url_host_port "$MODEL_BASE_URL")
      else
        _require_passed_env CLOUD_ML_REGION
        if [[ "$CLOUD_ML_REGION" == global ]]; then
          endpoint="aiplatform.googleapis.com $HTTPS_PORT"
        else
          endpoint="${CLOUD_ML_REGION}-aiplatform.googleapis.com $HTTPS_PORT"
        fi
      fi ;;
    *) echo "Error: unknown model.provider '$MODEL_PROVIDER'" >&2; exit 1 ;;
  esac
  read -r MODEL_ENDPOINT_HOST MODEL_ENDPOINT_PORT <<< "$endpoint"
}

# assert_model_endpoint_allowed - under an allowlist, the agent's model endpoint
# must be reachable through the proxy, or the agent cannot work at all. Checked
# with the proxy's own matching rules so the answer cannot drift from enforcement.
assert_model_endpoint_allowed() {
  [[ "$NET_MODE" == allowlist ]] || return 0
  if ! python3 "$LIBDIR/allowcheck.py" "$SELFDIR/image" "$MODEL_ENDPOINT_HOST" "$MODEL_ENDPOINT_PORT" "${NET_ALLOW[@]}"; then
    echo "Error: network.mode=allowlist does not allow the model endpoint $MODEL_ENDPOINT_HOST:$MODEL_ENDPOINT_PORT." >&2
    echo "       Add \"$MODEL_ENDPOINT_HOST\" to network.allow." >&2
    exit 1
  fi
}
