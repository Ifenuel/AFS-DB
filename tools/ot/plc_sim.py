"""Minimal Modbus TCP server standing in for a wellhead PLC.

Three holding registers are exposed at addresses 0..2 and scaled by 100:
   0  wellhead pressure, bar
   1  separator inlet flow, m3/h
   2  separator temperature, C

The values are synthetic and drift slowly; the protocol is real. Function code 3
(read holding registers) is the only function implemented, which is all a
historian collector needs. Run with:  python tools/ot/plc_sim.py --port 15020
"""
from __future__ import annotations

import argparse
import math
import socketserver
import struct
import time

START = time.monotonic()


def registers() -> list[int]:
    t = time.monotonic() - START
    pressure = 72.4 + 2.1 * math.sin(t / 17.0) + 0.15 * math.sin(t * 1.7)
    flow = 41.6 + 1.4 * math.sin(t / 11.0 + 0.6)
    temp = 63.2 + 0.9 * math.sin(t / 23.0 + 1.2)
    return [int(round(pressure * 100)), int(round(flow * 100)), int(round(temp * 100))]


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        self.request.settimeout(5)
        while True:
            try:
                header = self._read_exact(7)
                if not header:
                    return
                transaction, protocol, length, unit = struct.unpack(">HHHB", header)
                pdu = self._read_exact(length - 1)
                if not pdu:
                    return
                function = pdu[0]
                if function != 3 or len(pdu) < 5:
                    self._exception(transaction, unit, function, 1)
                    continue
                start, count = struct.unpack(">HH", pdu[1:5])
                if count < 1 or count > 125:
                    self._exception(transaction, unit, function, 3)
                    continue
                values = registers()
                data = []
                for address in range(start, start + count):
                    data.append(values[address] if 0 <= address < len(values) else 0)
                payload = struct.pack(">BB", function, len(data) * 2) + b"".join(
                    struct.pack(">H", value) for value in data
                )
                response = struct.pack(">HHHB", transaction, 0, len(payload) + 1, unit) + payload
                self.request.sendall(response)
            except (ConnectionResetError, BrokenPipeError, struct.error, OSError):
                return

    def _read_exact(self, size: int) -> bytes:
        buffer = b""
        while len(buffer) < size:
            chunk = self.request.recv(size - len(buffer))
            if not chunk:
                return b""
            buffer += chunk
        return buffer

    def _exception(self, transaction: int, unit: int, function: int, code: int) -> None:
        payload = struct.pack(">BBB", function | 0x80, code, 0)
        header = struct.pack(">HHHB", transaction, 0, len(payload) + 1, unit)
        self.request.sendall(header + payload[:2] + b"")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=15020)
    args = parser.parse_args()
    with Server((args.host, args.port), Handler) as server:
        print(f"plc_sim listening on {args.host}:{args.port} with 3 holding registers", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
