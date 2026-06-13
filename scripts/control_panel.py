import argparse
import codecs
import ctypes
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import socket
import subprocess
import sys
import time
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


if getattr(sys, "frozen", False):
    BASE_DIR = Path(sys.executable).resolve().parent.parent
else:
    BASE_DIR = Path(__file__).resolve().parent.parent
SCRIPT_DIR = BASE_DIR / "scripts"
WEB_DIR = BASE_DIR / "webui"
CONFIG_CANDIDATES = [
    BASE_DIR / "config.ini",
    BASE_DIR / "config" / "ftp_config.ini",
    BASE_DIR / "ftp_config.ini",
]
CONFIG_PATH = next((path for path in CONFIG_CANDIDATES if path.exists()), CONFIG_CANDIDATES[0])
RUNTIME_DIR = BASE_DIR / ".ftp_runtime"

CONFIG_KEYS = [
    "FTP_ROOT",
    "HOST",
    "PORT",
    "PERMISSION",
    "CUSTOM_PERMISSIONS",
    "DANGEROUS_ALLOW_ANONYMOUS_DELETE",
    "ALLOW_ANONYMOUS",
    "USERNAME",
    "PASSWORD",
    "PASSIVE_PORTS",
    "FTP_ENCODING",
    "WATCHDOG_INTERVAL_SECONDS",
    "AUTO_INSTALL_PYFTPDLIB",
    "PYFTPDLIB_PACKAGE",
    "ENABLE_FRONTEND",
]

DEFAULT_CONFIG = {
    "FTP_ROOT": "ftp-root",
    "HOST": "192.168.110.107",
    "PORT": "21",
    "PERMISSION": "readonly",
    "CUSTOM_PERMISSIONS": "",
    "DANGEROUS_ALLOW_ANONYMOUS_DELETE": "false",
    "ALLOW_ANONYMOUS": "true",
    "USERNAME": "ftp",
    "PASSWORD": "change-me-before-use",
    "PASSIVE_PORTS": "60000-60050",
    "FTP_ENCODING": "system",
    "WATCHDOG_INTERVAL_SECONDS": "5",
    "AUTO_INSTALL_PYFTPDLIB": "false",
    "PYFTPDLIB_PACKAGE": "pyftpdlib",
    "ENABLE_FRONTEND": "false",
}

BOOL_KEYS = {
    "DANGEROUS_ALLOW_ANONYMOUS_DELETE",
    "ALLOW_ANONYMOUS",
    "AUTO_INSTALL_PYFTPDLIB",
    "ENABLE_FRONTEND",
}

REQUEST_LOG = {}
CSRF_TOKEN = secrets.token_urlsafe(32)


def parse_bool(value):
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def read_config():
    config = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        for line in CONFIG_PATH.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith(";"):
                continue
            key, sep, value = stripped.partition("=")
            if sep and key.strip() in CONFIG_KEYS:
                config[key.strip()] = value.strip()
    return config


def write_config(config):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    text = f"""# FTP server config
#
# FTP_ROOT can be absolute, or relative to this folder.
# FTP_ROOT must not be placed on the Windows system drive.
# Examples:
# FTP_ROOT=ftp-root
# FTP_ROOT=D:\\FTPShare
FTP_ROOT={config["FTP_ROOT"]}

# Listen address and port.
# Bind to the lab FTP IP by default.
# Use HOST=0.0.0.0 only when you really want all network interfaces.
HOST={config["HOST"]}
PORT={config["PORT"]}

# Permission mode:
# readonly  = list/read only
# upload    = list/upload only, no download/delete
# readwrite = read/write/rename/mkdir, no delete
# full      = all common FTP file permissions
# custom    = use CUSTOM_PERMISSIONS directly
PERMISSION={config["PERMISSION"]}
CUSTOM_PERMISSIONS={config["CUSTOM_PERMISSIONS"]}

# Anonymous delete is blocked by default even when PERMISSION=full/custom includes d.
# Set this to true only for short, supervised maintenance windows.
DANGEROUS_ALLOW_ANONYMOUS_DELETE={config["DANGEROUS_ALLOW_ANONYMOUS_DELETE"]}

# Anonymous access is convenient for lab LAN usage.
# If false, USERNAME and PASSWORD are required.
ALLOW_ANONYMOUS={config["ALLOW_ANONYMOUS"]}
USERNAME={config["USERNAME"]}
PASSWORD={config["PASSWORD"]}

# Passive FTP ports. Open these in firewall if needed.
PASSIVE_PORTS={config["PASSIVE_PORTS"]}

# FTP command/path encoding.
# system = follow the OS preferred encoding.
# Common values: system, utf-8, gbk, gb2312, big5, cp936
FTP_ENCODING={config["FTP_ENCODING"]}

# Watchdog behavior.
WATCHDOG_INTERVAL_SECONDS={config["WATCHDOG_INTERVAL_SECONDS"]}
AUTO_INSTALL_PYFTPDLIB={config["AUTO_INSTALL_PYFTPDLIB"]}
PYFTPDLIB_PACKAGE={config["PYFTPDLIB_PACKAGE"]}

# Local web control panel.
# When false, start_control_panel.bat will not open the frontend.
ENABLE_FRONTEND={config["ENABLE_FRONTEND"]}
"""
    CONFIG_PATH.write_text(text, encoding="utf-8")


