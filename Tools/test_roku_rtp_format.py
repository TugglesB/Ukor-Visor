import base64
import importlib.util
import json
import ipaddress
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("roku_rtp_format", Path(__file__).with_name("roku-rtp-format.py"))
diag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diag)
TV = ipaddress.IPv4Address("192.0.2.1").packed
MAC = ipaddress.IPv4Address("192.0.2.2").packed


def rtp(seq, stamp, first=0x80):
    return struct.pack("!BBHII", first, 97, seq, stamp, 123)


def frame(payload, wire_payload=None, destination=6970):
    size = len(payload) if wire_payload is None else wire_payload
    ethernet = bytes(12) + b"\x08\x00"
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 28 + size, 0, 0, 64, 17, 0, TV, MAC)
    return ethernet + ip + struct.pack("!HHHH", 36129, destination, size + 8, 0) + payload


def pcap(frames, snap=diag.SNAP):
    data = struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, snap, 1)
    for index, packet in enumerate(frames):
        cropped = packet[:snap]
        seconds, usec = divmod(index * 10_000, 1_000_000)
        data += struct.pack("<IIII", seconds, usec, len(cropped), len(packet)) + cropped
    return data


class RTPFormatTests(unittest.TestCase):
    def test_wraparound_timestamp_progression_and_variable_lengths(self):
        packets = [frame(rtp((65530 + i) & 65535, (0xfffff800 + i * 480) & 0xffffffff)
                         + bytes(30 + i % 3)) for i in range(30)]
        result = diag.summarize(diag.read_pcap(pcap(packets), TV, MAC))
        candidate = result["rtp_candidates"][0]
        self.assertEqual(candidate["adjacent_sequences"], 29)
        self.assertEqual(candidate["timestamp_steps_on_adjacent_packets"], {480: 29})
        self.assertEqual(candidate["framing_evidence"], "strong RTP-like continuity")
        self.assertEqual(result["udp_payload_lengths"], {42: 10, 43: 10, 44: 10})
        self.assertEqual(result["endpoints"], {"TCL:36129 -> MAC:6970": 30})

    def test_non_rtp_truncated_prefix_and_extension(self):
        packets = [frame(bytes(50)), frame(bytes(10), wire_payload=50),
                   frame(b"ABCD" + rtp(1, 480, 0x90) + bytes(30)),
                   frame(rtp(1, 480) + bytes(20), destination=9999)]
        rows = diag.read_pcap(pcap(packets), TV, MAC)
        self.assertEqual(len(rows), 3)
        self.assertFalse(rows[0]["rtp"])
        self.assertFalse(rows[1]["rtp"])
        self.assertIn([4, 97, 1, 480, 123, True, 0], rows[2]["rtp"])
        self.assertEqual(diag.summarize(rows)["insufficient_bytes_for_base_header"], 1)

    def test_arrival_clock_estimates_use_adjacent_sequences(self):
        for step, rate in [(10, 1000), (480, 48000)]:
            frames = [frame(rtp(i, i * step) + bytes(20)) for i in range(50) if i != 5]
            pairs = [(10_000_000, step)] * 30
            self.assertEqual(diag.arrival_timing(pairs)["estimated_ticks_per_second"], rate)
            report = diag.summarize(diag.read_pcap(pcap(frames), TV, MAC))
            group = report["rtp_candidates"][0]
            self.assertEqual(group["forward_gaps"], 1)
            self.assertEqual(group["paired_arrival_timing"]["adjacent_pairs"], 47)

    def test_probe_rejects_truncation_and_does_not_serialize_audio(self):
        fixture = base64.b64decode("fIf8tLVje4P1sAApqjAi3UJ2LY/myfY1BvC6MSf4F4wf/JBPv4Bwp0cJY0npPpExO5eoKZHO1hDdlO3CovCOJsGZiKsRnkznjtN4k9DzRnK0Zg7Q")
        self.assertIsNone(diag.opus_payload(rtp(1, 10), 90))
        self.assertIsNone(diag.opus_payload(rtp(1, 10, 0x90) + b"\x00\x00\xff\xffA", 17))
        self.assertIsNone(diag.opus_payload(rtp(1, 10, 0xa0) + b"A\x00", 14))
        frames = [frame(rtp(i, i * 20) + fixture) for i in range(120)]
        frames.append(frame(rtp(120, 2400) + b"\x03"))
        with diag.OpusProbe() as probe:
            rows = diag.read_pcap(pcap(frames, diag.PROBE_SNAP), TV, MAC, probe)
            self.assertFalse(any(probe.pcm))
        result = diag.summarize(rows)["opus_probe"]
        self.assertEqual(result["successful"], 120)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(result["frame_duration_ms"], {20.0: 120})
        self.assertEqual(result["evidence"], "strong libopus compatibility")
        self.assertNotIn(base64.b64encode(fixture).decode(), json.dumps(rows))
        self.assertEqual(set(rows[0]), {"source", "length", "first", "arrival_ns", "header_bytes", "rtp", "opus"})

    def test_capture_bound_and_truncated_pcap_record(self):
        packet = frame(rtp(0, 0) + bytes(40))
        self.assertEqual(len(diag.read_pcap(pcap([packet] * (diag.LIMIT + 2)), TV, MAC)), diag.LIMIT)
        self.assertEqual(diag.read_pcap(pcap([packet])[:-1], TV, MAC), [])
        bad = bytearray(pcap([]))
        bad[16] = diag.SNAP + 1
        with self.assertRaises(ValueError):
            diag.read_pcap(bad, TV, MAC)


if __name__ == "__main__":
    unittest.main()
