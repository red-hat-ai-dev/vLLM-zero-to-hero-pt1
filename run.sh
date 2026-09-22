#!/bin/sh
set -eu

name="vllm-zero-to-hero"
volume="vllm-models"
port="8000"
state_dir="${TMPDIR:-/tmp}/vllm-zero-to-hero"
pid_file="$state_dir/metal.pid"
log_file="$state_dir/metal.log"
metal_venv="${VLLM_METAL_VENV:-$HOME/.venv-vllm-metal}"
metal_model="mlx-community/Qwen3.5-2B-4bit"
served_model="qwen3.5-2b"
managed_label="io.github.red-hat-ai-dev.vllm-zero-to-hero.managed"
backend=""
metal_pid=""

usage() {
  echo "Usage: ./run.sh [nvidia|amd|intel|metal]" >&2
}

error() {
  echo "Error: $*" >&2
}

require_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required but was not found."
    echo "Install curl, then run ./run.sh again." >&2
    exit 1
  fi
}

show_recent_logs() {
  echo >&2
  echo "Recent vLLM logs:" >&2
  if [ "$backend" = "metal" ]; then
    tail -n 40 "$log_file" >&2 2>/dev/null || true
  elif [ -n "${engine:-}" ]; then
    "$engine" logs --tail 40 "$name" >&2 2>/dev/null || true
  fi
}

cleanup_started_backend() {
  if [ "$backend" = "metal" ]; then
    if [ -n "$metal_pid" ] && kill -0 "$metal_pid" 2>/dev/null; then
      kill "$metal_pid" 2>/dev/null || true
      wait "$metal_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  elif [ "$backend" = "container" ]; then
    "$engine" rm --force "$name" >/dev/null 2>&1 || true
  fi
}

cancel_start() {
  echo >&2
  error "Startup was cancelled. Cleaning up so you can try again."
  cleanup_started_backend
  exit 130
}

backend_is_running() {
  if [ "$backend" = "metal" ]; then
    kill -0 "$metal_pid" 2>/dev/null
  else
    [ "$("$engine" inspect --format '{{.State.Running}}' "$name" 2>/dev/null || true)" = "true" ]
  fi
}

wait_until_ready() {
  attempt=0
  printf "Waiting for vLLM"
  until curl --fail --silent "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; do
    attempt=$((attempt + 1))

    if ! backend_is_running; then
      echo
      error "vLLM stopped before it became ready."
      show_recent_logs
      cleanup_started_backend
      return 1
    fi

    if [ "$attempt" -ge 360 ]; then
      echo
      error "vLLM did not become ready within 30 minutes."
      echo "Check your internet connection and available memory, then try again." >&2
      show_recent_logs
      cleanup_started_backend
      return 1
    fi

    printf "."
    sleep 5
  done

  echo
  trap - INT TERM HUP
  echo "vLLM is ready at http://127.0.0.1:$port/v1"
}

engine_is_running() {
  command -v "$1" >/dev/null 2>&1 && "$1" info >/dev/null 2>&1
}

engine_has_nvidia_support() {
  candidate="$1"
  case "$candidate" in
    podman|*/podman)
      if "$candidate" info 2>/dev/null | grep -Fq "nvidia.com/gpu=all"; then
        return 0
      fi
      command -v nvidia-ctk >/dev/null 2>&1 &&
        nvidia-ctk cdi list 2>/dev/null | grep -Fq "nvidia.com/gpu=all"
      ;;
    docker|*/docker)
      "$candidate" info --format '{{json .Runtimes}}' 2>/dev/null |
        grep -Fq '"nvidia"'
      ;;
    *) return 1 ;;
  esac
}

cleanup_partial_container() {
  label_value="$(
    "$engine" inspect --format "{{ index .Config.Labels \"$managed_label\" }}" \
      "$name" 2>/dev/null || true
  )"
  if [ "$label_value" = "true" ]; then
    "$engine" rm --force "$name" >/dev/null 2>&1 || true
  fi
}

