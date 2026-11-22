import importlib.util
import ipaddress
import json
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("timeline", Path(__file__).with_name("roku-session-timeline.py"))
timeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timeline)

MAC = ipaddress.IPv4Address("192.0.2.2").packed
TV = ipaddress.IPv4Address("192.0.2.3").packed
SECOND = 1_000_000_000


def record(sec, src, dst, sport, dport, flags=None):
    # The sentinel is intentionally inside the UDP snap length.
    payload = b"secret-token"
    if flags is None:
        proto = 17
        transport = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0)
    else:
        proto = 6
        transport = struct.pack("!HHIIBBHHH", sport, dport, 0, 0, 0x50, flags, 0, 0, 0)
    total = 20 + len(transport) + len(payload)
    ipv4 = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total, 0, 0, 64, proto, 0, src, dst)
    frame = bytes(12) + b"\x08\x00" + ipv4 + transport + payload
    body = frame[:timeline.SNAP]
    return struct.pack("<IIII", sec, 0, len(body), len(frame)) + body


def pcap(*records):
    return struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, timeline.SNAP, 1) + b"".join(records)


class TimelineTests(unittest.TestCase):
    def test_phases_order_flags_and_flow_timing(self):
        data = pcap(record(6, TV, MAC, 45598, 6970),
                    record(2, MAC, TV, 50000, 8060, 0x10),
                    record(4, MAC, TV, 50001, 8060, 0x02),
                    record(5, TV, MAC, 8060, 50001, 0x12),
                    record(14, TV, MAC, 8060, 50001, 0x11),
                    record(13, TV, MAC, 45598, 6970),
                    *(record(i, MAC, TV, 6970, 5150) for i in range(6, 12)))
        result = timeline.report(timeline.packets(data, TV, MAC), SECOND,
                                 {"listening_on": 4 * SECOND, "listening_off": 13 * SECOND},
                                 17 * SECOND, "user stopped")
        self.assertTrue(result["complete_stages"])
        self.assertEqual([e["event"] for e in result["tcp_events"]], ["SYN", "SYN-ACK", "FIN"])
        self.assertEqual(result["flows"][0]["by_stage"], {"baseline": 1})
        self.assertEqual(result["first_candidate_audio_since_on_s"], 2)
        self.assertEqual(result["activation_tcp_syn_to_candidate_audio_s"], 2)
        self.assertEqual(result["activation_tcp_syn_ack_to_candidate_audio_s"], 1)
        self.assertEqual(result["last_candidate_audio_since_off_s"], 0)
        periodic = next(f for f in result["flows"] if f["tcl_port"] == 5150)
        self.assertEqual(periodic["direction"], "Mac→TCL")
        self.assertEqual(periodic["periodic_candidate_s"], 1)
        audio = next(f for f in result["flows"] if f["mac_port"] == 6970 and f["direction"] == "TCL→Mac")
        self.assertEqual(audio["by_stage"], {"listening": 1, "after": 1})
        text = json.dumps(result)
        for value in ("secret-token", "192.0.2.2", "192.0.2.3"):
            self.assertNotIn(value, text)

    def test_filters_truncation_and_incomplete_run(self):
        outsider = ipaddress.IPv4Address("192.0.2.99").packed
        data = pcap(record(2, outsider, MAC, 8060, 6970),
                    record(3, TV, MAC, 8060, 50000, 0x04))[:-1]
        result = timeline.report(timeline.packets(data, TV, MAC), SECOND, {}, 5 * SECOND, "interrupted")
        self.assertFalse(result["complete_stages"])
        self.assertEqual(result["flows"], [])
        self.assertIsNone(result["first_candidate_audio_since_on_s"])


if __name__ == "__main__":
    unittest.main()
