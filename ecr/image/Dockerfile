# Engine only: model weights are published separately to S3.
ARG VLLM_BASE_IMAGE
FROM ${VLLM_BASE_IMAGE}
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1
USER 2000:0
# Inherit the upstream `vllm serve` entrypoint.
CMD ["/models/model"]