show_nvidia_setup_error() {
  selected_engine="${1:-}"
  distro="Linux"
  if [ -r /etc/os-release ]; then
    detected_distro="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | sed -n '1p' | tr -d '"')"
    if [ -n "$detected_distro" ]; then
      distro="$detected_distro"
    fi
  fi

  if [ -n "$selected_engine" ]; then
    error "ENGINE is set to '$selected_engine', but it cannot access the NVIDIA GPU."
  else
    error "NVIDIA works on this $distro host, but no running container engine can access it."
  fi
  echo "The NVIDIA driver is available, but GPU container support is not configured." >&2
  echo "Install NVIDIA Container Toolkit, then run ./run.sh again:" >&2
  echo "https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html" >&2
  echo >&2
  echo "Podman must list nvidia.com/gpu=all in: nvidia-ctk cdi list" >&2
  echo "Docker must list an nvidia runtime in: docker info" >&2
}

select_engine() {
  if [ -n "${ENGINE:-}" ]; then
    if ! command -v "$ENGINE" >/dev/null 2>&1; then
      error "ENGINE is set to '$ENGINE', but that command was not found."
      exit 1
    fi
    if ! "$ENGINE" info >/dev/null 2>&1; then
      error "$ENGINE is installed but is not running."
      echo "Start $ENGINE, then run ./run.sh again." >&2
      exit 1
    fi
    if [ "$accelerator" = "nvidia" ] && ! engine_has_nvidia_support "$ENGINE"; then
      show_nvidia_setup_error "$ENGINE"
      exit 1
    fi
    engine="$ENGINE"
    return
  fi

  podman_running="false"
  docker_running="false"
  if engine_is_running podman; then
    podman_running="true"
  fi
  if engine_is_running docker; then
    docker_running="true"
  fi

  if [ "$podman_running" = "false" ] && [ "$docker_running" = "false" ]; then
    error "No running container engine was found."
    echo "Install and start Docker or Podman, then run ./run.sh again." >&2
    exit 1
  fi

  if [ "$accelerator" != "nvidia" ]; then
    if [ "$podman_running" = "true" ]; then
      engine="podman"
    else
      engine="docker"
    fi
    return
  fi

  if [ "$podman_running" = "true" ] && engine_has_nvidia_support podman; then
    engine="podman"
  elif [ "$docker_running" = "true" ] && engine_has_nvidia_support docker; then
    engine="docker"
  else
    show_nvidia_setup_error
    exit 1
  fi
}

detect_accelerator() {
  if [ "$requested" != "auto" ]; then
    accelerator="$requested"
  elif command -v nvidia-smi >/dev/null 2>&1 || [ -e /dev/nvidiactl ]; then
    accelerator="nvidia"
  elif [ -e /dev/kfd ]; then
    accelerator="amd"
  else
    accelerator=""
    for vendor_file in /sys/class/drm/card*/device/vendor; do
      [ -r "$vendor_file" ] || continue
      if [ "$(cat "$vendor_file")" = "0x8086" ]; then
        accelerator="intel"
        break
      fi
    done
  fi

  if [ -z "$accelerator" ]; then
    error "No supported NVIDIA, AMD, or Intel accelerator was detected."
    echo "Make sure the accelerator works inside Docker or Podman." >&2
    echo "You can override detection with ./run.sh nvidia, amd, or intel." >&2
    exit 1
  fi
}

run_linux() {
  case "$requested" in
    auto|nvidia|amd|intel) ;;
    metal)
      error "vLLM Metal is available only on an Apple Silicon Mac."
      exit 1
      ;;
    *)
      error "Unknown accelerator: $requested"
      usage
      exit 1
      ;;
  esac

  detect_accelerator
  echo "Detected Linux with $accelerator acceleration."
  if [ "$accelerator" = "intel" ]; then
    echo "Note: vLLM validates the Intel XPU path on Arc Pro B-series GPUs only."
  fi

  select_engine

  if "$engine" container inspect "$name" >/dev/null 2>&1; then
    error "$name already exists."
    echo "Run ./stop.sh, then try again." >&2
    exit 1
  fi

  echo "Using $engine."

  case "$accelerator" in
    nvidia)
      image="ghcr.io/red-hat-ai-dev/vllm-zero-to-hero:cuda"
      if [ "$engine" = "podman" ]; then
        set -- --device nvidia.com/gpu=all --security-opt=label=disable
      else
        set -- --gpus all
      fi
      ;;
    amd)
      image="ghcr.io/red-hat-ai-dev/vllm-zero-to-hero:rocm"
      set -- --device /dev/kfd --device /dev/dri --group-add video \
        --cap-add SYS_PTRACE --security-opt seccomp=unconfined
      ;;
    intel)
      image="ghcr.io/red-hat-ai-dev/vllm-zero-to-hero:xpu"
      set -- --device /dev/dri:/dev/dri \
        -v /dev/dri/by-path:/dev/dri/by-path --privileged
      ;;
    *)
      error "Unknown accelerator: $accelerator"
      usage
      exit 1
      ;;
  esac

  echo "Starting vLLM. The first run also downloads the model."
  if ! "$engine" run -d --name "$name" "$@" --ipc=host \
    -p "127.0.0.1:$port:8000" \
    -v "$volume:/root/.cache/huggingface" \
    --label "$managed_label=true" "$image"; then
    cleanup_partial_container
    error "$engine could not start the vLLM container."
    echo "Review the error above. A partial container created by this launcher was removed when present." >&2
    exit 1
  fi

  backend="container"
  trap cancel_start INT TERM HUP
  wait_until_ready
}

