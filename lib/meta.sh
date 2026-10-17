#!/bin/bash
# meta.sh - write/read agentdev.meta.json and agentdev.lock for a profile.
# Requires: python3, and $PROFILE / config globals set by the launcher.

# _hash_dir DIR -> sha256 over the sorted file list + contents (stable, portable).
_hash_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "sha256:none"; return; }
  local h
  h=$(cd "$dir" && find . -type f -not -path '*/.git/*' -print0 \
        | sort -z | xargs -0 cat 2>/dev/null | sha256sum | awk '{print $1}') || true
  echo "sha256:${h:-0}"
}

# _image_digest IMAGE -> the local digest if the image is present, else the ref.
_image_digest() {
  local image="$1" dig
  dig=$(podman image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null) || true
  [[ -n "$dig" ]] && { echo "$dig"; return; }
  echo "$image"
}

# _claude_version -> the Claude Code CLI version baked into the image, if we can read it.
_claude_version() {
  local v=""
  # Only introspect a locally present image; never trigger a registry pull here.
  if podman image exists "$IMAGE" 2>/dev/null; then
    v=$(podman run --rm "$IMAGE" claude --version 2>/dev/null | head -1 | awk '{print $1}') || true
  fi
  echo "${v:-unknown}"
}

write_meta() {
  local template_hash; template_hash=$(_hash_dir "$TEMPLATE_SOURCE")
  python3 - "$PROFILE/agentdev.meta.json" "$AGENT_NAME" "$MODE" "$RUN_ID" \
           "$TEMPLATE_SOURCE" "$template_hash" "$DIR_NAME" "${MEMORY_STORE:-}" <<'PY'
import json, sys, datetime
path, agent, mode, run_id, tsrc, thash, dirname, mem = sys.argv[1:9]
doc = {
    "schema": 1,
    "agent": agent,
    "mode": mode,
    "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": run_id,
    "template_source": tsrc,
    "template_hash": thash,
    "workspace_basename": dirname,
    "memory_store": mem or None,
}
with open(path, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
}

write_lock() {
  local image_digest template_hash claude_version mount_hash
  image_digest=$(_image_digest "$IMAGE")
  template_hash=$(_hash_dir "$TEMPLATE_SOURCE")
  claude_version=$(_claude_version)
  mount_hash=$(printf '%s\n' "${VOLUME_MOUNTS[@]:-}" | sha256sum | awk '{print $1}') || true
  python3 - "$PROFILE/agentdev.lock" "$image_digest" "$claude_version" \
           "$template_hash" "sha256:${mount_hash:-0}" <<'PY'
import json, sys
path, image, cver, thash, mhash = sys.argv[1:6]
doc = {
    "schema": 1,
    "image": image,
    "claude_code_version": cver,
    "template_hash": thash,
    "mount_set_hash": mhash,
}
with open(path, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
}
