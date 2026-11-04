#!/usr/bin/env python3
"""Keep this host's containers in line with apps.yaml.

Runs every two minutes from a systemd timer. For each app listing "oci" in apps.yaml it
writes an env file, a Docker Compose service and a Caddy site, then applies them. Secrets
(the Postgres password and each app's auth secret) are generated here and never leave
the host. Optional shared settings, such as GEMINI_API_KEY, go in /opt/30apps/env/shared.env.
"""

import json
import os
import re
import secrets
import subprocess
import sys
import urllib.request

import yaml

ROOT = "/opt/30apps"
ENV_DIR = os.path.join(ROOT, "env")
STATE_FILE = os.path.join(ROOT, "state.json")
COMPOSE_FILE = os.path.join(ROOT, "compose.yaml")
CADDY_FILE = os.path.join(ROOT, "Caddyfile")
SHARED_ENV = os.path.join(ENV_DIR, "shared.env")
CATALOG_URL = os.environ.get(
    "CATALOG_URL",
    "https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/apps.yaml",
)
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
COMPOSE = ["docker", "compose", "-p", "30apps", "-f", COMPOSE_FILE]


def log(msg, **fields):
    print(json.dumps({"msg": msg, **fields}), flush=True)


def run(cmd, check=True):
    result = subprocess.run(cmd, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:4])}... failed: {result.stderr.strip()[-500:]}")
    return result


def write_if_changed(path, content, mode=0o644):
    old = None
    if os.path.exists(path):
        with open(path) as f:
            old = f.read()
    if old == content:
        return False
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return True


def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {}


def public_ip(state):
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=10) as r:
            ip = r.read().decode().strip()
        if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", ip):
            state["public_ip"] = ip
    except Exception as err:  # keep the last known address
        log("public_ip.lookup_failed", error=str(err))
    return state.get("public_ip")


def fetch_catalog():
    with urllib.request.urlopen(CATALOG_URL, timeout=20) as r:
        data = yaml.safe_load(r.read()) or {}
    apps = []
    for a in data.get("apps", []):
        if "oci" not in (a.get("clouds") or []):
            continue
        name, tag = str(a.get("name", "")), str(a.get("tag", ""))
        if not NAME_RE.match(name) or not TAG_RE.match(tag) or "PENDING" in tag:
            log("app.skipped", name=name, reason="invalid name or tag not published yet")
            continue
        apps.append(a)
    return apps


def main():
    os.makedirs(ENV_DIR, mode=0o700, exist_ok=True)
    state = load_state()
    state.setdefault("pg_password", secrets.token_urlsafe(24))
    state.setdefault("ports", {})
    state.setdefault("auth", {})

    apps = fetch_catalog()
    ip = public_ip(state)
    if not ip:
        log("abort", reason="no public IP yet")
        return 1

    services = {
        "postgres": {
            "image": "pgvector/pgvector:pg17",
            "restart": "unless-stopped",
            "environment": {"POSTGRES_PASSWORD": state["pg_password"]},
            "command": ["postgres", "-c", "max_connections=100"],
            "volumes": [f"{ROOT}/pgdata:/var/lib/postgresql/data"],
            "healthcheck": {
                "test": ["CMD-SHELL", "pg_isready -U postgres"],
                "interval": "5s",
                "retries": 20,
            },
        },
        "caddy": {
            "image": "caddy:2",
            "restart": "unless-stopped",
            "network_mode": "host",
            "volumes": [f"{CADDY_FILE}:/etc/caddy/Caddyfile:ro", "caddy_data:/data", "caddy_config:/config"],
        },
    }
    sites = ["{\n\temail dev@breakthruventures.ai\n}\n"]
    used_ports = set(state["ports"].values())

    for a in apps:
        name = a["name"]
        if name not in state["ports"]:
            port = 3101
            while port in used_ports:
                port += 1
            state["ports"][name] = port
            used_ports.add(port)
        port = state["ports"][name]
        state["auth"].setdefault(name, secrets.token_urlsafe(36))

        default_host = f"{name}.{ip.replace('.', '-')}.sslip.io"
        domain = a.get("domain")
        hosts = [domain, default_host] if domain else [default_host]
        db = name.replace("-", "_")
        env = {
            "DATABASE_URL": f"postgres://postgres:{state['pg_password']}@postgres:5432/{db}",
            "BETTER_AUTH_SECRET": state["auth"][name],
            "APP_URL": f"https://{hosts[0]}",
            "APP_NAME": str(a.get("title", name)),
            "APP_VERSION": str(a["tag"]),
            "CLOUD": "oci",
            "MIGRATE_ON_START": "true",
            "AI_PROVIDER": str(a.get("ai", "demo")),
            "DB_POOL_MAX": "5",
        }
        env_path = os.path.join(ENV_DIR, f"{name}.env")
        write_if_changed(env_path, "".join(f"{k}={v}\n" for k, v in env.items()), 0o600)

        env_files = [env_path] + ([SHARED_ENV] if os.path.exists(SHARED_ENV) else [])
        services[f"app-{name}"] = {
            "image": f"{a['image']}:{a['tag']}",
            "restart": "unless-stopped",
            "env_file": env_files,
            "ports": [f"127.0.0.1:{port}:3000"],
            "depends_on": {"postgres": {"condition": "service_healthy"}},
        }
        sites.append(f"{', '.join(hosts)} {{\n\treverse_proxy 127.0.0.1:{port}\n}}\n")

    compose = {"services": services, "volumes": {"caddy_data": {}, "caddy_config": {}}}
    # JSON is valid YAML, and it can't be mis-indented.
    compose_changed = write_if_changed(COMPOSE_FILE, json.dumps(compose, indent=2) + "\n", 0o600)
    caddy_changed = write_if_changed(CADDY_FILE, "\n".join(sites))
    write_if_changed(STATE_FILE, json.dumps(state, indent=2), 0o600)

    run(COMPOSE + ["up", "-d", "--remove-orphans", "--wait", "postgres"])

    created = []
    for a in apps:
        db = a["name"].replace("-", "_")
        exists = run(COMPOSE + ["exec", "-T", "postgres", "psql", "-U", "postgres", "-tAc",
                                f"select 1 from pg_database where datname='{db}'"]).stdout.strip()
        if exists != "1":
            run(COMPOSE + ["exec", "-T", "postgres", "createdb", "-U", "postgres", db])
            created.append(a["name"])
            log("database.created", name=db)

    run(COMPOSE + ["up", "-d", "--remove-orphans"])
    for name in created:  # a fresh database: restart so the app migrates into it
        run(COMPOSE + ["restart", f"app-{name}"])
    if caddy_changed and not compose_changed:
        run(COMPOSE + ["exec", "-T", "caddy", "caddy", "reload", "--config", "/etc/caddy/Caddyfile"], check=False)

    log("synced", apps=[a["name"] for a in apps], ip=ip, compose_changed=compose_changed, caddy_changed=caddy_changed)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:
        log("sync.failed", error=str(err))
        sys.exit(1)
