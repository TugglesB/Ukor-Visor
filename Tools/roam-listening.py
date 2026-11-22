#!/usr/bin/env python3
"""Local socket snapshots and redaction of tcpdump's terse IPv4 summaries."""

import argparse
from datetime import datetime, timezone
import ipaddress
import os
import re
import select
import subprocess
import sys
import tempfile
import time


def endpoint(value):
    host, sep, port = value.rpartition(":")
    if not sep or (port != "*" and not (port.isascii() and port.isdecimal() and int(port) <= 65535)):
        return None
    try:
        if host != "*":
            host = str(ipaddress.ip_address(host.strip("[]")))
    except ValueError:
        return None
    return host, port


def socket_rows(output, tv):
    rows = set()
    protocol = name = state = ""

    def add():
        if protocol not in {"TCP", "UDP"}:
            return
        local, _, peer = name.partition("->")
        left = endpoint(local)
        right = endpoint(peer) if peer else None
        if not left or (peer and not right) or (not peer and protocol != "UDP"):
            return
        remote = ("TCL" if right[0] == tv else "OTHER") if right else "UNCONNECTED"
        if remote == "OTHER":
            # Retain evidence of an unrelated peer without disclosing its port or address.
            rows.add((protocol, "-", remote, "-", "-"))
            return
        tcp_state = state if state in {
            "ESTABLISHED", "SYN_SENT", "SYN_RECEIVED", "FIN_WAIT_1", "FIN_WAIT_2",
            "CLOSE_WAIT", "CLOSED", "LAST_ACK", "CLOSING", "TIME_WAIT", "LISTEN",
        } else "-"
        rows.add((protocol, left[1], remote, right[1] if right else "-", tcp_state))

    for line in output.splitlines() + ["f"]:
        key, value = line[:1], line[1:]
        if key in {"f", "p"}:
            add()
            protocol = name = state = ""
        elif key == "P":
            protocol = value
        elif key == "n":
            name = value
        elif line.startswith("TST="):
            state = value[3:]
    return rows


def run_tool(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=4, check=False)


def snapshot(pid, tv):
    result = run_tool(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-i", "-FfPnT", "-Ts"])
    # lsof exits 1 on no matching sockets. Treat diagnostics on stderr as a failed sample.
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError("lsof could not inspect Roam's sockets.")
    return socket_rows(result.stdout, tv)


def find_roam():
    result = run_tool(["/usr/bin/pgrep", "-x", "Roam"])
    ids = [int(line) for line in result.stdout.splitlines() if line.isdecimal()]
    if result.returncode != 0 or len(ids) != 1:
        raise RuntimeError("Expected one running Roam process. Open Roam manually and retry.")
    return ids[0]


class Log:
    def __init__(self, stream, now=time.monotonic):
        self.stream, self.now = stream, now
        self.start = now()

    def write(self, event, *fields):
        stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
        print(stamp, f"{self.now() - self.start:.3f}", event, *fields, sep="\t",
              file=self.stream, flush=True)


def observe(pid, tv, log, take_snapshot=snapshot, wait=select.select):
    previous = None
    phase = 0
    deadline = log.now() + 180
    log.write("START", f"PID={pid}", "BASELINE")
    try:
        while log.now() < deadline:
            try:
                rows = take_snapshot(pid, tv)
            except (RuntimeError, subprocess.TimeoutExpired):
                log.write("SAMPLE_UNAVAILABLE")
            else:
                for row in sorted(rows if previous is None else rows - previous):
                    log.write("PRESENT" if previous is None else "APPEARED", *row)
                for row in sorted(set() if previous is None else previous - rows):
                    log.write("DISAPPEARED", *row)
                previous = rows
            if wait([sys.stdin], [], [], 1)[0]:
                line = sys.stdin.readline()
                command = line.strip().lower()
                if not line or command in {"q", "quit"}:
                    break
                if command == "on" and phase == 0:
                    phase = 1
                    log.write("MARK", "LISTENING_ON")
                elif command == "off" and phase == 1:
                    phase = 2
                    log.write("MARK", "LISTENING_OFF")
                else:
                    print("Type on, off, or q and press Return.", file=sys.stderr)
    except KeyboardInterrupt:
        pass
    finally:
        log.write("STOP")


PACKET = re.compile(
    r"^(\d{9,12}\.\d{1,9}) IP ((?:\d{1,3}\.){4}\d{1,5}) > "
    r"((?:\d{1,3}\.){4}\d{1,5}): (tcp|UDP),? (?:length )?(\d{1,5})(?: \(DF\))?$"
)


def packet_row(line, tv):
    match = PACKET.fullmatch(line.strip())
    if not match:
        return None
    stamp, source, destination, protocol, size = match.groups()
    left = endpoint(":".join(source.rsplit(".", 1)))
    right = endpoint(":".join(destination.rsplit(".", 1)))
    if not left or not right or (left[0] == tv) == (right[0] == tv):
        return None
    return stamp, protocol.upper(), "TCL_TO_MAC" if left[0] == tv else "MAC_TO_TCL", left[1], right[1], size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["sockets", "packet-summary"])
    parser.add_argument("tv", type=ipaddress.IPv4Address, help="TCL's IPv4 address")
    args = parser.parse_args()
    tv = str(args.tv)
    if args.mode == "sockets" and not sys.stdin.isatty():
        parser.error("Socket mode requires an interactive Terminal.")
    try:
        pid = find_roam() if args.mode == "sockets" else None
        with tempfile.NamedTemporaryFile(mode="w", prefix="roam-listening-", suffix=".tsv",
                                         dir=os.path.expanduser("~"), delete=False) as file:
            print(f"Private log: {file.name}", flush=True)
            if args.mode == "sockets":
                print("Type on, off, or q, then Return. Ctrl-C also stops.", flush=True)
                observe(pid, tv, Log(file))
            else:
                print("# unix_time\tprotocol\tdirection\tsource_port\tdestination_port\tbytes", file=file)
                for line in sys.stdin:
                    row = packet_row(line, tv)
                    if row:
                        print(*row, sep="\t", file=file, flush=True)
    except KeyboardInterrupt:
        return 130
    except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
        print(f"Diagnostic stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
