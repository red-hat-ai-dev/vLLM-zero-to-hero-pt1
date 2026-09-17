# vLLM Zero to Hero

### *This is part one in a four part series. Follow the vLLM-zero-to-hero [campaign path](https://github.com/red-hat-ai-dev/vLLM-zero-to-hero-overview) to learn more!*

Start a local, OpenAI-compatible AI API with one command. The launcher supports
Apple Silicon Macs and Linux computers with NVIDIA, AMD, or Intel acceleration.

Want to know what the launcher is doing? Read
[Behind the scenes](BEHIND_THE_SCENES.md).

## Requirements

Every computer needs:

- Git and curl
- Internet access for the first setup and model download
- At least 8 GB of available memory and several GB of free disk space

The launcher supports:

- **Apple Silicon:** an M-series Mac running macOS 15 or newer. The first run
  installs the official stable vLLM Metal environment automatically.
- **Linux:** an x86-64 computer with Docker or Podman and a supported NVIDIA,
  AMD, or Intel accelerator. Accelerator access must already work inside the
  container engine.

NVIDIA users also need
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
configured for their container engine. `nvidia-smi` confirms that the host
driver works, but does not by itself give containers access to the GPU.

Windows users can follow the Linux path from a compatible WSL2 environment.

## 1. Clone

Open a terminal and run:

```bash
git clone https://github.com/red-hat-ai-dev/vLLM-zero-to-hero-pt1.git
cd vLLM-zero-to-hero-pt1
```

## 2. Start vLLM

```bash
./run.sh
```

The launcher detects the operating system and accelerator, explains what it is
doing, and waits for the API to become ready. The first run takes longer because
it installs any required software and downloads Qwen3.5-2B. Later starts reuse
the downloaded files.

Success looks like this:

```text
vLLM is ready at http://127.0.0.1:8000/v1
```

## 3. Send a request

Keep vLLM running and use another terminal:

```bash
curl http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.5-2b",
    "messages": [
      {"role": "user", "content": "Explain containers in three sentences."}
    ]
  }'
```

The generated answer is inside `choices[0].message.content` in the JSON
response. It comes from an OpenAI-compatible API running locally on your
computer.

## Stop

```bash
./stop.sh
```

Stopping the server keeps the downloaded model so the next start is faster.
Running `./stop.sh` when the server is already stopped is safe.

## Completely remove the local setup

```bash
./cleanup.sh
```

Cleanup shows exactly what it will remove and asks for confirmation. It deletes
the vLLM Metal environment and example model on a Mac, or the project model
volume on Linux. Other Hugging Face models and container images are left alone.

The next `./run.sh` reinstalls or downloads the required files. Use
`./cleanup.sh --yes` only when you intentionally want to skip the confirmation.

## If something goes wrong

The launcher reports the likely problem and, when available, shows recent vLLM
logs. Common causes are:

- Docker or Podman is installed but not running.
- The accelerator is not available inside the container engine. On NVIDIA,
  the launcher checks this before downloading the image and links to the
  required Container Toolkit setup.
- Port 8000 is already being used by another application.
- The computer ran out of memory during model loading.
- The first download was interrupted.

Fix the reported problem and run `./run.sh` again. Failed starts are cleaned up
automatically.

## Need help?

If something is not working, [open an issue](https://github.com/red-hat-ai-dev/vLLM-zero-to-hero-pt1/issues/new)
with what you tried and the error message.

---

[Back to the vLLM Zero to Hero overview](https://github.com/red-hat-ai-dev/vLLM-zero-to-hero-overview)
