#!/usr/bin/env python3
"""Send a QEMU monitor command over a unix socket.

Usage: qemu-screenshot.py <monitor-socket> <output.ppm>

Connects to the QEMU human monitor listening on a unix socket and issues the
`screendump` command, which writes a PPM image of the graphical console.
"""

import socket
import sys
import time


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: qemu-screenshot.py <monitor-socket> <output.ppm>", file=sys.stderr)
        return 2

    socket_path, output_path = sys.argv[1], sys.argv[2]

    deadline = time.time() + 20.0
    last_error = None
    while time.time() < deadline:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(10.0)
                sock.connect(socket_path)
                # Drain the monitor banner.
                time.sleep(0.3)
                try:
                    sock.recv(65536)
                except socket.timeout:
                    pass
                sock.sendall(b"screendump " + output_path.encode() + b"\n")
                time.sleep(1.0)
                try:
                    sock.recv(65536)
                except socket.timeout:
                    pass
            return 0
        except OSError as error:
            last_error = error
            time.sleep(0.25)

    print(f"ERROR: could not reach the QEMU monitor: {last_error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
