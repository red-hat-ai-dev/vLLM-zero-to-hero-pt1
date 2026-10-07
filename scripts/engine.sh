# Resolve the engine that owns this tutorial's resources, not the first daemon.
# Arguments: container name, managed label, optional cleanup volume.
# shellcheck shell=sh
resolve_managed_engine() {
  resource_name="$1"
  resource_label="$2"
  resource_volume="${3:-}"
  engine=""
  resource_key=""
  unavailable=""
  if [ -n "${ENGINE:-}" ]; then set -- "$ENGINE"; else set -- podman docker; fi
  for candidate in "$@"; do
    command -v "$candidate" >/dev/null 2>&1 || {
      if [ -n "${ENGINE:-}" ]; then
        echo "Error: ENGINE command not found: $candidate" >&2
        return 1
      fi
      continue
    }
    if ! "$candidate" info >/dev/null 2>&1; then
      unavailable="$unavailable $candidate"
      continue
    fi
    container_id="$("$candidate" container inspect --format '{{.Id}}' "$resource_name" 2>/dev/null || true)"
    volume_path=""
    if [ -n "${resource_volume:-}" ]; then
      volume_path="$("$candidate" volume inspect --format '{{.Mountpoint}}' "$resource_volume" 2>/dev/null || true)"
    fi
    [ -n "$container_id$volume_path" ] || continue
    if [ -n "$container_id" ]; then
      owner="$("$candidate" inspect --format "{{ index .Config.Labels \"$resource_label\" }}" "$resource_name" 2>/dev/null || true)"
      if [ "$owner" != true ]; then
        echo "Error: refusing to remove unrelated container '$resource_name' in $candidate (missing managed label)." >&2
        return 1
      fi
    fi
    # docker may be a Podman compatibility command: identical resources are one owner.
    key="$container_id:$volume_path"
    if [ -n "$engine" ] && [ "$key" != "$resource_key" ]; then
      echo "Error: tutorial resources exist in both Podman and Docker. Set ENGINE explicitly." >&2
      return 1
    fi
    engine="$candidate"
    resource_key="$key"
  done
  if [ -n "$unavailable" ]; then
    echo "Error: cannot inspect container engine(s):$unavailable. Start them or set ENGINE to the owner." >&2
    return 1
  fi
}
