#!/usr/bin/env python3
"""ProxyCommand helper: tunnel SSH through the runtime egress proxy (-> Tailscale).
Usage: proxy-ssh-helper.py <host> <port>
Reads proxy host/port/credentials from HTTPS_PROXY env (never from argv)."""
import os, socket, base64, sys
from urllib.parse import urlparse

ENV_FILE = os.environ.get("PROXY_ENV_FILE", os.path.expanduser("~/.config/vps-ssh-proxy-env"))

def proxy_url():
    v = os.environ.get("HTTPS_PROXY")
    if not v:
        # Fallback: read the systemd EnvironmentFile directly. The keepalive
        # step-0 sometimes rewrites it as a BARE URL (no VAR= prefix), which
        # systemd then ignores -> HTTPS_PROXY missing -> crash loop. Handle
        # both formats so the persistent tunnel survives either.
        try:
            with open(ENV_FILE) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("HTTPS_PROXY="):
                        v = line.split("=", 1)[1].strip().strip('"').strip("'")
                        break
                    elif line and not line.startswith("#") and "://" in line:
                        v = line
        except OSError:
            pass
    if not v:
        raise KeyError("HTTPS_PROXY")
    return v

def main():
    host, port = sys.argv[1], int(sys.argv[2])
    u = urlparse(proxy_url())
    # Port 3130 is the tailnet CONNECT relay on the runtime HTTP proxy (per
    # ~/docs/devices/tailscale.md: reuse HTTPS_PROXY host, change port to 3130).
    # Do NOT use u.port (3128 = plain HTTPS egress, refuses tailnet CONNECT).
    proxy = (u.hostname, 3130)
    auth = base64.b64encode(f"{u.username}:{u.password}".encode()).decode()
    s = socket.create_connection(proxy, timeout=20)
    s.sendall(
        f"CONNECT {host}:{port} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Proxy-Authorization: Basic {auth}\r\n\r\n".encode()
    )
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit(1)
        resp += chunk
    if b" 200 " not in resp.split(b"\r\n")[0]:
        sys.exit(1)
    s.setblocking(True)  # create_connection may leave the fd non-blocking -> EAGAIN
    # hand the live socket to ssh over stdio (fd-level, works for pipes+sockets)
    import threading
    s_fd, in_fd, out_fd = s.fileno(), sys.stdin.fileno(), sys.stdout.fileno()
    def fwd(infd, outfd):
        try:
            while True:
                d = os.read(infd, 65536)
                if not d:
                    break
                os.write(outfd, d)
        except OSError:
            pass
    t1 = threading.Thread(target=fwd, args=(in_fd, s_fd), daemon=True)
    t2 = threading.Thread(target=fwd, args=(s_fd, out_fd), daemon=True)
    t1.start(); t2.start(); t1.join(); t2.join()

if __name__ == "__main__":
    main()