def reject_newline(name, value):
    if "\r" in value or "\n" in value:
        raise ValueError(f"{name} cannot contain newlines.")


def resolve_root(path_value):
    root = Path(path_value)
    if not root.is_absolute():
        root = BASE_DIR / root
    return root.resolve()


def assert_safe_root(path_value):
    root = resolve_root(path_value)
    anchor = root.anchor
    if str(root).rstrip("\\/").upper() == anchor.rstrip("\\/").upper():
        raise ValueError("FTP_ROOT cannot be a drive root.")

    if sys.platform.startswith("win"):
        system_root = os.environ.get("SystemRoot") or os.environ.get("windir") or r"C:\Windows"
        system_drive = Path(system_root).drive.upper()
        if root.drive.upper() == system_drive:
            raise ValueError("FTP_ROOT cannot be placed on the Windows system drive.")

        blocked = [
            Path(system_root).resolve(),
            Path(os.environ.get("USERPROFILE", "")).resolve() if os.environ.get("USERPROFILE") else None,
        ]
        for blocked_path in blocked:
            if blocked_path and root == blocked_path:
                raise ValueError("FTP_ROOT cannot be a sensitive system folder.")
    return str(root)


def validate_host(value):
    reject_newline("HOST", value)
    if value == "localhost":
        return value
    try:
        ipaddress.ip_address(value)
    except ValueError as exc:
        raise ValueError("HOST must be an IP address or localhost.") from exc
    return value


def validate_port(name, value, minimum=1):
    reject_newline(name, value)
    try:
        port = int(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number.") from exc
    if port < minimum or port > 65535:
        raise ValueError(f"{name} must be between {minimum} and 65535.")
    return str(port)


def validate_passive_ports(value):
    reject_newline("PASSIVE_PORTS", value)
    if not value:
        return ""
    if "-" in value:
        start_text, end_text = value.split("-", 1)
        start = int(validate_port("PASSIVE_PORTS", start_text.strip(), 1024))
        end = int(validate_port("PASSIVE_PORTS", end_text.strip(), 1024))
        if start > end:
            raise ValueError("PASSIVE_PORTS range start must be less than or equal to end.")
        if end - start > 500:
            raise ValueError("PASSIVE_PORTS range is too large.")
        return f"{start}-{end}"

    ports = []
    for item in value.split(","):
        item = item.strip()
        if item:
            ports.append(validate_port("PASSIVE_PORTS", item, 1024))
    if len(ports) > 100:
        raise ValueError("PASSIVE_PORTS contains too many ports.")
    return ",".join(ports)


def validate_encoding(value):
    reject_newline("FTP_ENCODING", value)
    encoding = (value or "system").strip().lower()
    if not re.fullmatch(r"[a-z0-9._-]{1,32}", encoding):
        raise ValueError("FTP_ENCODING contains unsupported characters.")
    if encoding in {"system", "default", "auto"}:
        return "system"
    try:
        codecs.lookup(encoding)
    except LookupError as exc:
        raise ValueError("FTP_ENCODING is not a supported Python codec.") from exc
    return encoding


def validate_config(input_config, existing_config=None):
    existing = dict(DEFAULT_CONFIG)
    if existing_config:
        existing.update(existing_config)

    config = dict(existing)
    for key, value in input_config.items():
        if key not in CONFIG_KEYS:
            continue
        if value is None:
            value = ""
        value = str(value).strip()
        reject_newline(key, value)
        if key == "PASSWORD" and value == "":
            continue
        config[key] = value

    assert_safe_root(config["FTP_ROOT"])
    config["HOST"] = validate_host(config["HOST"])
    config["PORT"] = validate_port("PORT", config["PORT"])

    permission = config["PERMISSION"].lower()
    if permission not in {"readonly", "upload", "readwrite", "full", "custom"}:
        raise ValueError("PERMISSION must be readonly, upload, readwrite, full, or custom.")
    config["PERMISSION"] = permission

    allowed_permissions = set("elradfmwMT")
    if any(char not in allowed_permissions for char in config["CUSTOM_PERMISSIONS"]):
        raise ValueError("CUSTOM_PERMISSIONS contains unsupported permission characters.")
    if permission == "custom" and not config["CUSTOM_PERMISSIONS"]:
        raise ValueError("CUSTOM_PERMISSIONS is required when PERMISSION=custom.")

    for key in BOOL_KEYS:
        config[key] = "true" if parse_bool(config[key]) else "false"

    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", config["USERNAME"]):
        raise ValueError("USERNAME may only contain letters, numbers, dot, underscore, or hyphen.")

    if len(config["PASSWORD"]) > 128:
        raise ValueError("PASSWORD is too long.")
    if config["ALLOW_ANONYMOUS"] != "true" and config["PASSWORD"] in {"", "ftp", "change-me-before-use"}:
        raise ValueError("Non-anonymous mode requires a non-default password.")

    config["PASSIVE_PORTS"] = validate_passive_ports(config["PASSIVE_PORTS"])
    config["FTP_ENCODING"] = validate_encoding(config["FTP_ENCODING"])

    interval = int(validate_port("WATCHDOG_INTERVAL_SECONDS", config["WATCHDOG_INTERVAL_SECONDS"]))
    if interval > 3600:
        raise ValueError("WATCHDOG_INTERVAL_SECONDS must be 3600 or less.")
    config["WATCHDOG_INTERVAL_SECONDS"] = str(interval)

    if not re.fullmatch(r"[A-Za-z0-9_.-]+([=<>!~]{1,2}[A-Za-z0-9_.-]+)?", config["PYFTPDLIB_PACKAGE"]):
        raise ValueError("PYFTPDLIB_PACKAGE must be a simple package name or pinned version.")

    return config


def config_for_client(config):
    safe = {key: config.get(key, "") for key in CONFIG_KEYS if key != "PASSWORD"}
    safe["PASSWORD_SET"] = "true" if config.get("PASSWORD") else "false"
    return safe


def process_alive(pid):
    if not pid:
        return False
    if sys.platform.startswith("win"):
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))
        if not handle:
            return False
        try:
            exit_code = wintypes.DWORD()
            ok = ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
            return bool(ok) and exit_code.value == 259
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def process_text(pid):
    if not pid or not sys.platform.startswith("win"):
        return ""
    ps = (
        "$p=Get-CimInstance Win32_Process -Filter 'ProcessId = "
        f"{int(pid)}' -ErrorAction SilentlyContinue; "
        "if ($p) { ($p.CommandLine + ' ' + $p.ExecutablePath) }"
    )
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps],
            cwd=str(BASE_DIR),
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return (result.stdout or "").strip().lower()


