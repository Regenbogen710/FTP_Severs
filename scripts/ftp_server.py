import os
import sys
import codecs
import locale

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import ThreadedFTPServer


def parse_bool(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def parse_passive_ports(value: str):
    value = (value or "").strip()
    if not value:
        return None
    if "-" in value:
        start, end = value.split("-", 1)
        return range(int(start), int(end) + 1)
    return [int(part.strip()) for part in value.split(",") if part.strip()]


def resolve_encoding(value: str) -> str:
    encoding = (value or "system").strip()
    if encoding.lower() in {"system", "default", "auto"}:
        encoding = locale.getpreferredencoding(False) or sys.getfilesystemencoding() or "utf-8"
    return codecs.lookup(encoding).name


def main() -> int:
    root = os.environ.get("FTP_ROOT", "").strip()
    host = os.environ.get("FTP_HOST", "127.0.0.1").strip()
    port = int(os.environ.get("FTP_PORT", "21"))
    permissions = os.environ.get("FTP_PERMISSIONS", "elr").strip()
    allow_anonymous = parse_bool(os.environ.get("FTP_ALLOW_ANONYMOUS", "true"))
    username = os.environ.get("FTP_USERNAME", "ftp")
    password = os.environ.get("FTP_PASSWORD", "change-me-before-use")
    passive_ports = parse_passive_ports(os.environ.get("FTP_PASSIVE_PORTS", "60000-60050"))
    encoding = resolve_encoding(os.environ.get("FTP_ENCODING", "system"))

    if not root:
        print("FTP_ROOT is empty.", file=sys.stderr)
        return 2

    root = os.path.abspath(root)
    os.makedirs(root, exist_ok=True)

    authorizer = DummyAuthorizer()
    if allow_anonymous:
        authorizer.add_anonymous(root, perm=permissions)
        login_text = "anonymous"
    else:
        authorizer.add_user(username, password, root, perm=permissions)
        login_text = username

    handler = FTPHandler
    handler.authorizer = authorizer
    handler.banner = "Lab FTP server ready."
    handler.encoding = encoding
    if passive_ports:
        handler.passive_ports = passive_ports

    server = ThreadedFTPServer((host, port), handler)
    server.max_cons = 64
    server.max_cons_per_ip = 16

    print(f"FTP root: {root}", flush=True)
    print(f"Listen: ftp://{host}:{port}", flush=True)
    print(f"Login: {login_text}", flush=True)
    print(f"Permissions: {permissions}", flush=True)
    print(f"Encoding: {encoding}", flush=True)
    print(f"Passive ports: {os.environ.get('FTP_PASSIVE_PORTS', '')}", flush=True)

    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
