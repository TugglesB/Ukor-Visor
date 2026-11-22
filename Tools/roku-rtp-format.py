#!/usr/bin/env python3
"""Bounded, header-only compatibility diagnostic for a user-started Roam session."""

import argparse
from collections import Counter, defaultdict
import ctypes as c
import ipaddress
import json
import os
from pathlib import Path
import signal
from statistics import median
import struct
import subprocess
import sys

LIMIT = 1200
SNAP = 58  # Ethernet 14 + IPv4 20 + UDP 8 + RTP 12 + up to 4 prefix bytes
PROBE_SNAP = 14 + 60 + 8 + 2048
PORT = 6970
SECONDS = 12
MAX_REPORT = 1024 * 1024


def udp_header(packet, tv, mac):
    if len(packet) < 42 or packet[12:14] != b"\x08\x00":
        return None
    ip = packet[14:]
    ihl = (ip[0] & 15) * 4
    if (ip[0] >> 4 != 4 or ihl < 20 or len(ip) < ihl + 8 or ip[9] != 17
            or int.from_bytes(ip[6:8], "big") & 0x3fff
            or ip[12:16] != tv or ip[16:20] != mac):
        return None
    source, destination, length = struct.unpack_from("!HHH", ip, ihl)
    if (destination != PORT or length < 8
            or length > int.from_bytes(ip[2:4], "big") - ihl):
        return None
    wire_payload = length - 8
    return source, wire_payload, ip[ihl + 8:ihl + 8 + wire_payload]


def rtp_candidates(header, length):
    candidates = []
    for offset in range(5):
        if len(header) < offset + 12:
            break
        first, second, seq, stamp, ssrc = struct.unpack_from("!BBHII", header, offset)
        if first >> 6 != 2:
            continue
        extension = bool(first & 0x10)
        csrc = first & 15
        minimum = offset + 12 + 4 * csrc + (4 if extension else 0) + (1 if first & 0x20 else 0)
        if length <= minimum:
            continue
        candidates.append([offset, second & 127, seq, stamp, ssrc, extension, csrc])
    return candidates


def opus_payload(packet, wire_length):
    """Only the observed, unprefixed RTP v2/PT 97 stream is eligible."""
    if not 12 < len(packet) == wire_length <= 2048 or packet[0] >> 6 != 2 or packet[1] & 127 != 97:
        return None
    start = 12 + 4 * (packet[0] & 15)
    end = len(packet)
    if packet[0] & 0x20:
        if packet[-1] == 0:
            return None
        end -= packet[-1]
    if packet[0] & 0x10:
        if start + 4 > end:
            return None
        start += 4 + 4 * int.from_bytes(packet[start + 2:start + 4], "big")
    return packet[start:end] if start < end else None


class OpusProbe:
    def __init__(self):
        self.lib = c.CDLL("/opt/homebrew/opt/opus/lib/libopus.0.dylib")
        self.lib.opus_decoder_create.argtypes = [c.c_int32, c.c_int, c.POINTER(c.c_int)]
        self.lib.opus_decoder_create.restype = c.c_void_p
        self.lib.opus_decoder_destroy.argtypes = [c.c_void_p]
        self.lib.opus_decoder_destroy.restype = None
        self.lib.opus_decode_float.argtypes = [c.c_void_p, c.c_char_p, c.c_int32,
                                              c.POINTER(c.c_float), c.c_int, c.c_int]
        self.lib.opus_decode_float.restype = c.c_int
        self.lib.opus_packet_get_nb_channels.argtypes = [c.c_char_p]
        self.lib.opus_packet_get_nb_channels.restype = c.c_int
        self.pcm = (c.c_float * (5760 * 2))()
        self.decoder = None
        self.flow = None
        self.previous_sequence = None

    def __enter__(self):
        status = c.c_int()
        self.decoder = self.lib.opus_decoder_create(48000, 2, c.byref(status))
        if not self.decoder:
            raise ValueError(f"Cannot initialize libopus ({status.value}).")
        return self

    def __exit__(self, *_):
        if self.decoder:
            self.lib.opus_decoder_destroy(self.decoder)
            self.decoder = None

    def inspect(self, source, packet, wire_length):
        payload = opus_payload(packet, wire_length)
        if payload is None:
            return ["skipped"]
        seq, _, ssrc = struct.unpack_from("!HII", packet, 2)
        flow = (source, ssrc)
        if self.flow is None:
            self.flow = flow
        if self.flow != flow:
            return ["skipped"]
        if self.previous_sequence is not None and not 0 < (seq - self.previous_sequence) & 65535 < 32768:
            return ["skipped"]
        self.previous_sequence = seq
        try:
            frames = self.lib.opus_decode_float(self.decoder, payload, len(payload), self.pcm, 5760, 0)
            if frames <= 0:
                return ["failed"]
            return ["decoded", frames, self.lib.opus_packet_get_nb_channels(payload)]
        finally:
            c.memset(self.pcm, 0, c.sizeof(self.pcm))


