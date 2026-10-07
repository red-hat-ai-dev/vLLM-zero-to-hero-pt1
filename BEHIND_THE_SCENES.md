# Behind the scenes

The launcher starts an OpenAI-compatible vLLM server. You use the same API and
model name on every supported computer, but the way vLLM reaches the accelerator
depends on the operating system.

## What `run.sh` does

`run.sh` first checks the operating system:

- On an Apple Silicon Mac, it runs vLLM natively with the vLLM Metal plugin.
- On Linux, it starts a CUDA or ROCm container.

Both paths listen only on `127.0.0.1:8000`, wait for `/v1/models` to respond,
and expose the example model as `qwen3.5-2b`. Binding to `127.0.0.1` keeps the
API local to the computer instead of exposing it to the surrounding network.

The core command is:

```bash
vllm serve MODEL \
  --host 127.0.0.1 \
  --port 8000 \
  --served-model-name qwen3.5-2b \
  --max-model-len 8192
```

## Apple Silicon

[vLLM Metal](https://docs.vllm.ai/projects/vllm-metal/en/stable/) is the
community-maintained vLLM hardware plugin for Apple Silicon. It uses Apple's
MLX and Metal technologies while preserving vLLM's server and API.

If vLLM Metal is missing, the first `./run.sh` downloads the official installer
and selects its stable release. The installer creates:

```text
~/.venv-vllm-metal
```

The Mac path uses the smaller, four-bit
`mlx-community/Qwen3.5-2B-4bit` checkpoint. The API still calls it
`qwen3.5-2b`, so the request in the README works on every platform.

The server runs in the background. Its process ID and log are stored under the
system temporary directory:

```text
$TMPDIR/vllm-zero-to-hero/metal.pid
$TMPDIR/vllm-zero-to-hero/metal.log
```

To follow startup in more detail, run:

```bash
tail -f "${TMPDIR:-/tmp}/vllm-zero-to-hero/metal.log"
```

Set `VLLM_METAL_VENV` if you already maintain vLLM Metal in another virtual
environment:

```bash
VLLM_METAL_VENV=/path/to/venv ./run.sh
```

The launcher never changes a custom environment. The directory must already
contain `bin/vllm`.

## Linux containers

The Linux path detects the accelerator and selects one of these images:

| Accelerator | Image tag | vLLM base image |
| --- | --- | --- |
| NVIDIA | `cuda` | `vllm/vllm-openai:v0.28.0` |
| AMD | `rocm` | `vllm/vllm-openai-rocm:v0.28.0` |

The project image uses these defaults:

```bash
vllm serve Qwen/Qwen3.5-2B \
  --host 0.0.0.0 \
  --port 8000 \
  --served-model-name qwen3.5-2b \
  --max-model-len 8192
```

The container listens on all of its own interfaces. The launcher publishes that
port only on the host's loopback address:

```text
127.0.0.1:8000:8000
```

The launcher checks that Podman or Docker is actually running. For NVIDIA, it
also checks GPU container support before downloading the large CUDA image.
Podman must report the `nvidia.com/gpu=all` CDI device through `podman info` or
`nvidia-ctk cdi list`; Docker must report its `nvidia` runtime. The second
Podman check supports releases that can use CDI but omit resolved devices from
`podman info`. If Podman is running without CDI but Docker is ready, Docker is
selected automatically. For AMD, Podman remains the first choice.

Set `ENGINE` to choose one explicitly. An explicit engine must still pass the
same NVIDIA capability check:

```bash
ENGINE=docker ./run.sh
```

```bash
ENGINE=podman ./run.sh
```

Override accelerator detection when necessary:

```bash
./run.sh nvidia
```

```bash
./run.sh amd
```

The launcher maps port 8000, shares host memory, and mounts the `vllm-models`
volume at the Hugging Face cache path. The named volume keeps model files after
the container stops.

### NVIDIA

Docker passes the accelerator with:

```bash
--gpus all
```

Podman uses the NVIDIA Container Device Interface:

```bash
--device nvidia.com/gpu=all --security-opt=label=disable
```

The host must have the NVIDIA driver and
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
working before the launcher runs. The driver makes `nvidia-smi` work on the
host; the toolkit exposes that GPU safely inside containers. The launcher does
not install privileged system packages automatically. If integration is
missing, it reports the detected Linux distribution and stops before pulling
the image.

### AMD

ROCm uses the Linux kernel device nodes and video group:

```bash
--device /dev/kfd \
--device /dev/dri \
--group-add video \
--cap-add SYS_PTRACE \
--security-opt seccomp=unconfined
```

Consult the [vLLM installation guide](https://docs.vllm.ai/en/latest/getting_started/installation/)
for current hardware and driver requirements.

## Errors and automatic startup cleanup

The launcher waits up to 30 minutes because first-time installation and model
downloads can be slow. While it waits, it also checks whether the process or
container has exited. An early exit prints the last 40 log lines immediately.

If startup fails, times out, or is interrupted, the launcher removes the failed
process or container. This makes the next `./run.sh` a clean retry. Once the API
is ready, it stays in the background until `./stop.sh` is run.

Container creation can fail after an engine has reserved the project name, for
example when port 8000 is already occupied. The launcher also removes that
partially created container before returning an error.

`stop.sh` understands both backends. It stops the native Metal process when a
Metal PID file exists; otherwise, it removes the Linux container. It succeeds
quietly if neither one is running.

## Complete local cleanup

`./cleanup.sh` is for someone who wants to remove the local setup, not merely
stop the server. Before deleting anything, it lists the resources and asks for
confirmation. Pressing Enter or answering anything other than `y` or `yes`
cancels safely. `./cleanup.sh --yes` is available for intentional,
non-interactive cleanup.

On Apple Silicon, cleanup removes only these managed paths:

```text
~/.venv-vllm-metal
~/.cache/huggingface/hub/models--mlx-community--Qwen3.5-2B-4bit
~/.cache/huggingface/hub/.locks/models--mlx-community--Qwen3.5-2B-4bit
${TMPDIR:-/tmp}/vllm-zero-to-hero
```

If `HF_HOME` is set, the two model paths use that directory instead of
`~/.cache/huggingface`. Cleanup does not remove the rest of the Hugging Face
cache. If `VLLM_METAL_VENV` points to a custom environment, that custom path is
reported and preserved; only the default environment managed by this project is
removed.

On Linux, cleanup removes the `vllm-zero-to-hero` container, the
`vllm-models` volume, and temporary project state. The container image stays in
Docker or Podman's image cache. If the engine is installed but stopped, cleanup
asks the user to start it rather than pretending that its volume was removed.

Cleanup calls `stop.sh` first. If the running server cannot be stopped, cleanup
aborts before deleting its environment or model data. Running cleanup again
after it has completed is safe: missing resources are reported as already
removed.

## Build the container images

The GitHub Actions workflow publishes the `cuda` and `rocm` image tags.
It also publishes versioned tags such as `v0.1.0-cuda` when a matching Git tag
triggers the workflow.

Build a CUDA image locally:

```bash
docker build -t vllm-zero-to-hero:cuda .
```

Build a ROCm image:

```bash
docker build \
  --build-arg VLLM_IMAGE=docker.io/vllm/vllm-openai-rocm:v0.28.0 \
  -t vllm-zero-to-hero:rocm .
```

## Use another model

The image does not contain model weights. vLLM downloads the public example
model on first use and stores it in the mounted cache.

Pass a model and its options directly to the container image to replace the
defaults:

```bash
docker run --rm --gpus all --ipc=host -p 127.0.0.1:8000:8000 \
  -v vllm-models:/root/.cache/huggingface \
  ghcr.io/red-hat-ai-dev/vllm-zero-to-hero:cuda \
  Qwen/Qwen3.5-4B --served-model-name qwen3.5-4b
```

Set `HF_TOKEN` for a gated model and review its license before use. The example
Qwen models use the Apache-2.0 license; details are in their model cards.
