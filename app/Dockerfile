FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends iputils-ping curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]

# Create a non-root user for runtime and ensure /app is owned by it
RUN groupadd -g 1000 appuser || true \
    && useradd -m -u 1000 -g appuser -s /bin/bash appuser || true \
    && chown -R appuser:appuser /app

USER appuser
