import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("roam_listening", Path(__file__).with_name("roam-listening.py"))
diag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diag)


class DiagnosticsTest(unittest.TestCase):
    def test_socket_redaction(self):
        fixture = """p42
f3
PTCP
n192.168.0.1:50000->192.168.0.2:8060
TST=ESTABLISHED
f4
PUDP
n*:6970
f5
PUDP
n192.168.0.1:60000->192.168.0.2:5150
f6
PTCP
n[fe80::12]:5555->[fe80::34]:443
TST=ESTABLISHED
f7
PUDP
n127.0.0.1:5555->secret.example:443
"""
        self.assertEqual(diag.socket_rows(fixture, "192.168.0.2"), {
            ("TCP", "50000", "TCL", "8060", "ESTABLISHED"),
            ("UDP", "6970", "UNCONNECTED", "-", "-"),
            ("UDP", "60000", "TCL", "5150", "-"),
            ("TCP", "-", "OTHER", "-", "-"),
        })

    def test_events_markers_and_monotonic_elapsed(self):
        stream = io.StringIO()
        log = diag.Log(stream, now=lambda: 30.25)
        baseline = {("TCP", "123", "TCL", "456", "ESTABLISHED")}
        extra = {("UDP", "789", "UNCONNECTED", "-", "-")}
        samples = iter([baseline, baseline | extra, baseline])
        with patch.object(diag.sys, "stdin", io.StringIO("on\noff\nq\n")):
            diag.observe(123, "192.168.0.2", log, lambda *_: next(samples), lambda *_: [True])
        lines = [line.split("\t") for line in stream.getvalue().splitlines()]
        self.assertEqual([line[2] for line in lines],
                         ["START", "PRESENT", "MARK", "APPEARED", "MARK", "DISAPPEARED", "STOP"])
        self.assertEqual(lines[2][3], "LISTENING_ON")
        self.assertEqual(lines[4][3], "LISTENING_OFF")
        self.assertTrue(all(line[1] == "0.000" for line in lines))
        self.assertRegex(lines[0][0], r"^\d{4}-\d\d-\d\dT.*\+00:00$")

    def test_timeout_and_interruption_close_log(self):
        stream = io.StringIO()
        with patch.object(diag.sys, "stdin", io.StringIO("")):
            diag.observe(123, "192.168.0.2", diag.Log(stream),
                         lambda *_: (_ for _ in ()).throw(subprocess.TimeoutExpired("test", 4)),
                         lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        self.assertIn("SAMPLE_UNAVAILABLE", stream.getvalue())
        self.assertTrue(stream.getvalue().endswith("\tSTOP\n"))

    def test_packet_summary_fails_closed(self):
        prefix = "1784000000.123456 IP "
        self.assertEqual(diag.packet_row(prefix + "192.168.0.2.5150 > 192.168.0.1.6971: UDP, length 24",
                                         "192.168.0.2"), ("1784000000.123456", "UDP", "TCL_TO_MAC", "5150", "6971", "24"))
        self.assertEqual(diag.packet_row(prefix + "192.168.0.1.50000 > 192.168.0.2.8060: tcp 0",
                                         "192.168.0.2"), ("1784000000.123456", "TCP", "MAC_TO_TCL", "50000", "8060", "0"))
        self.assertIsNone(diag.packet_row(prefix + "192.168.0.3.5150 > 192.168.0.1.6971: UDP, length 24", "192.168.0.2"))
        self.assertIsNone(diag.packet_row(prefix + "192.168.0.2.5150 > 192.168.0.1.6971: evil token", "192.168.0.2"))


if __name__ == "__main__":
    unittest.main()
