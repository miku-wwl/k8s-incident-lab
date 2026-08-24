import json
import logging
import os
import signal
import socket
import sqlite3
import sys
import threading
import time
import uuid
from contextlib import closing, contextmanager

import redis
import requests
from flask import Flask, Response, jsonify, request
from prometheus_client import Counter, Gauge, Histogram, generate_latest, start_http_server


ROLE = os.getenv("SERVICE_ROLE", "gateway")
RELEASE = os.getenv("APP_RELEASE", "1.0.0")
PORT = int(os.getenv("PORT", "8080"))

logging.basicConfig(level=logging.INFO, format="%(message)s")
LOG = logging.getLogger("lab-service")

HTTP_REQUESTS = Counter(
    "lab_http_requests_total",
    "HTTP requests handled by a lab service",
    ["service", "route", "status"],
)
HTTP_DURATION = Histogram(
    "lab_http_request_duration_seconds",
    "HTTP request duration",
    ["service", "route"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5),
)
DEPENDENCY_REQUESTS = Counter(
    "lab_dependency_requests_total",
    "Calls from one lab service to another",
    ["service", "dependency", "result"],
)
QUEUE_DEPTH = Gauge("lab_queue_depth", "Current messages waiting", ["queue"])
OLDEST_AGE = Gauge("lab_oldest_message_age_seconds", "Age of the oldest message", ["queue"])
MESSAGES_PROCESSED = Counter("lab_messages_processed_total", "Messages processed", ["worker", "result"])
STORAGE_DURATION = Histogram(
    "lab_storage_operation_duration_seconds",
    "Stateful operation duration",
    ["operation"],
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10),
)
STORAGE_ERRORS = Counter("lab_storage_errors_total", "Stateful operation errors", ["operation", "reason"])
LOAD_REQUESTS = Counter("lab_load_requests_total", "Traffic generator requests", ["target", "result"])
DNS_DURATION = Histogram(
    "lab_dns_query_duration_seconds",
    "Observed DNS query duration from synthetic runtime clients",
    ["result"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2),
)


def env_float(name, default):
    return float(os.getenv(name, str(default)))


def env_int(name, default):
    return int(os.getenv(name, str(default)))


def emit(event, **fields):
    record = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "service": ROLE,
        "release": RELEASE,
        "event": event,
        **fields,
    }
    LOG.info(json.dumps(record, separators=(",", ":"), sort_keys=True))


@contextmanager
def measured(route):
    started = time.monotonic()
    outcome = {"status": 500}
    try:
        yield outcome
    finally:
        HTTP_DURATION.labels(ROLE, route).observe(time.monotonic() - started)
        HTTP_REQUESTS.labels(ROLE, route, str(outcome["status"])).inc()


def dependency_call(name, url, timeout):
    started = time.monotonic()
    try:
        response = requests.get(url, timeout=timeout)
        response.raise_for_status()
        DEPENDENCY_REQUESTS.labels(ROLE, name, "success").inc()
        return response.json()
    except requests.RequestException as exc:
        reason = type(exc).__name__
        DEPENDENCY_REQUESTS.labels(ROLE, name, reason).inc()
        emit(
            "dependency_call_failed",
            dependency=name,
            elapsed_ms=round((time.monotonic() - started) * 1000, 1),
            error=reason,
        )
        raise


