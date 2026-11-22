#!/usr/bin/env python3
"""Report header metadata for a manually controlled Roam listening session."""

from collections import Counter, defaultdict
from datetime import datetime
import ipaddress
import json
import os
from pathlib import Path
import selectors
import signal
from statistics import median
import struct
import subprocess
import sys
import time

LIMIT = 8000
SNAP = 54  # Ethernet + minimal IPv4 + minimal TCP
MAX_BYTES = 24 + LIMIT * (16 + SNAP)
MAX_SECONDS = 45


def packets(data, tv, mac):
    if len(data) < 24 or len(data) > MAX_BYTES:
        raise ValueError("Capture missing or outside the expected size limit.")
    formats = {b"\xd4\xc3\xb2\xa1": ("<", 1000), b"\xa1\xb2\xc3\xd4": (">", 1000),
               b"\x4d\x3c\xb2\xa1": ("<", 1), b"\xa1\xb2\x3c\x4d": (">", 1)}
    if bytes(data[:4]) not in formats:
        raise ValueError("Expected classic pcap.")
    endian, scale = formats[bytes(data[:4])]
    if struct.unpack_from(endian + "II", data, 16) != (SNAP, 1):
        raise ValueError("Expected bounded Ethernet-format headers.")
    offset = 24
    for _ in range(LIMIT):
        if offset + 16 > len(data):
            break
        sec, frac, count, wire = struct.unpack_from(endian + "IIII", data, offset)
        offset += 16
        if count > SNAP or count > wire or offset + count > len(data):
            break
        record = data[offset:offset + count]
        offset += count
        if len(record) < 42 or record[12:14] != b"\x08\x00":
            continue
        ip = record[14:]
        ihl = (ip[0] & 15) * 4
        total, fragment = struct.unpack_from("!HxxH", ip, 2)
        proto = ip[9]
        if ip[0] >> 4 != 4 or ihl < 20 or fragment & 0x3fff or total + 14 > wire:
            continue
        source, dest = ip[12:16], ip[16:20]
        if (source, dest) == (tv, mac):
            direction = "TCL→Mac"
        elif (source, dest) == (mac, tv):
            direction = "Mac→TCL"
        else:
            continue
        minimum = 20 if proto == 6 else 8 if proto == 17 else 0
        if not minimum or len(ip) < ihl + minimum or total < ihl + minimum:
            continue
        sport, dport = struct.unpack_from("!HH", ip, ihl)
        if proto == 6:
            header = (ip[ihl + 12] >> 4) * 4
            if not 20 <= header <= total - ihl:
                continue
            flags = ip[ihl + 13]
            event = ("RST" if flags & 4 else "FIN" if flags & 1 else
                     "SYN-ACK" if flags & 18 == 18 else "SYN" if flags & 2 else None)
        else:
            length = struct.unpack_from("!H", ip, ihl + 4)[0]
            if not 8 <= length <= total - ihl:
                continue
            event = None
        local, remote = (sport, dport) if direction == "Mac→TCL" else (dport, sport)
        yield (sec * 1_000_000_000 + frac * scale, "TCP" if proto == 6 else "UDP",
               direction, local, remote, total, event)


def report(rows, start, markers, end, completion):
    def elapsed(stamp):
        return round((stamp - start) / 1e9, 6)

    def stage(stamp):
        if "listening_off" in markers and stamp >= markers["listening_off"]:
            return "after"
        if "listening_on" in markers and stamp >= markers["listening_on"]:
            return "listening"
        return "baseline"

    groups = defaultdict(list)
    events = []
    for stamp, protocol, direction, local, remote, size, event in sorted(rows, key=lambda row: row[0]):
        if not start <= stamp <= end:
            continue
        groups[(protocol, direction, local, remote)].append((stamp, size, event))
        if event:
            events.append({"at_s": elapsed(stamp), "event": event, "direction": direction,
                           "mac_port": local, "tcl_port": remote, "stage": stage(stamp)})
    flows = []
    for (protocol, direction, local, remote), group in groups.items():
        during = [stamp for stamp, _, _ in group if stage(stamp) == "listening"]
        gaps = [(b - a) / 1e9 for a, b in zip(during, during[1:])]
        cadence = median(gaps) if gaps else 0
        periodic = (len(gaps) >= 4 and 0.1 <= cadence <= 10
                    and sum(abs(gap - cadence) <= cadence * 0.2 for gap in gaps) >= len(gaps) * 0.8)
        flows.append({
            "transport": protocol, "direction": direction, "mac_port": local, "tcl_port": remote,
            "first_s": elapsed(group[0][0]), "last_s": elapsed(group[-1][0]), "packets": len(group),
            "by_stage": dict(Counter(stage(stamp) for stamp, _, _ in group)),
            "ipv4_bytes": {"min": min(size for _, size, _ in group),
                           "max": max(size for _, size, _ in group),
                           "total": sum(size for _, size, _ in group)},
            "periodic_candidate_s": round(cadence, 4) if periodic else None,
            "interpretation": ("audio candidate (historically observed port)" if
                               protocol == "UDP" and direction == "TCL→Mac" and local == 6970
                               else "unknown"),
        })
    flows.sort(key=lambda flow: flow["first_s"])
    audio = next((flow for flow in flows if flow["interpretation"].startswith("audio")), None)
    syn = next((event for event in events if event["event"] == "SYN"
                and event["direction"] == "Mac→TCL" and event["tcl_port"] == 8060
                and "listening_on" in markers and event["stage"] == "listening"
                and audio and event["at_s"] <= audio["first_s"]), None)
    syn_ack = next((item for item in events if syn and item["event"] == "SYN-ACK"
                    and item["direction"] == "TCL→Mac"
                    and (item["mac_port"], item["tcl_port"]) == (syn["mac_port"], syn["tcl_port"])
                    and syn["at_s"] <= item["at_s"] <= audio["first_s"]), None)
    return {"completion": completion, "duration_s": elapsed(end),
            "complete_stages": {"listening_on", "listening_off"} <= markers.keys(),
            "markers_s": {name: elapsed(stamp) for name, stamp in markers.items()},
            "tcp_events": events, "flows": flows,
            "first_candidate_audio_since_on_s": (
                round(audio["first_s"] - elapsed(markers["listening_on"]), 6)
                if audio and "listening_on" in markers else None),
            "activation_tcp_syn_to_candidate_audio_s": (
                round(audio["first_s"] - syn["at_s"], 6) if syn else None),
            "activation_tcp_syn_ack_to_candidate_audio_s": (
                round(audio["first_s"] - syn_ack["at_s"], 6) if syn_ack else None),
            "last_candidate_audio_since_off_s": (
                round(audio["last_s"] - elapsed(markers["listening_off"]), 6)
                if audio and "listening_off" in markers else None),
            "application_framing": "unknown; transport headers only"}


