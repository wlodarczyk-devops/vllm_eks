#!/usr/bin/env python3
"""Exercise the gateway in a disposable Docker container; requires Docker/OpenSSL.

No AWS or Kubernetes access. A closed loopback upstream makes valid authenticated
requests return 502, distinguishing auth success from an accidental open proxy.
"""
import base64
import http.client
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "nginxinc/nginx-unprivileged@sha256:7377697a821c131a924a7105fafbe7414db4e9fcc77a6f08f776f33f141ec3f8"


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def main():
    name = "llm-gateway-test-" + uuid.uuid4().hex[:10]
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        directory.chmod(0o755)  # Container UID 101 must traverse the bind mount.
        # Test-only credentials and certificate, generated per execution.
        password = uuid.uuid4().hex
        hashed = run("openssl", "passwd", "-6", "-stdin", input=password)
        (directory / "htpasswd").write_text(f"review:{hashed}\n")
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", str(directory / "tls.key"), "-out", str(directory / "tls.crt"), stderr=subprocess.DEVNULL)
        for file in directory.iterdir():
            file.chmod(0o644)  # Disposable test material, readable by container UID 101.
        config = (ROOT / "vllm/templates/gateway.conf.tftpl").read_text()
        config = config.replace("${dns_resolver}", "127.0.0.1").replace("${upstream}", "127.0.0.1:9")
        config = config.replace("/etc/gateway-tls/", "/test/").replace("/etc/gateway-auth/", "/test/")
        (directory / "nginx.conf").write_text(config)
        try:
            run("docker", "run", "--detach", "--name", name, "--read-only",
                "--cap-drop=ALL", "--security-opt=no-new-privileges", "--user", "101:101",
                "--tmpfs", "/tmp:rw,noexec,nosuid,size=128m,uid=101,gid=101",
                "--publish", "127.0.0.1::8443", "--volume", f"{directory}:/test:ro",
                "--entrypoint", "nginx", IMAGE, "-c", "/test/nginx.conf", "-g", "daemon off;")
            port = int(run("docker", "port", name, "8443/tcp").rsplit(":", 1)[1])
            context = ssl.create_default_context(cafile=str(directory / "tls.crt"))

            def request(path, auth=None, method="GET", body=None):
                connection = http.client.HTTPSConnection("localhost", port, context=context, timeout=5)
                headers = {} if auth is None else {"Authorization": "Basic " + base64.b64encode(auth.encode()).decode()}
                try:
                    connection.request(method, path, body=body, headers=headers)
                    response = connection.getresponse()
                    response.read()
                    return response.status
                finally:
                    connection.close()

            for attempt in range(30):
                try:
                    assert request("/v1/models") == 401
                    break
                except (ConnectionError, socket.timeout):
                    time.sleep(0.2)
            else:
                raise RuntimeError("Gateway did not become reachable")
            assert request("/v1/models", "review:wrong") == 401
            valid = f"review:{password}"
            assert request("/v1/models", valid) == 502  # Auth accepted, closed upstream.
            for path in ("/pause", "/metrics", "/invocations", "/v1/load_lora_adapter"):
                assert request(path, valid) == 404, path
            assert request("/v1/models", valid, method="POST") == 403
            assert request("/v1/chat/completions", valid, method="POST", body=b"x" * (1024 * 1024 + 1)) == 413
            statuses = [request("/v1/models", valid) for _ in range(40)]
            assert 429 in statuses, "Burst traffic should be rate-limited"
            print("Gateway checks passed: TLS, authentication, route/method/body restrictions and rate limiting")
        finally:
            subprocess.run(["docker", "rm", "--force", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


if __name__ == "__main__":
    main()
