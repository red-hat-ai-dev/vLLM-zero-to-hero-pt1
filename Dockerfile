# syntax=docker/dockerfile:1
ARG VLLM_IMAGE=docker.io/vllm/vllm-openai:v0.28.0
FROM ${VLLM_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/red-hat-ai-dev/vLLM-zero-to-hero" \
      org.opencontainers.image.description="A ready-to-run vLLM API server"

EXPOSE 8000
ENTRYPOINT ["vllm", "serve"]
CMD ["RedHatAI/Qwen3.5-2B", "--host", "0.0.0.0", "--port", "8000", "--served-model-name", "qwen3.5-2b", "--max-model-len", "8192"]
