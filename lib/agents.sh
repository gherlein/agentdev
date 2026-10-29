#!/bin/bash
# agents.sh - the per-agent table. agentdev maps a short agent name (claude|omp|pi)
# to its in-container executable, its home dir(s), where history and memory live
# under that home, its model environment variable, and its headless-prompt command.
#
# Claude is fully wired. omp and pi are present in the image and selectable; their
# headless command and model env are best-effort and marked below (VISION §9).
#
# The entrypoint symlinks the host $HOME to /home/developer, so the agent sees its
# dotfiles at the host home path while we mount at the physical path below.
AGENT_HOME=/home/developer

# agent_known NAME -> 0 if NAME is a supported agent.
agent_known() { case "$1" in claude|omp|pi) return 0 ;; *) return 1 ;; esac; }

# agent_home_items NAME -> the home dir(s)/file(s) this agent keeps, each a path
# relative to both agent_folder (host) and $AGENT_HOME (container). One per line.
# The last field "dir" or "file" says what to pre-create for a clean home (a "file" is a
# JSON config, seeded as {}).
agent_home_items() {
  case "$1" in
    claude) printf '.claude\tdir\n.claude.json\tfile\n' ;;
    omp)    printf '.omp\tdir\n' ;;
    pi)     printf '.pi\tdir\n' ;;
  esac
}

# agent_history_dest NAME ENC -> container path for the history redirect, or empty
# if this agent has no separable history folder.
agent_history_dest() {
  case "$1" in
    claude) printf '%s/.claude/projects/%s\n' "$AGENT_HOME" "$2" ;;
    pi)     printf '%s/.pi/agent/sessions\n' "$AGENT_HOME" ;;
    omp)    printf '\n' ;;   # history is a sqlite DB, not a separable folder
  esac
}

# agent_memory_dest NAME ENC -> container path for the memory redirect, or empty.
agent_memory_dest() {
  case "$1" in
    claude) printf '%s/.claude/projects/%s/memory\n' "$AGENT_HOME" "$2" ;;
    omp)    printf '%s/.omp/agent/memories\n' "$AGENT_HOME" ;;
    pi)     printf '\n' ;;   # pi keeps no memory store
  esac
}

# agent_model_env NAME -> the environment variable that selects the model, or empty
# (omp/pi route the model through .env/.envrc for now; VISION §9).
agent_model_env() {
  case "$1" in claude) printf 'ANTHROPIC_MODEL\n' ;; *) printf '\n' ;; esac
}

# agent_headless_cmd NAME PROMPT_PATH [EXTRA_FLAGS] -> the in-container command that
# runs the agent once on the prompt file, then exits. The prompt is read via command
# substitution and stdin is closed so a headless run never blocks on a TTY. EXTRA_FLAGS
# (container-side, agentdev-controlled: the mcp --strict-mcp-config/--mcp-config string)
# is spliced in for claude only; omp/pi have no such surface.
agent_headless_cmd() {
  local extra="${3:+$3 }"
  case "$1" in
    claude) printf 'claude --dangerously-skip-permissions %s-p "$(cat %q)" </dev/null' "$extra" "$2" ;;
    omp)    printf 'omp -p "$(cat %q)" </dev/null' "$2" ;;   # best-effort (VISION §9)
    pi)     printf 'pi -p "$(cat %q)" </dev/null' "$2" ;;    # best-effort (VISION §9)
  esac
}
