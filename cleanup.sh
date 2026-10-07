#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/engine.sh
. "$script_dir/scripts/engine.sh"
managed_label="io.github.red-hat-ai-dev.vllm-zero-to-hero.managed"

name="vllm-zero-to-hero"
volume="vllm-models"
temp_root="${TMPDIR:-/tmp}"
state_dir="${temp_root%/}/vllm-zero-to-hero"
user_home="${HOME:-}"
default_metal_venv="$user_home/.venv-vllm-metal"
hf_home="${HF_HOME:-$user_home/.cache/huggingface}"
metal_model_cache="$hf_home/hub/models--mlx-community--Qwen3.5-2B-4bit"
metal_model_locks="$hf_home/hub/.locks/models--mlx-community--Qwen3.5-2B-4bit"
assume_yes="false"
engine=""

usage() {
  echo "Usage: ./cleanup.sh [--yes]"
  echo
  echo "Stop vLLM and remove files downloaded by vLLM Zero to Hero."
  echo "  --yes  Skip the confirmation prompt."
}

error() {
  echo "Error: $*" >&2
}

if [ -z "$user_home" ] || [ "$user_home" = "/" ]; then
  error "HOME does not point to a safe user directory. Nothing was removed."
  exit 1
fi

if [ -z "$hf_home" ] || [ "$hf_home" = "/" ]; then
  error "HF_HOME does not point to a safe cache directory. Nothing was removed."
  exit 1
fi

describe_path() {
  label="$1"
  path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "  - $label: $path"
  else
    echo "  - $label: already removed"
  fi
}

confirm_cleanup() {
  if [ "$assume_yes" = "true" ]; then
    return
  fi

  printf "Continue with complete cleanup? [y/N] "
  answer=""
  read -r answer || true
  case "$answer" in
    y|Y|[yY][eE][sS]) ;;
    *)
      echo "Cleanup cancelled. Nothing was removed."
      exit 0
      ;;
  esac
}

remove_managed_path() {
  label="$1"
  path="$2"

  case "$label" in
    "Metal environment") expected="$default_metal_venv" ;;
    "example model") expected="$metal_model_cache" ;;
    "example model locks") expected="$metal_model_locks" ;;
    "temporary state") expected="$state_dir" ;;
    *)
      error "Refusing to remove an unknown resource: $label"
      return 1
      ;;
  esac

  if [ -z "$path" ] || [ "$path" = "/" ] || [ "$path" = "$user_home" ] || [ "$path" != "$expected" ]; then
    error "Refusing to remove an unexpected path: $path"
    return 1
  fi

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    echo "$label is already removed."
    return
  fi

  echo "Removing $label..."
  if ! rm -rf "$path"; then
    error "Could not remove $label at $path"
    return 1
  fi
  echo "Removed $label."
}

select_engine() {
  resolve_managed_engine "$name" "$managed_label" "${volume:-}"
}

remove_linux_volume() {
  if [ -z "$engine" ]; then
    echo "Container model volume is already removed."
    return
  fi

  if ! "$engine" volume inspect "$volume" >/dev/null 2>&1; then
    echo "Container model volume is already removed."
    return
  fi

  echo "Removing container model volume '$volume' with $engine..."
  if ! "$engine" volume rm "$volume" >/dev/null; then
    error "$engine could not remove the '$volume' volume."
    return 1
  fi
  echo "Removed container model volume."
}

case "${1:-}" in
  "") ;;
  --yes) assume_yes="true" ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    error "Unknown option: $1"
    usage >&2
    exit 1
    ;;
esac

if [ "$#" -gt 1 ]; then
  error "Too many options."
  usage >&2
  exit 1
fi

os="$(uname -s)"
case "$os" in
  Darwin)
    echo "This will stop vLLM and permanently remove:"
    describe_path "example model" "$metal_model_cache"
    describe_path "example model locks" "$metal_model_locks"
    describe_path "temporary logs and state" "$state_dir"
    if [ -n "${VLLM_METAL_VENV:-}" ] && [ "$VLLM_METAL_VENV" != "$default_metal_venv" ]; then
      echo
      echo "Your custom VLLM_METAL_VENV will not be removed: $VLLM_METAL_VENV"
    fi
    ;;
  Linux)
    select_engine
    echo "This will stop vLLM and permanently remove:"
    echo "  - container: $name"
    echo "  - downloaded model volume: $volume"
    describe_path "temporary logs and state" "$state_dir"
    ;;
  *)
    error "This operating system is not supported: $os"
    exit 1
    ;;
esac

echo
echo "Other Hugging Face models and container images will not be removed."
echo "The next ./run.sh will download the required files again."
echo
echo "The shared vLLM Metal environment is kept."
confirm_cleanup

script_dir="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
if [ "$os" = "Linux" ] && [ -n "$engine" ]; then
  if ! ENGINE="$engine" "$script_dir/stop.sh"; then
    error "vLLM could not be stopped, so nothing else was removed."
    exit 1
  fi
else
  if ! "$script_dir/stop.sh"; then
    error "vLLM could not be stopped, so nothing else was removed."
    exit 1
  fi
fi

if [ "$os" = "Darwin" ]; then
  remove_managed_path "example model" "$metal_model_cache"
  remove_managed_path "example model locks" "$metal_model_locks"
else
  remove_linux_volume
fi
remove_managed_path "temporary state" "$state_dir"

echo "Cleanup complete. Run ./run.sh whenever you want to start again."
