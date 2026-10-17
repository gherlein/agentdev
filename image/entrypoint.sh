#!/bin/bash
# agentdev container entrypoint. Remaps the in-image `developer` user to the host
# UID/GID, points its home at the host's $HOME path, and creates the host-home
# symlink so absolute paths baked into config resolve. Then execs the command.
set -e

HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}
HOST_USER=${HOST_USER:-developer}
HOST_HOME=${HOST_HOME:-/home/developer}

link_host_home() {
  # Symlink the host's absolute home path to the physical /home/developer so that
  # $HOME, ~, and absolute paths in config all resolve to the same place.
  if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/developer" ] && [ ! -e "$HOST_HOME" ]; then
    mkdir -p "$(dirname "$HOST_HOME")" 2>/dev/null || true
    ln -sfn /home/developer "$HOST_HOME" 2>/dev/null || true
  fi
}

if [ "$(id -u)" = "0" ]; then
  link_host_home

  if [ "$HOST_GID" != "1000" ]; then
    if ! getent group "$HOST_GID" >/dev/null 2>&1; then
      groupmod -g "$HOST_GID" developer
    else
      groupdel developer 2>/dev/null || true
      usermod -g "$HOST_GID" developer
    fi
  fi
  if [ "$HOST_UID" != "1000" ]; then
    usermod -u "$HOST_UID" developer
    chown "$HOST_UID:$HOST_GID" /home/developer 2>/dev/null || true
    for item in .bashrc .profile .config .cache .local .npm; do
      [ -e "/home/developer/$item" ] && chown -R "$HOST_UID:$HOST_GID" "/home/developer/$item" 2>/dev/null || true
    done
  fi
  if [ "$HOST_USER" != "developer" ]; then
    usermod -l "$HOST_USER" -d "$HOST_HOME" developer 2>/dev/null || true
    echo "$HOST_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agentdev
  fi

  if [ "${REFRESH_CA_CERTS:-}" = "1" ]; then
    /usr/sbin/update-ca-certificates >/dev/null 2>&1 || true
  fi

  export HOME="$HOST_HOME"
  exec gosu "$HOST_USER" "$@"
else
  # Non-root (e.g. --userns=keep-id). Use sudo for the privileged bits.
  if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/developer" ] && [ ! -e "$HOST_HOME" ]; then
    sudo mkdir -p "$(dirname "$HOST_HOME")" 2>/dev/null || true
    sudo ln -sfn /home/developer "$HOST_HOME" 2>/dev/null || true
  fi
  if [ "${REFRESH_CA_CERTS:-}" = "1" ]; then
    sudo /usr/sbin/update-ca-certificates >/dev/null 2>&1 || true
  fi
  export HOME="${HOST_HOME:-/home/developer}"
  exec "$@"
fi