def process_matches(pid, expected_tokens):
    if not process_alive(pid):
        return False
    text = process_text(pid)
    if not text:
        return True
    return str(BASE_DIR).lower() in text and any(token.lower() in text for token in expected_tokens)


def read_pid(name):
    path = RUNTIME_DIR / name
    if not path.exists():
        return None
    try:
        return int(path.read_text(encoding="ascii").strip().splitlines()[0])
    except (OSError, ValueError, IndexError):
        return None


def port_open(host, port):
    probe_host = "127.0.0.1" if host in {"0.0.0.0", "::", "192.168.110.107"} else host
    try:
        with socket.create_connection((probe_host, int(port)), timeout=0.4):
            return True
    except OSError:
        return False


def get_status():
    config = read_config()
    ftp_pid = read_pid("ftp_server.pid")
    watchdog_a = read_pid("watchdog-A.pid")
    watchdog_b = read_pid("watchdog-B.pid")
    ftp_running = process_matches(ftp_pid, ("ftp_server.py", "ftp_server.exe"))
    port_reachable = port_open(config["HOST"], config["PORT"])
    watchdog_a_alive = process_matches(watchdog_a, ("ftp_watchdog.ps1",))
    watchdog_b_alive = process_matches(watchdog_b, ("ftp_watchdog.ps1",))
    watchdogs = [
        f"A:running(pid={watchdog_a})" if watchdog_a_alive else "A:stopped",
        f"B:running(pid={watchdog_b})" if watchdog_b_alive else "B:stopped",
    ]
    return {
        "ftpRunning": ftp_running or port_reachable,
        "ftpPid": ftp_pid,
        "ftpUrl": f'ftp://{config["HOST"]}:{config["PORT"]}',
        "ftpRoot": str(resolve_root(config["FTP_ROOT"])),
        "permission": config["PERMISSION"],
        "watchdogs": " / ".join(watchdogs),
    }


def creation_flags():
    if sys.platform.startswith("win"):
        return getattr(subprocess, "CREATE_NO_WINDOW", 0)
    return 0


