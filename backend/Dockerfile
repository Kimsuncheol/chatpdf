FROM python:3.14.8-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    OMP_NUM_THREADS=1 \
    TOKENIZERS_PARALLELISM=false

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 libgomp1 tesseract-ocr tesseract-ocr-eng \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt ./
# CPU wheels avoid pulling CUDA dependencies into this CPU-only deployment.
RUN python -m pip install --index-url https://download.pytorch.org/whl/cpu \
      torch==2.14.1 torchvision==0.29.1 \
    && python -m pip install -r requirements.txt \
    && python -m pip check

COPY chatpdf ./chatpdf
# Provision parser artifacts in the image, never with the runtime signing secret.
RUN docling-tools models download layout tableformer --output-dir /opt/docling-models

RUN python -m chatpdf.e5_local download /opt/e5-model

ENV E5_MODEL_PATH=/opt/e5-model
ENV DOCLING_ARTIFACTS_PATH=/opt/docling-models
EXPOSE 10000
CMD ["python", "-m", "chatpdf.serve"]