def make_http_app():
    app = Flask(__name__)
    max_inflight = env_int("MAX_INFLIGHT", 8)
    queue_wait = env_float("QUEUE_WAIT_TIMEOUT_SECONDS", 0.08)
    slots = threading.BoundedSemaphore(max_inflight)

    @app.get("/health/live")
    @app.get("/health/ready")
    def health():
        return jsonify(status="ok", service=ROLE, release=RELEASE)

    @app.get("/metrics")
    def metrics():
        if ROLE == "orders":
            update_queue_metrics(redis_client())
        return Response(generate_latest(), mimetype="text/plain; version=0.0.4")

    @app.get("/data")
    def data():
        with measured("data") as result:
            acquired = slots.acquire(timeout=queue_wait)
            if not acquired:
                result["status"] = 503
                emit("request_rejected", reason="concurrency_limit")
                return jsonify(error="temporarily unavailable"), 503
            try:
                delay = env_float("SERVICE_DELAY_SECONDS", 0.02)
                time.sleep(delay)
                shared_url = os.getenv("SHARED_URL")
                if shared_url:
                    dependency_call("identity", f"{shared_url}/data", dependency_timeout())
                result["status"] = 200
                return jsonify(service=ROLE, release=RELEASE, result="ok")
            except requests.RequestException:
                result["status"] = 503
                return jsonify(error="dependency unavailable"), 503
            finally:
                slots.release()

    @app.get("/api")
    def api():
        request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        with measured("api") as result:
            acquired = slots.acquire(timeout=queue_wait)
            if not acquired:
                result["status"] = 503
                emit("request_rejected", request_id=request_id, reason="concurrency_limit")
                return jsonify(error="temporarily unavailable", request_id=request_id), 503
            try:
                catalog = dependency_call(
                    "catalog", f"{os.environ['CATALOG_URL']}/data", dependency_timeout()
                )
                result["status"] = 200
                return jsonify(request_id=request_id, catalog=catalog)
            except (KeyError, requests.RequestException):
                result["status"] = 503
                return jsonify(error="request could not be completed", request_id=request_id), 503
            finally:
                slots.release()

    @app.post("/orders")
    def create_order():
        with measured("orders") as result:
            try:
                shared_url = os.getenv("SHARED_URL")
                if shared_url:
                    dependency_call("identity", f"{shared_url}/data", dependency_timeout())
                message = json.dumps({"id": str(uuid.uuid4()), "enqueued_at": time.time()})
                client = redis_client()
                client.rpush(queue_name(), message)
                update_queue_metrics(client)
                result["status"] = 202
                return jsonify(status="accepted"), 202
            except (redis.RedisError, requests.RequestException) as exc:
                result["status"] = 503
                emit("order_rejected", error=type(exc).__name__)
                return jsonify(error="order unavailable"), 503

    @app.post("/write")
    def write_record():
        with measured("write") as result:
            started = time.monotonic()
            try:
                with closing(sqlite_connection()) as connection:
                    connection.execute(
                        "INSERT INTO records(id, created_at, payload) VALUES (?, ?, ?)",
                        (str(uuid.uuid4()), time.time(), "x" * env_int("STORAGE_PAYLOAD_BYTES", 4096)),
                    )
                    connection.commit()
                STORAGE_DURATION.labels("write").observe(time.monotonic() - started)
                result["status"] = 201
                return jsonify(status="stored"), 201
            except sqlite3.Error as exc:
                reason = type(exc).__name__
                STORAGE_DURATION.labels("write").observe(time.monotonic() - started)
                STORAGE_ERRORS.labels("write", reason).inc()
                emit("storage_operation_failed", operation="write", error=str(exc))
                result["status"] = 503
                return jsonify(error="storage temporarily unavailable"), 503

    @app.get("/read")
    def read_records():
        with measured("read") as result:
            started = time.monotonic()
            try:
                with closing(sqlite_read_connection()) as connection:
                    row = connection.execute(
                        "SELECT COUNT(*), MAX(created_at) FROM records"
                    ).fetchone()
                STORAGE_DURATION.labels("read").observe(time.monotonic() - started)
                result["status"] = 200
                return jsonify(records=row[0], latest_created_at=row[1]), 200
            except sqlite3.Error as exc:
                reason = type(exc).__name__
                STORAGE_DURATION.labels("read").observe(time.monotonic() - started)
                STORAGE_ERRORS.labels("read", reason).inc()
                emit("storage_operation_failed", operation="read", error=str(exc))
                result["status"] = 503
                return jsonify(error="storage temporarily unavailable"), 503

    return app


def dependency_timeout():
    explicit = os.getenv("DEPENDENCY_TIMEOUT_SECONDS")
    if explicit:
        return float(explicit)
    # Release 2 adopted a tighter client timeout. It is a genuine client/dependency
    # interaction, not a response-code switch; its operational effect is visible in
    # rollout history, latency metrics and dependency timeout logs.
    return 0.03 if RELEASE.startswith("2.") else 0.5


def redis_client():
    return redis.Redis.from_url(os.getenv("REDIS_URL", "redis://redis:6379/0"), decode_responses=True)


def queue_name():
    return os.getenv("QUEUE_NAME", "orders")


def update_queue_metrics(client):
    name = queue_name()
    try:
        depth = client.llen(name)
        QUEUE_DEPTH.labels(name).set(depth)
        oldest = client.lindex(name, 0)
        age = max(0, time.time() - json.loads(oldest)["enqueued_at"]) if oldest else 0
        OLDEST_AGE.labels(name).set(age)
    except (redis.RedisError, ValueError, KeyError, TypeError):
        pass