def read_pcap(data, tv, mac, probe=None):
    if len(data) < 24:
        raise ValueError("No usable pcap header. Check tcpdump's diagnostic.")
    endian = {b"\xd4\xc3\xb2\xa1": "<", b"\xa1\xb2\xc3\xd4": ">",
              b"\x4d\x3c\xb2\xa1": "<", b"\xa1\xb2\x3c\x4d": ">"}.get(bytes(data[:4]))
    if endian is None:
        raise ValueError("Expected classic pcap.")
    snap, link = struct.unpack_from(endian + "II", data, 16)
    max_snap = PROBE_SNAP if probe is not None else SNAP
    if link != 1 or not 1 <= snap <= max_snap:
        raise ValueError("Expected a bounded Ethernet capture.")
    rows = []
    precision = 1 if data[:4] in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d") else 1000
    offset = 24
    for _ in range(LIMIT):
        if len(data) - offset < 16:
            break
        seconds, fraction, count, wire = struct.unpack_from(endian + "IIII", data, offset)
        offset += 16
        if count > snap or count > wire or count > len(data) - offset:
            break
        parsed = udp_header(data[offset:offset + count], tv, mac)
        offset += count
        if parsed is not None:
            source, length, header = parsed
            row = {"source": source, "length": length, "first": header[0] if header else None,
                   "arrival_ns": seconds * 1_000_000_000 + fraction * precision,
                   "header_bytes": min(len(header), 16), "rtp": rtp_candidates(header[:16], length)}
            if probe is not None:
                row["opus"] = probe.inspect(source, header, length)
                if row["opus"][0] == "skipped":
                    row["first"] = None
                    row["rtp"] = []
            rows.append(row)
    return rows


def summarize(rows):
    sizes = Counter(row["length"] for row in rows)
    flows = Counter(row["source"] for row in rows)
    first = Counter(row["first"] for row in rows if row["first"] is not None)
    groups = defaultdict(list)
    for row in rows:
        for offset, pt, seq, stamp, ssrc, extension, csrc in row["rtp"]:
            groups[(row["source"], offset, pt, ssrc)].append((seq, stamp, extension, csrc, row.get("arrival_ns")))
    report = {
        "packets": len(rows),
        "endpoints": {f"TCL:{port} -> MAC:{PORT}": count for port, count in flows.items()},
        "udp_payload_lengths": dict(sorted(sizes.items())),
        "first_byte_patterns": {f"0x{value:02x}": count for value, count in first.most_common(12)},
        "first_byte_version_bits": dict(Counter(row["first"] >> 6 for row in rows if row["first"] is not None)),
        "insufficient_bytes_for_base_header": sum(row["header_bytes"] < 12 for row in rows),
        "rtp_candidates": [],
        "codec": "Unverified. RTP headers and payload type alone cannot identify Opus.",
    }
    for (port, offset, pt, _), group in sorted(groups.items(), key=lambda pair: -len(pair[1]))[:12]:
        seq_steps = []
        stamps = Counter()
        paired = []
        for (old_seq, old_stamp, _, _, old_time), (seq, stamp, _, _, arrival) in zip(group, group[1:]):
            step = (seq - old_seq) & 65535
            seq_steps.append(step)
            if step == 1:
                ticks = (stamp - old_stamp) & 0xffffffff
                stamps[ticks] += 1
                if arrival is not None and old_time is not None and arrival >= old_time:
                    paired.append((arrival - old_time, ticks))
        adjacent = seq_steps.count(1)
        common = stamps.most_common(1)
        strong = len(group) >= 20 and adjacent >= 0.9 * (len(group) - 1) and common and common[0][0] > 0 and common[0][1] >= 0.9 * adjacent
        opus_timing = (
            f"{common[0][0] / 48:g} ms at an assumed 48 kHz RTP clock; compatible duration, codec unverified"
            if strong and common[0][0] in {120, 240, 480, 960, 1920, 2880, 5760}
            else "No clear match to a common Opus duration at 48 kHz"
        )
        report["rtp_candidates"].append({
            "source_port": port, "offset": offset, "payload_type": pt,
            "same_ssrc_packets": len(group), "adjacent_sequences": adjacent,
            "repeated_sequences": seq_steps.count(0),
            "forward_gaps": sum(1 < step < 32768 for step in seq_steps),
            "backward_or_reordered": sum(step >= 32768 for step in seq_steps),
            "timestamp_steps_on_adjacent_packets": dict(stamps.most_common(12)),
            "extension_bit_packets": sum(row[2] for row in group),
            "csrc_count_distribution": dict(Counter(row[3] for row in group)),
            "opus_timing_hint": opus_timing,
            "paired_arrival_timing": arrival_timing(paired),
            "framing_evidence": "strong RTP-like continuity" if strong else "inconclusive",
        })
    probe_rows = [row["opus"] for row in rows if "opus" in row]
    if probe_rows:
        outcomes = Counter(row[0] for row in probe_rows)
        durations = Counter(row[1] / 48 for row in probe_rows if row[0] == "decoded")
        channels = Counter(row[2] for row in probe_rows if row[0] == "decoded")
        attempts = outcomes["decoded"] + outcomes["failed"]
        strong = (outcomes["decoded"] >= 100 and outcomes["decoded"] >= attempts * 0.98
                  and outcomes["decoded"] >= len(probe_rows) * 0.90
                  and any(row["framing_evidence"] == "strong RTP-like continuity"
                          and row["offset"] == 0 and row["payload_type"] == 97
                          for row in report["rtp_candidates"]))
        report["opus_probe"] = {
            "attempts": attempts, "successful": outcomes["decoded"], "failed": outcomes["failed"],
            "skipped": outcomes["skipped"], "pcm_frames_per_channel": sum(row[1] for row in probe_rows if row[0] == "decoded"),
            "frame_duration_ms": dict(durations), "opus_packet_channels": dict(channels),
            "evidence": "strong libopus compatibility" if strong else "insufficient sustained compatibility evidence",
            "output": "48 kHz stereo PCM was discarded in memory; no playback",
        }
    return report


