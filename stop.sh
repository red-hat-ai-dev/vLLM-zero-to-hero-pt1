#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/engine.sh
. "$script_dir/scripts/engine.sh"
managed_label="io.github.red-hat-ai-dev.vllm-zero-to-hero.managed"

name="vllm-zero-to-hero"
state_dir="${TMPDIR:-/tmp}/vllm-zero-to-hero"
pid_file="$state_dir/metal.pid"

error() {
  echo "Error: $*" >&2
}

stop_metal() {
  if [ ! -f "$pid_file" ]; then
    return 1
  fi

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    echo "vLLM Metal is already stopped."
    return 0
  fi

  process="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$process" in
    *vllm*) ;;
    *)
      rm -f "$pid_file"
      echo "vLLM Metal is already stopped."
      return 0
      ;;
  esac

  echo "Stopping vLLM Metal..."
  kill "$pid" 2>/dev/null || true
  attempt=0
  while kill -0 "$pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 20 ]; then
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  rm -f "$pid_file"
  echo "vLLM Metal stopped."
  return 0
}

select_engine() {
  resolve_managed_engine "$name" "$managed_label" "${volume:-}"
}

if stop_metal; then
  exit 0
fi
if [ "$(uname -s)" = Darwin ]; then
  echo "vLLM Metal is already stopped."
  exit 0
fi

select_engine
if [ -z "$engine" ]; then
  echo "vLLM is already stopped."
  exit 0
fi

if ! "$engine" container inspect "$name" >/dev/null 2>&1; then
  echo "vLLM is already stopped."
  exit 0
fi

echo "Stopping the vLLM container..."
if ! "$engine" rm --force "$name" >/dev/null; then
  error "$engine could not stop the vLLM container."
  exit 1
fi
echo "vLLM container stopped."