def sqlite_path():
    return os.getenv("SQLITE_PATH", "/data/lab.db")


def sqlite_connection(timeout=None):
    connection = sqlite3.connect(
        sqlite_path(), timeout=timeout or env_float("SQLITE_TIMEOUT_SECONDS", 0.35)
    )
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=FULL")
    connection.execute(
        "CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, created_at REAL, payload TEXT)"
    )
    return connection


def sqlite_read_connection():
    path = sqlite_path()
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=0.35)
    connection.execute("PRAGMA query_only=ON")
    return connection


def run_worker():
    start_http_server(PORT)
    client = redis_client()
    process_seconds = env_float("WORK_SECONDS", 0.25)
    emit("worker_started", process_seconds=process_seconds)
    while True:
        try:
            item = client.blpop(queue_name(), timeout=2)
            update_queue_metrics(client)
            if not item:
                continue
            time.sleep(process_seconds)
            MESSAGES_PROCESSED.labels(socket.gethostname(), "success").inc()
        except redis.RedisError as exc:
            MESSAGES_PROCESSED.labels(socket.gethostname(), "error").inc()
            emit("queue_operation_failed", error=type(exc).__name__)
            time.sleep(1)


def run_load_generator():
    start_http_server(PORT)
    target = os.environ["TARGET_URL"]
    method = os.getenv("TARGET_METHOD", "GET").upper()
    concurrency = env_int("CONCURRENCY", 1)
    interval = env_float("REQUEST_INTERVAL_SECONDS", 0.25)
    timeout = env_float("REQUEST_TIMEOUT_SECONDS", 1.0)

    def loop():
        while True:
            try:
                response = requests.request(method, target, timeout=timeout)
                outcome = str(response.status_code)
            except requests.RequestException as exc:
                outcome = type(exc).__name__
            LOAD_REQUESTS.labels(target, outcome).inc()
            time.sleep(interval)

    for index in range(concurrency):
        threading.Thread(target=loop, name=f"load-{index}", daemon=True).start()
    emit("load_generator_started", target=target, method=method, concurrency=concurrency)
    signal.pause()


def run_dns_pressure():
    start_http_server(PORT)
    concurrency = env_int("CONCURRENCY", 4)
    interval = env_float("REQUEST_INTERVAL_SECONDS", 0.02)
    timeout = env_float("DNS_TIMEOUT_SECONDS", 0.25)
    suffix = os.getenv("DNS_SUFFIX", "incident-lab.svc.cluster.local")

    with open("/etc/resolv.conf", encoding="utf-8") as resolv_conf:
        nameserver = next(
            line.split()[1]
            for line in resolv_conf
            if line.strip().startswith("nameserver ")
        )

    def query_packet(hostname):
        transaction_id = os.urandom(2)
        header = transaction_id + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
        question = b"".join(bytes([len(label)]) + label.encode("ascii") for label in hostname.split("."))
        return header + question + b"\x00\x00\x01\x00\x01"

    def loop():
        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client.settimeout(timeout)
        while True:
            hostname = f"probe-{uuid.uuid4().hex}.{suffix}"
            started = time.monotonic()
            try:
                client.sendto(query_packet(hostname), (nameserver, 53))
                response, _ = client.recvfrom(512)
                outcome = f"rcode_{response[3] & 0x0f}"
            except (TimeoutError, OSError):
                outcome = "timeout"
            LOAD_REQUESTS.labels("cluster-dns", outcome).inc()
            DNS_DURATION.labels(outcome).observe(time.monotonic() - started)
            time.sleep(interval)

    for index in range(concurrency):
        threading.Thread(target=loop, name=f"dns-{index}", daemon=True).start()
    emit("dns_client_started", concurrency=concurrency)
    signal.pause()


def main():
    emit("service_starting")
    if ROLE == "worker":
        run_worker()
    elif ROLE == "loadgen":
        run_load_generator()
    elif ROLE == "dns-client":
        run_dns_pressure()
    else:
        app = make_http_app()
        from gunicorn.app.base import BaseApplication

        class Application(BaseApplication):
            def load_config(self):
                self.cfg.set("bind", f"0.0.0.0:{PORT}")
                self.cfg.set("workers", 1)
                self.cfg.set("threads", env_int("HTTP_THREADS", 16))
                self.cfg.set("accesslog", "-")
                self.cfg.set("errorlog", "-")

            def load(self):
                return app

        Application().run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