def arrival_timing(samples):
    if not samples:
        return None
    total_ns = sum(delta for delta, _ in samples)
    hz = sum(ticks for _, ticks in samples) * 1e9 / total_ns if total_ns else None
    behavior = "inconclusive"
    if len(samples) >= 20 and hz is not None:
        if 900 <= hz <= 1100:
            behavior = "approximately 1 kHz; consistent with millisecond-scale timestamps"
        elif 43_200 <= hz <= 52_800:
            behavior = "approximately 48 kHz; consistent with the standard Opus RTP sample clock"
    return {"adjacent_pairs": len(samples), "median_arrival_ms": round(median(delta for delta, _ in samples) / 1e6, 3),
            "mean_arrival_ms": round(total_ns / len(samples) / 1e6, 3),
            "estimated_ticks_per_second": round(hz, 1) if hz is not None else None, "behavior": behavior}


def collect(tv, probe=None):
    route = subprocess.check_output(["/sbin/route", "-n", "get", str(tv)], text=True, timeout=2)
    iface = next((line.split()[1] for line in route.splitlines() if line.strip().startswith("interface:")), None)
    if not iface:
        raise ValueError("No local interface for the TCL route.")
    mac = ipaddress.IPv4Address(subprocess.check_output(
        ["/usr/sbin/ipconfig", "getifaddr", iface], text=True, timeout=2).strip())
    if mac == tv:
        raise ValueError("The TCL address must differ from the Mac address.")
    command = ["/usr/bin/sudo", "-n", "/usr/sbin/tcpdump", "-i", iface, "-p", "-nn",
               "-y", "EN10MB", "-s", str(PROBE_SNAP if probe else SNAP), "-c", str(LIMIT), "-U", "-w", "-",
               f"ip and udp and src host {tv} and dst host {mac} and dst port {PORT} and ip[6:2] & 0x3fff = 0"]
    print(f"Inspecting inbound UDP headers for at most {SECONDS} seconds or {LIMIT} packets.", flush=True)
    with subprocess.Popen(command, stdout=subprocess.PIPE) as capture:
        try:
            data, _ = capture.communicate(timeout=SECONDS)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            capture.send_signal(signal.SIGINT)
            try:
                data, _ = capture.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                capture.terminate()
                data, _ = capture.communicate(timeout=3)
    return read_pcap(data, tv.packed, mac.packed, probe)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture")
    capture.add_argument("tv", type=ipaddress.IPv4Address)
    capture.add_argument("file", type=Path)
    capture.add_argument("--probe-opus", action="store_true", help="explicitly inspect inbound audio bytes in memory")
    analyze = commands.add_parser("analyze")
    analyze.add_argument("file", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            with os.fdopen(os.open(args.file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
                if args.probe_opus:
                    with OpusProbe() as probe:
                        rows = collect(args.tv, probe)
                else:
                    rows = collect(args.tv)
                json.dump(rows, output, separators=(",", ":"))
        else:
            with args.file.open("rb") as input_file:
                raw = input_file.read(MAX_REPORT + 1)
            if len(raw) > MAX_REPORT:
                raise ValueError("Metadata exceeds analysis size limit.")
            rows = json.loads(raw)
            if not isinstance(rows, list) or len(rows) > LIMIT:
                raise ValueError("Metadata exceeds analysis row limit or has an invalid format.")
            print(json.dumps(summarize(rows), indent=2))
    except (OSError, ValueError, subprocess.SubprocessError, KeyError, TypeError, IndexError) as error:
        parser.exit(1, f"Diagnostic failed: {error}\n")


if __name__ == "__main__":
    main()