def start_watchdog(name):
    cmd = [
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-WindowStyle",
        "Hidden",
        "-File",
        str(SCRIPT_DIR / "ftp_watchdog.ps1"),
        "-WatchdogName",
        name,
    ]
    subprocess.Popen(cmd, cwd=str(BASE_DIR), creationflags=creation_flags())


def start_ftp():
    validate_config(read_config())
    RUNTIME_DIR.mkdir(exist_ok=True)
    for marker_name in ("shutdown.request", "ftp_server.started"):
        marker_path = RUNTIME_DIR / marker_name
        try:
            marker_path.unlink()
        except FileNotFoundError:
            pass
    start_watchdog("A")
    start_watchdog("B")


def stop_ftp():
    cmd = [
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(SCRIPT_DIR / "stop_ftp_server.ps1"),
    ]
    subprocess.run(cmd, cwd=str(BASE_DIR), check=False, capture_output=True, text=True)


def rate_limited(client_ip):
    now = time.time()
    window_start = now - 60
    hits = [item for item in REQUEST_LOG.get(client_ip, []) if item > window_start]
    REQUEST_LOG[client_ip] = hits
    if len(hits) >= 60:
        return True
    hits.append(now)
    return False


class ControlPanelHandler(BaseHTTPRequestHandler):
    server_version = "FTPControlPanel/1.0"

    def log_message(self, format_text, *args):
        return

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; "
            "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        )
        super().end_headers()

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status, message):
        self.send_json(status, {"error": message})

    def local_request(self):
        host = self.headers.get("Host", "")
        allowed = host.startswith("127.0.0.1:") or host.startswith("localhost:") or host.startswith("[::1]:")
        origin = self.headers.get("Origin")
        if origin:
            parsed = urlparse(origin)
            allowed_origin = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
            return allowed and allowed_origin
        return allowed

    def validate_state_request(self):
        if not self.local_request():
            self.send_error_json(403, "Control panel accepts local requests only.")
            return False
        if rate_limited(self.client_address[0]):
            self.send_error_json(429, "Too many requests.")
            return False
        token = self.headers.get("X-CSRF-Token", "")
        if not secrets.compare_digest(token, CSRF_TOKEN):
            self.send_error_json(403, "Invalid CSRF token.")
            return False
        return True

    def read_json_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 32768:
            raise ValueError("Request body is too large.")
        raw = self.rfile.read(length)
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/api/session":
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Set-Cookie", "ftp_panel=1; SameSite=Strict; Path=/")
                body = json.dumps({"csrfToken": CSRF_TOKEN}).encode("utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/api/config":
                self.send_json(200, {"config": config_for_client(read_config())})
                return
            if path == "/api/status":
                self.send_json(200, {"status": get_status()})
                return
            self.serve_static(path)
        except Exception:
            self.send_error_json(500, "Internal server error.")

    def do_POST(self):
        path = urlparse(self.path).path
        if not self.validate_state_request():
            return
        try:
            if path == "/api/config":
                payload = self.read_json_body()
                current = read_config()
                config = validate_config(payload, current)
                write_config(config)
                self.send_json(200, {"config": config_for_client(config)})
                return
            if path == "/api/start":
                start_ftp()
                self.send_json(200, {"ok": True})
                return
            if path == "/api/stop":
                stop_ftp()
                self.send_json(200, {"ok": True})
                return
            self.send_error_json(404, "Not found.")
        except ValueError as exc:
            self.send_error_json(400, str(exc))
        except Exception:
            self.send_error_json(500, "Internal server error.")

    def serve_static(self, path):
        if path == "/":
            path = "/index.html"
        rel = path.lstrip("/")
        target = (WEB_DIR / rel).resolve()
        web_root = WEB_DIR.resolve()
        try:
            target.relative_to(web_root)
        except ValueError:
            self.send_error_json(404, "Not found.")
            return
        if not target.is_file():
            self.send_error_json(404, "Not found.")
            return
        content = target.read_bytes()
        mime, _ = mimetypes.guess_type(str(target))
        self.send_response(200)
        self.send_header("Content-Type", mime or "application/octet-stream")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


def main():
    parser = argparse.ArgumentParser(description="FTP control panel")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8088)
    args = parser.parse_args()

    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("Control panel must bind to localhost only.")

    if not parse_bool(read_config().get("ENABLE_FRONTEND", "false")):
        print("Control panel disabled by ENABLE_FRONTEND=false in config.ini.", flush=True)
        return

    RUNTIME_DIR.mkdir(exist_ok=True)
    (RUNTIME_DIR / "control_panel.pid").write_text(str(os.getpid()), encoding="ascii")

    server = ThreadingHTTPServer((args.host, args.port), ControlPanelHandler)
    print(f"FTP control panel: http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            (RUNTIME_DIR / "control_panel.pid").unlink()
        except OSError:
            pass


if __name__ == "__main__":
    main()
