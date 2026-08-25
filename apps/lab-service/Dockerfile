FROM python:3.13.7-slim@sha256:5f55cdf0c5d9dc1a415637a5ccc4a9e18663ad203673173b8cda8f8dcacef689

ARG APP_RELEASE=1.0.0
ENV APP_RELEASE=${APP_RELEASE} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./

RUN useradd --uid 10001 --create-home appuser \
    && mkdir -p /data \
    && chown -R appuser:appuser /app /data

USER 10001
EXPOSE 8080

CMD ["python", "/app/app.py"]
