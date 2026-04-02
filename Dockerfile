# ── Stage 1: Builder ──────────────────────────────────────────
# Install dependencies in a separate stage so final image stays slim
FROM python:3.12-slim AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy and install Python dependencies
COPY app/requirements.txt .
RUN pip install --upgrade pip && \
    pip install --prefix=/install --no-cache-dir -r requirements.txt


# ── Stage 2: Runtime ──────────────────────────────────────────
# Clean slim image — only what's needed to run
FROM python:3.12-slim AS runtime

WORKDIR /app

# Install only runtime system dependency (libpq for psycopg2)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Copy installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy application code
COPY app/app.py .
COPY app/models.py .

# Security best practice — run as non-root user
RUN groupadd -r flaskuser && useradd -r -g flaskuser flaskuser
RUN chown -R flaskuser:flaskuser /app
USER flaskuser

# Expose port
EXPOSE 5000

# Health check built into image
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health/live')"

# Run with gunicorn — production WSGI server, never use flask dev server in prod
#CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", \
#     "--timeout", "60", "--access-logfile", "-", "--error-logfile", "-", \
#     "--log-level", "info", "app:app"]


CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:5000", "app:create_app()"]