install_metal() {
  if [ -x "$metal_venv/bin/vllm" ]; then
    return
  fi

  if [ -n "${VLLM_METAL_VENV:-}" ]; then
    error "No vLLM executable was found in VLLM_METAL_VENV: $metal_venv"
    echo "Install vLLM Metal there or unset VLLM_METAL_VENV and try again." >&2
    exit 1
  fi

  echo "vLLM Metal is not installed yet."
  echo "Installing the official stable release in $metal_venv."
  echo "This is a one-time setup and may take several minutes."

  installer="$(mktemp "${TMPDIR:-/tmp}/vllm-metal-install.XXXXXX")"
  if ! curl --fail --silent --show-error --location \
    https://raw.githubusercontent.com/vllm-project/vllm-metal/main/install.sh \
    --output "$installer"; then
    rm -f "$installer"
    error "Could not download the official vLLM Metal installer."
    echo "Check your internet connection, then try again." >&2
    exit 1
  fi

  if ! bash "$installer" --stable; then
    rm -f "$installer"
    error "vLLM Metal installation failed."
    echo "Review the installer output above, then try again." >&2
    exit 1
  fi
  rm -f "$installer"

  if [ ! -x "$metal_venv/bin/vllm" ]; then
    error "Installation finished, but vLLM was not found at $metal_venv/bin/vllm."
    exit 1
  fi
}

run_macos() {
  case "$requested" in
    auto|metal) ;;
    nvidia|amd|intel)
      error "$requested acceleration through this launcher requires Linux."
      echo "On Apple Silicon, run ./run.sh without an override to use Metal." >&2
      exit 1
      ;;
    *)
      error "Unknown accelerator: $requested"
      usage
      exit 1
      ;;
  esac

  if [ "$(uname -m)" != "arm64" ]; then
    error "This Mac is not Apple Silicon. vLLM Metal requires an M-series Mac."
    exit 1
  fi

  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  if [ "$macos_major" -lt 15 ]; then
    error "vLLM Metal requires macOS 15 or newer."
    echo "This Mac is running macOS $(sw_vers -productVersion)." >&2
    exit 1
  fi

  mkdir -p "$state_dir"
  if [ -f "$pid_file" ]; then
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      if curl --fail --silent "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then
        echo "vLLM is already ready at http://127.0.0.1:$port/v1"
        return
      fi
      error "A vLLM Metal process is already starting."
      echo "Follow its progress with: tail -f $log_file" >&2
      exit 1
    fi
    rm -f "$pid_file"
  fi

  echo "Detected Apple Silicon."
  install_metal

  echo "Starting vLLM Metal with $metal_model."
  echo "The first run downloads about 2 GB of model data."
  : > "$log_file"
  nohup "$metal_venv/bin/vllm" serve "$metal_model" \
    --host 127.0.0.1 \
    --port "$port" \
    --served-model-name "$served_model" \
    --max-model-len 8192 >"$log_file" 2>&1 &
  metal_pid=$!
  echo "$metal_pid" > "$pid_file"
  backend="metal"
  trap cancel_start INT TERM HUP
  wait_until_ready
}

if [ "$#" -gt 1 ]; then
  usage
  exit 1
fi

requested="${1:-auto}"
require_curl

case "$(uname -s)" in
  Darwin) run_macos ;;
  Linux) run_linux ;;
  *)
    error "This operating system is not supported by the launcher: $(uname -s)"
    echo "Use Linux or an Apple Silicon Mac." >&2
    exit 1
    ;;
esac
