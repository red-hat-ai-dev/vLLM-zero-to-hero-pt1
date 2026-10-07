# Tested support: Part 1

This is a tutorial validation record, not a vendor support guarantee. Status is
specific to the versions and models below. Last reviewed: 2026-10-07.

## Platform and image record

| Path | Configuration | Evidence |
| --- | --- | --- |
| Linux / NVIDIA | vLLM 0.28.0, `RedHatAI/Qwen3.5-2B`, Dockerfile built locally | Fresh local image build, readiness, chat/completions, and stop passed on RTX 3090 / Podman 5.4.2 / driver 610.43.02 |
| Apple Silicon | Apple M4 Pro 48 GiB, vLLM Metal 0.29.0, MLX 0.32.1, `mlx-community/Qwen3.5-2B-4bit` | Fresh readiness, greedy/sampled chat, completions, and stop passed 2026-10-07 |
| AMD / Intel | vLLM 0.28.0 ROCm / XPU images | Historical image builds succeeded; inference with this exact model is unverified |

The [Metal hardware record](validation/2026-10-07-metal.json) records installed
versions, the model revision, request scope, and the corrected test harness run.
These short requests establish serving functionality, not a performance result.

The launcher and publisher both use the public legacy package
`ghcr.io/red-hat-ai-dev/vllm-zero-to-hero`, even though this source repository is
named `vLLM-zero-to-hero-pt1`. The Dockerfile's source label points here.
`IMAGE_REPO` can select a local test build; `PORT` selects the host API port.

The existing public tags were built from an older commit and default to
`Qwen/Qwen3.5-2B`. The current Dockerfile defaults to `RedHatAI/Qwen3.5-2B`.
After an authorized release, verify anonymous pulls of all three tags and check
the resulting image configuration, digest, source revision, and actual inference.
A local build does not prove that GHCR publication or package permissions work.

## Lifecycle behavior

Stop and cleanup discover which engine owns the tutorial resources. If resources
exist in both engines, or an engine is unavailable, they fail with instructions
to set `ENGINE`. They refuse to remove an unlabeled container. Parts 1 and 3
intentionally share their container name, volume, and Metal state; stop one
before starting the other. Cleanup keeps the shared Metal Python environment.

See the [sanitized hardware record](validation/2026-10-07.json) for model revisions,
image identity, and request scope.

## Reproduce the checks

Run `python3 -m unittest discover -s tests -v` for the committed regression and
documentation checks. The pull-request workflow runs these on Linux and macOS
with Python 3.10 and 3.13. These tests use fake engines; they do not establish GPU
support. Successful CI, a successful image build, and successful inference are
separate kinds of evidence.

For a hardware result, record the commit, date, OS/architecture, GPU and driver,
engine/version, image digest or Python packages, exact model revision, command,
request payload, response, and logs. For speculative decoding include accepted
and drafted token counters. Record failed steps too. Do not include credentials
or model weights in an issue or PR.

## Remaining validation

AMD ROCm, Intel XPU, and WSL2 have not been exercised by this change. Do not infer
support for the tutorial's exact model and quantization from an upstream backend
support table. Maintainers should attach equivalent hardware evidence before
marking those paths tested. No image publication or GPU CI is performed by the
pull-request checks.
