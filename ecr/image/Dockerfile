# The publishing script supplies the digest-pinned base and model commit.
ARG VLLM_BASE_IMAGE
FROM ${VLLM_BASE_IMAGE} AS model-download
ARG MODEL_ID
ARG MODEL_REVISION
USER root
COPY download_model.py /tmp/download_model.py
RUN MODEL_ID="${MODEL_ID}" MODEL_REVISION="${MODEL_REVISION}" python3 /tmp/download_model.py

# Only the model directory crosses stages; Hub download caches stay out of the image.
FROM ${VLLM_BASE_IMAGE}
ARG MODEL_ID
ARG MODEL_REVISION
LABEL ai.huggingface.model="${MODEL_ID}" \
      ai.huggingface.revision="${MODEL_REVISION}"
COPY --from=model-download --chown=0:0 /opt/model /opt/model
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1
USER 2000:0
# Inherit the base image's `vllm serve` entrypoint.
CMD ["/opt/model"]