def capture(tv):
    route = subprocess.check_output(["/sbin/route", "-n", "get", str(tv)], text=True, timeout=2)
    iface = next((row.split()[1] for row in route.splitlines() if row.strip().startswith("interface:")), None)
    if not iface:
        raise ValueError("No interface for the TCL route.")
    mac = ipaddress.IPv4Address(subprocess.check_output(
        ["/usr/sbin/ipconfig", "getifaddr", iface], text=True, timeout=2).strip())
    if mac == tv:
        raise ValueError("The TV address must differ from the Mac address.")
    command = ["/usr/bin/sudo", "-n", "/usr/sbin/tcpdump", "-i", iface, "-p", "-nn",
               "-y", "EN10MB", "-s", str(SNAP), "-c", str(LIMIT), "-U", "-w", "-",
               f"ip and host {tv} and host {mac} and (tcp or udp) and ip[6:2] & 0x3fff = 0"]
    raw = bytearray()
    marks = {}
    start = time.time_ns()
    begin = time.monotonic()
    deadline = begin + MAX_SECONDS
    completion = "time limit"
    print("Leave listening off for 8 seconds. Then turn it on in Roam and enter on here.", flush=True)
    print("When audible, enter heard. After about 15 seconds, turn it off and enter off.", flush=True)
    print("If TV sound returns, enter tv. The capture ends 8 seconds after off (or enter q).", flush=True)

    with subprocess.Popen(command, stdout=subprocess.PIPE) as child, selectors.DefaultSelector() as ready:
        ready.register(child.stdout, selectors.EVENT_READ, "capture")
        ready.register(sys.stdin, selectors.EVENT_READ, "input")
        try:
            while time.monotonic() < deadline:
                for key, _ in ready.select(max(0, deadline - time.monotonic())):
                    if key.data == "capture":
                        chunk = os.read(key.fd, 8192)
                        if not chunk:
                            completion = "capture ended"
                            break
                        raw.extend(chunk)
                        if len(raw) > MAX_BYTES:
                            raise ValueError("Capture exceeded size limit.")
                    else:
                        line = sys.stdin.readline()
                        word = line.strip().lower()
                        if not line or word in {"q", "quit"}:
                            completion = "user stopped"
                            break
                        name, allowed = {
                            "on": ("listening_on", "listening_off" not in marks),
                            "heard": ("audible_on_mac", "listening_on" in marks and "listening_off" not in marks),
                            "off": ("listening_off", "listening_on" in marks),
                            "tv": ("tv_audio_returned", "listening_off" in marks),
                        }.get(word, ("", False))
                        if allowed and name not in marks:
                            marks[name] = time.time_ns()
                            print(f"Marked {name}.", flush=True)
                            if word == "off":
                                deadline = min(deadline, time.monotonic() + 8)
                        else:
                            print("Use on, heard, off, tv, or q in that order.", flush=True)
                else:
                    continue
                break
        except KeyboardInterrupt:
            completion = "interrupted"
        finally:
            end = time.time_ns()
            if child.poll() is None:
                child.send_signal(signal.SIGINT)
            try:
                tail, _ = child.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                child.terminate()
                tail, _ = child.communicate(timeout=3)
            raw.extend(tail)
    return report(packets(raw, tv.packed, mac.packed), start, marks, end, completion)


def main():
    try:
        if not sys.stdin.isatty():
            raise ValueError("Run in an interactive Terminal.")
        tv = ipaddress.IPv4Address(input("TCL IPv4 address: ").strip())
        result = capture(tv)
        path = Path.home() / f"roku-session-{datetime.now():%Y%m%d-%H%M%S-%f}.json"
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
            json.dump(result, output, indent=2, ensure_ascii=False)
            output.write("\n")
        print(f"Saved: {path}")
        print(f"{result['completion']}; stage markers: {result['markers_s']}")
        timeline = [(item["at_s"], f"TCP {item['event']} {item['direction']} "
                     f"Mac:{item['mac_port']} TCL:{item['tcl_port']}") for item in result["tcp_events"]]
        for flow in result["flows"]:
            timeline.append((flow["first_s"], f"{flow['transport']} {flow['direction']} "
                             f"Mac:{flow['mac_port']} TCL:{flow['tcl_port']}, {flow['packets']} packets "
                             f"through {flow['last_s']:.3f}s; {flow['by_stage']}"))
        for stamp, item in sorted(timeline)[:80]:
            print(f"{stamp:8.3f}s {item}")
        if len(timeline) > 80:
            print("Additional timeline entries are in the JSON report.")
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"Diagnostic failed: {error}")


if __name__ == "__main__":
    main()
