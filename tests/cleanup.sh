#!/bin/bash
# cleanup.sh - scoped container teardown for the live tiers (sourced, not run).
#
# An interrupted test can leave an agent container or a proxy sidecar behind, so each tier
# removes leftovers on exit. That removal must touch only what THIS test run started: a
# blanket "remove every agentdev-labelled container" kills the operator's own running
# agentdev sessions.
#
#   PROXIES_BEFORE="$(agentdev_proxy_ids)"            # at test start
#   remove_own_containers "$ROOT" "$PROXIES_BEFORE"   # in the EXIT trap

# agentdev_proxy_ids -> the IDs of every agentdev proxy sidecar now present, sorted.
agentdev_proxy_ids() {
  timeout 30 podman ps -a --filter label=agentdev.proxy -q 2>/dev/null | sort
}

# remove_own_containers ROOT PROXIES_BEFORE
#   Agent containers carry agentdev.home=<agent_folder>, and the tests keep every agent folder
#   under ROOT, so they are matched by that prefix. Proxy sidecars carry no path, so only the
#   ones that did not exist when the test started are removed.
remove_own_containers() {
  local root="$1" before="$2" id home
  while read -r id home; do
    [[ -n "$id" && "$home" == "$root"/* ]] || continue
    timeout 30 podman rm -f "$id" >/dev/null 2>&1 || true
  done < <(timeout 30 podman ps -a --filter label=agentdev.home \
             --format '{{.ID}} {{index .Labels "agentdev.home"}}' 2>/dev/null)
  comm -13 <(printf '%s\n' "$before") <(agentdev_proxy_ids) \
    | xargs -r timeout 30 podman rm -f >/dev/null 2>&1 || true
}
