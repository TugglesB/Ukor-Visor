> Historical diagnostics below use example IPv4 addresses. Replace them with your own address only for an intentional local test. Build the Debug product as described in the README before running commands.

# Private Listening feasibility

Reviewed Roam main at `d44ef781ce825c785040ac68b1dceb3e18c84b23`. This release implements the Settings title-bar change. It contains no audio transport, decoder, playback controls, or simulated audio. Neither application was launched and no requests were sent to a Roku.

## What Roam does

- **Control channel.** Roam upgrades the Roku ECP service connection to a WebSocket at `/ecp-session`, negotiating `ecp-2`. Roku issues a challenge. Roam answers using an embedded seed and transformation that are absent from Roku’s public ECP documentation. This is a control-channel prerequisite, independent of the audio codec.
- **Capability and setup.** Roam queries the Roku’s audio-device capabilities. Datagram support is indicated by a reported destination, and the device can advertise an RTCP port. Roam opens local UDP listeners on 6970 (audio) and 6971 (control) before requesting datagram audio on the WebSocket. It advertises the Mac’s Roku-facing local address, RTP receive port, payload type 97, and a frame-size field of 960. The meaning of the last field is inferred. Outbound RTCP uses a separate ephemeral source port, targeting the Roku’s advertised port or 5150.
- **Start, keepalive, stop.** Roku-specific RTCP APP messages negotiate delay and acknowledge the client version. Roam requests 600 ms, expects the matching acknowledgment, and then exchanges client-version and new-client messages. The handshake retries within a bounded startup timeout. After setup, Roam emits receiver reports about once per second. Stop cancels the session tasks and closes the listeners and their accepted flows, with a best-effort RTCP BYE. Returning the TV to normal audio on each stop and failure path requires live verification.
- **Audio.** The UDP payload is RTP v2 carrying Opus. Roam decodes to 48 kHz stereo Float32 PCM with libopus and plays through AVAudioEngine, converting for the current output format. RTP sequence numbers are used to reorder packets, discard late audio, and conceal losses. The timing model uses sequence spacing and local host/render time; it does not derive playback timing from RTP timestamps or RTCP Sender Reports. Roam targets approximately 400 ms of jitter buffering and adjusts scheduling for output latency. Its playback model assumes 10 ms spacing despite the separate frame-size value advertised at startup.
- **Recovery and compatibility.** Port collisions and setup failures surface as errors. Roam monitors audio engine health and rebuilds its graph around output changes. Capability reporting, advertised RTCP port, handshake behavior, and timing are device/firmware dependencies. No reliable firmware matrix or guarantees for sleep/wake, another client taking over, HDMI audio, or failure-time restoration were established in this review. The user’s successful Roam session establishes support on their TV for Roam’s implementation.

## Implementation gate

The media layer can be designed independently around RTP, Opus, and public Apple audio APIs. The required Roku WebSocket authentication has no supported specification or independently authorized interoperable implementation established by this review. Implementing only the standard media layer would leave Ukor Visor unable to start playback. Stage B and the audio UI are deferred pending an authorized authentication path.

Roam’s checked-in license is **PolyForm Noncommercial 1.0.0**. Its README offers free commercial permission for the protocol code **by written request** to the address listed in its README; that offer is not a grant on its own. For reuse, request written permission explicitly covering the ECP WebSocket handshake and Roku-specific audio setup/RTCP code, redistribution in a paid Mac App Store app, and any required notices. Confirm with Roku whether this client authentication is authorized for third-party distribution. Roam’s grant would cover its own code only. Any later reused dependency, including an Opus implementation, needs its own license and notice review. No Roam code, authentication material, or dependency was added to this repository.

## macOS validation once authorized

Test Local Network access in an actual sandboxed signed app. Outbound WebSocket/RTCP and inbound UDP audio/control require validating both client and server entitlements. Public AVFoundation/Core Audio output needs no microphone capture for this design. Verify the default built-in, wired, and Bluetooth routes, switching routes during playback, volume scoped to the app, and cleanup on stop, sleep, timeouts, device change, or takeover. Use synthetic fixtures for protocol parsing and state transitions and obtain permission before any live test. Signing and permissions for this build are unchanged.

[Roam protocol notes](https://github.com/msdrigg/roam/blob/d44ef781ce825c785040ac68b1dceb3e18c84b23/Roam/AudioPlayer/audio-protocol.md) · [Roam source license and permission terms](https://github.com/msdrigg/roam/tree/d44ef781ce825c785040ac68b1dceb3e18c84b23#license) · [Roku ECP](https://developer.roku.com/dev/docs/external-control-api) · [Apple network entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)

## Phase 1.5.1 outcome B

The experimental Debug path independently parses standard RTP v2 headers, validates source/payload type/length, handles CSRCs, extensions and padding, and uses a bounded sequence window. The bundled synthetic tone goes through that path, decodes via libopus to 48 kHz stereo PCM, and renders using AVAudioEngine. Tests verify a non-silent decoded waveform, a PCM CAF round trip, and validation-failure cleanup without opening a physical audio route. The test environment could not initialize AVAudioEngine, so physical playback remains a manual check. The optional manual diagnostic opens the current macOS output for one short tone, waits up to two seconds for completion, and stops/detaches the player on exit. A lost route or render timeout ends the run; rerun after switching output. Volume is app-local and persisted under a separate experimental key, with 70% as its default. There is no UDP socket or Roku session in this path.

The experiment is compiled only into Debug app/test targets and uses the independent Xiph libopus 1.6.1 static archive. The local Debug build expects Homebrew `opus` under `/opt/homebrew/opt/opus`; set the Xcode build setting `OPUS_PREFIX` to use a different SDK location. The packaged Debug binary contains the decoder and does not require Homebrew at runtime. See [Opus notices](Opus-LICENSE.txt). The fixture was generated with FFmpeg’s 440 Hz sine source at 48 kHz for 0.35 seconds and encoded to Opus stereo at 32 kbit/s with 20 ms frames. Only generated audio data is embedded. The RTP parser and bounded window are original Swift based on [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) and [RFC 7587](https://www.rfc-editor.org/rfc/rfc7587). No Roam files, source code, authentication material, or binary dependency are in the build. The Release target has no Opus linkage and no diagnostic entry point.

The public ECP documentation still supplies no authorized WebSocket challenge-response method for this mode. Therefore there is no live negotiation, keepalive, UDP reception, TV audio restoration, or experimental Settings UI in this phase. Recovery from packet loss, route changes during a live stream, and real Roku session lifecycle remain unverified. The diagnostic accepts only the embedded fixture and has no network code.

### Manual Debug diagnostic

In Terminal, use the packaged Debug executable, not the Release app. Run:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-tone 25
```

The optional final number sets and saves playback volume from 0 to 100. Omit it to use your last diagnostic volume. Listen for a short tone on the selected Mac output. It stops automatically. To test another output, select it in macOS Sound settings and rerun. If it fails, copy the Terminal error and note your macOS version and chosen output. No step connects to TCL or verifies Roku Private Listening.

## Phase 1.5.2 research log and results

- **Confirmed by Roku documentation.** The public [External Control Protocol reference](https://developer.roku.com/dev/docs/external-control-api) documents local HTTP ECP. The [Headphone Mode support page](https://support.roku.com/en-us/article/how-to-resolve-an-issue-with-headphone-mode) documents the mobile app and supported hardware paths. Neither source supplies a third-party WebSocket enrollment process, an authorized challenge-response specification, or the listening command interface. Availability in another application demonstrates device capability, but does not establish authorization for Ukor Visor.
- **Prior source observation, not a wire observation.** The pinned Roam source review above identified a WebSocket upgrade, a server challenge followed by an authentication response, a separate audio-output request, and RTP/RTCP. Its ports, request fields, acknowledgments, keepalive cadence and shutdown behavior are implementation observations only. No packet capture or Roku connection was made in either this phase or the prior investigation.
- **Confirmed by standards.** [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) defines RTP framing, sequencing, and padding. [RFC 7587](https://www.rfc-editor.org/rfc/rfc7587) specifies dynamic RTP payload types and a 48 kHz timestamp clock for Opus, independent of decoder output rate. One standard RTP payload carries one Opus packet, which may contain multiple Opus frames. The parser hands the entire payload to libopus.
- **Unverified.** Whether a Roku-supported third-party registration or identity exists, how authorization is scoped to devices or applications, whether firmware variants differ, and which timing, negotiation, keepalive, and shutdown values Ukor Visor would need. No successful authentication, rejection status, packets from Roku, or audible live audio were observed.
- **Implemented independently.** Debug now runs incoming synthetic datagrams through a one-source RTP/Opus pipeline with a bounded sequence window. It rejects malformed framing and unexpected identifiers, drops duplicates, waits for reordered packets, and can use Opus loss concealment when the caller explicitly expires a gap. Concealment uses the last decoded duration and requires a future packet; this is a bounded prototype policy, not a measured Roku playout strategy. libopus supports mono/stereo output at 8, 12, 16, 24, or 48 kHz, tested with synthetic 24 kHz mono and 48 kHz stereo. There is no production feature flag or linked Opus dependency. No Roam code or credentials were incorporated and no licensing agreement is assumed.
- **Still blocked.** Roku session establishment and negotiation, WebSocket integration tests, live UDP socket lifecycle, a continuous playout clock, and live shutdown/restoration remain deferred. Phase 1.5.1’s short AVAudioEngine diagnostic is available for manual Mac output testing. Tests verify decoded PCM, file output and validation-failure cleanup, not a hardware route.

### Optional manual socket metadata check

This observes socket metadata for an already-running session you are authorized to inspect. It does not open connections, capture packets, follow another process, or save media. Start and stop the known-working listening session yourself if you choose. Obtain its PID from Activity Monitor, then run the following in Terminal before, during and after the session, replacing the two example values. It records TCP connection states and UDP endpoints associated with the chosen process where available. An unconnected UDP socket or an empty result cannot establish which host sent audio.

```sh
LISTENING_PID=12345
ROKU_IP=192.0.2.25
umask 077
LOG="$HOME/roku-listening-endpoints.log"
{
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  /usr/sbin/lsof -nP -a -p "$LISTENING_PID" -i |
    awk -v tv="$ROKU_IP" '
      index($0, "->" tv ":") || ($8 == "UDP" && $9 !~ /->/) {
        n = split($9, endpoints, "->")
        sub(/^.*:/, "LOCAL:", endpoints[1])
        if (n > 1) sub(/^.*:/, "ROKU:", endpoints[2])
        print $8, endpoints[1], endpoints[2], $10
      }'
} >> "$LOG"
```

The result uses endpoint aliases and contains no message bodies, challenge values, credentials, or media. It is a reachability and troubleshooting aid. It cannot establish authentication, Opus decoding, or actual playback.

### Phase 1.5.2 local test

Select an output in **System Settings → Sound → Output**, then run:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-tone 25
```

The synthetic tone stops automatically. Note the Terminal result and whether you heard the tone; if it fails, record the selected output and error. To test Bluetooth or wired output, select it first and rerun. There is no valid TCL start/stop procedure for the current build. A future authorized test must independently confirm authentication accepted, matching RTP arrived, PCM decoded, sound was audible, and stopping restored normal TV audio.

## Phase 1.5.3 Android-to-TCL diagnostic

### Method selection

| Method | What it can establish | Decision |
| --- | --- | --- |
| Android local VPN capture | Observes traffic at the phone, including eligible same-LAN flows routed through the VPN. Provides app identity, endpoints, transport, byte/packet counts, and timing where exposed. | First choice. PCAPdroid publishes its source and performs capture locally without root or a remote VPN server. VPN routing may change device discovery or playback. Verify Headphone Mode still works while capture runs. |
| Mac passive capture | A normal Wi-Fi interface generally sees the Mac’s own traffic, plus broadcast/multicast. Monitor-mode visibility depends on adapter support, channel, and link encryption. | Skip on the existing network. Being on the same Wi-Fi is insufficient. The prior Mac socket snapshot applies to Mac apps only, not the Android session. |
| Android developer tools | Android’s Network Inspector targets inspectable apps and only supports certain HTTP libraries. A normal ADB connection does not make a retail app’s private socket traffic available. | Skip. No rooting, repackaging, or modifying the official app. |
| Router/AP monitoring | A LAN/AP capture or mirroring feature can observe the pair if it actually traverses the observed interface. WAN statistics and device lists do not show local phone-to-TV streams. | Fallback if the exact gateway/AP model documents LAN bridge or wireless capture. The available T-Mobile gateway help did not establish that capability for the user’s gateway. |
| Explicit proxy | Can observe connections the app elects to send through it. Direct local sockets, UDP, and encrypted protocol contents may be invisible. | Skip for this experiment. No trust changes, interception CA, or pinning bypass. |

Sources: [PCAPdroid project](https://github.com/emanuele-f/PCAPdroid), [VPN capture limitations](https://emanuele-f.github.io/PCAPdroid/faq.html), [Android VPN](https://developer.android.com/develop/connectivity/vpn), [Android Network Inspector](https://developer.android.com/studio/debug/network-profiler), [Wireshark WLAN capture](https://wiki.wireshark.org/CaptureSetup/WLAN), [T-Mobile gateway support](https://www.t-mobile.com/support/home-internet).

### Run a short metadata-only comparison on the phone

1. On the TCL, open **Settings → Network → About** and privately note the current TV IP. Confirm the phone and TV are on the same Wi-Fi. Choose a non-sensitive Roku clip and keep it playing at the same point in the setup for both runs. Confirm **Remote → headphones icon** works in the official Roku app with no capture, then turn Headphone Mode off. Keep the same TV selected so discovery is not required to repeat the test.
2. If you choose to install a capture tool, follow the Play Store link from the [official PCAPdroid project](https://github.com/emanuele-f/PCAPdroid). Android allows one active VPN per user. If you use a VPN that you do not want to interrupt, skip this method and check the router/AP option. Otherwise note which VPN to restore when finished. This experiment requires neither root nor a certificate installation.
3. In PCAPdroid, choose **No dump**. Leave **Full payload**, TLS decryption, and any remote export or streaming option off. If your version exposes a capture-time app selector, choose the official **Roku** app only. A Connections-screen filter may merely hide other entries rather than exclude them from inspection. If your version has only a display filter, proceed only if you are comfortable with this distinction. Close unrelated apps and keep the run short. Record only Roku-app entries whose remote IP matches the TCL.
4. Tap PCAPdroid’s start control and approve Android’s local VPN prompt. Note elapsed time as **00:00**. Open the Roku app and use the previously selected TV. With Headphone Mode off, wait about **10 seconds**. Mark the baseline and note any existing TCP/UDP rows and their counters.
5. Tap the Roku app’s **headphones icon**, note the elapsed time, and confirm sound actually moves to the phone. Let it play for **20 seconds**. While active, check the matching rows in PCAPdroid. Note if opening PCAPdroid interrupts audio or changes session behavior. If playback fails only with capture enabled, record that result, stop the capture, and restore the ordinary configuration. A failed run does not characterize working traffic.
6. Tap the headphones icon again, record the elapsed time and whether sound returns to the TV. Wait about **10 seconds**, note endpoint/counter changes, then stop PCAPdroid. Review retained connection rows if switching apps during playback was disruptive. Close the diagnostic app, discard its session data when finished, and restore the phone’s previous VPN if you paused it. Repeat once if the first run worked and you want to distinguish repeatable behavior from incidental traffic.
7. Keep a plain-text record locally. Use aliases `PHONE` and `TCL` in place of addresses. Omit screenshots, payloads, device names, SSIDs, account identifiers and connection details containing secrets. No packet file is needed.

Copy this line once per matching connection in each phase:

```text
phase | elapsed | TCP/UDP | PHONE port | TCL port | opened/reused/closed/unknown | sent packets/bytes | received packets/bytes | audio route
```

Prefer counter deltas between snapshots of the same connection. If packet counts are shown, divide the count delta by the elapsed seconds for an approximate packet rate. Divide byte delta by packet delta for an approximate size, taking the app’s byte-counting convention into account. These are averages, not per-packet size distributions. If you only have cumulative counters or missed the first packets, mark cadence, setup and initiator **unknown**. Signs worth recording include UDP receive counters that rise only during successful listening, quiet control traffic that persists during playback, and which rows remain after stopping. TCP may be reused across all phases. A new row or a familiar port alone does not establish WebSocket, authentication, keepalive, or shutdown semantics. Record an upgrade only if the tool independently identifies it without exposing payload.

### Evidence and implementation gate

- **Verified by Lee:** Official Android Headphone Mode and Roam play audio from this TCL. The Phase 1.5.2 synthetic test produced 17,280 frames that Lee heard on the Mac.
- **Unverified:** All Android experiment observations, including endpoint roles, initiation, authentication, framing, and session lifecycle. This phase did not run a capture or contact the TCL.
- **Encrypted traffic:** Endpoints, directions, counters and timing can remain observable. They do not establish how a challenge is answered, whether credentials are device- or application-specific, or whether another client may use the session. Even a readable upgrade does not establish authorization. This workflow does not inspect message bodies.
- **Next decision:** Compare two successful runs to identify stable versus incidental flows and the effect of the local VPN. Use those observations to scope transport testing and ask Roku whether it provides a documented third-party enrollment and authorization path for Headphone Mode. Roku documents the official app path and HTTP ECP separately. Neither document establishes an audio session authorization method for Ukor Visor. A confirmed endpoint can guide transport tests, but a supported authorization path and a successful session using Ukor Visor’s own identity are still required before implementing or claiming live listening.

Sources: [Roku Headphone Mode](https://support.roku.com/en-us/article/how-to-resolve-an-issue-with-headphone-mode), [Roku public ECP](https://developer.roku.com/dev/docs/external-control-api).

## Phase 1.5.4 Roam on macOS

The tester reported that Android Headphone Mode became silent while the PCAPdroid VPN was active. That run does not establish successful-session traffic. Use Roam on the Mac, where Lee has already heard TCL audio through Private Listening. This workflow does not interact with Roam or the TV. The script is outside both app build targets.

### Mode A — Roam socket snapshots

1. Start Roam manually and select your TCL. Leave Private Listening off. On the TV, use **Settings → Network → About** to find its IPv4 address. Verify both are on the same LAN.
2. In Terminal, paste this block. Enter only the TCL address at the prompt. Use the standard Python 3 available with Xcode or the macOS Command Line Tools.

   ```sh
   printf 'TCL IPv4 address: '; read -r TV
   TOOL="Tools/roam-listening.py"
   /usr/bin/python3 "$TOOL" sockets "$TV"
   ```

3. Wait **10 seconds**. Enable Private Listening in Roam yourself and immediately type `on` and press Return in Terminal. The marker records when Terminal received your input, so note any delay between switching apps and entering it.
4. Confirm you hear the TV through the Mac. Continue for **20 seconds**. In Roam, disable listening and immediately enter `off` in Terminal. Note whether audio returned to the TV.
5. Wait **10 seconds**. Enter `q` or press **Control-C**. The script also stops after about three minutes. Copy the log from the path printed by Terminal. It is a private TSV file in your home directory. If the run was silent, label it as a failed listening run when sharing the log.

This uses process-scoped numeric `lsof` snapshots roughly once per second and needs no sudo. Logs contain UTC timestamps, monotonic elapsed seconds, the Roam PID, protocol, ports, and available TCP state. All addresses are omitted. `TCL` identifies the supplied remote address, `UNCONNECTED` indicates a UDP socket with no kernel-reported peer, and `OTHER` is a collapsed category with no endpoint details. `PRESENT`, `APPEARED` and `DISAPPEARED` describe differences between snapshots; a state change can appear as a removed row and a new row. Brief connections may be missed. When a sample fails, the next successful snapshot compares with the last good one. A bound UDP socket cannot show packets, an unconnected peer, or idle vs. active byte counts. Per-flow counters from other tools such as `nettop` may vary by transport and macOS version and are not required here.

### Mode B — Optional terse packet metadata, separately initiated

Use only if Mode A cannot distinguish when UDP traffic starts and stops. This reads the Mac’s own traffic with the TCL, rather than passively observing another device. The built-in `tcpdump` needs elevated privileges to open the capture interface. Run the command yourself and enter any password only at the system `sudo` prompt. There is no packet-file export. Terse output is parsed locally and only numeric time, direction, transport, ports and printed lengths are saved. Capture is restricted at the interface to the named Mac/TCL IPv4 pair and TCP/UDP. The output cannot reliably attribute a packet to Roam, so avoid using other Mac apps to control the TV during this run.

In a second Terminal tab, repeat the address prompt and start this only when ready. Keep Mode A running in the first tab if you want markers on the same UTC clock.

```sh
printf 'TCL IPv4 address: '; read -r TV
TOOL="Tools/roam-listening.py"
if /usr/bin/python3 -c 'import ipaddress, sys; ipaddress.IPv4Address(sys.argv[1])' "$TV"; then
  IFACE=$(/sbin/route -n get "$TV" | awk '/interface:/{print $2; exit}')
  MAC_IP=$(/usr/sbin/ipconfig getifaddr "$IFACE")
  if [ -n "$IFACE" ] && [ -n "$MAC_IP" ]; then
    sudo /usr/sbin/tcpdump -i "$IFACE" -p -nn -tt -q -l -s 96 -c 10000 \
      "ip and host $TV and host $MAC_IP and (tcp or udp)" |
      /usr/bin/python3 "$TOOL" packet-summary "$TV"
  else
    printf 'No IPv4 address found on the route interface. Stop here.\n'
  fi
fi
```

Repeat the 10/20/10-second sequence. Press **Control-C** in the packet Terminal tab after the final wait. It stops automatically at 10,000 matching packets if you reach that limit first. The packet sampler drops unexpected output formats and never saves an unparsed line. Printed lengths depend on tcpdump’s transport summary and are not encoded frame lengths or full link-layer sizes. There is no TLS decryption. The capture command reads packet headers and some bytes transiently within its snapshot length, but does not print or write payloads.

### Compare the logs

Use the baseline `PRESENT` entries first, then compare appearances and disappearances around both markers. Retained TCP connections may carry setup, remote commands, and other traffic. A port number cannot establish WebSocket use. Sustained TCL-to-Mac UDP that rises and falls with audible listening is a media candidate; occasional packets during silence may be control or keepalive candidates. Compare directions, rates and lengths between phases before assigning a role. Report `OTHER` endpoint changes separately and treat them as unknown. Share only the redacted text logs and tell us if you heard audio and whether it returned to the TV. We can then report which flows are repeatable and which are hypotheses. This cannot establish authentication, credentials, session authorization, or permission to reproduce Roam’s behavior.

Sources: [macOS packet tracing](https://developer.apple.com/documentation/Network/recording-a-packet-trace), [lsof socket visibility](https://github.com/lsof-org/lsof/blob/master/docs/faq.md).

## Phase 1.5.5 — Debug UDP receiver

The redacted packet summary from one successful Roam/TCL session contained 2,668 TCL-to-Mac UDP packets on 36129 → 6970, 24 in the opposite direction on 6970 → 5150, and two TCL-to-Mac on 39310 → 6971. TCP port 8060 was also visible. Sustained traffic to 6970 makes it a strong audio candidate for that run. Metadata does not verify packet framing, codec, authorization, or a universal port assignment.

The Debug receiver binds exclusively to IPv4 loopback with no reuse flags. Port 6970 is the default and port 0 is an OS-assigned free port. It sends no data in receive-only mode. The separate fixture mode sends generated RTP/Opus solely to the socket it owns. The receiver is bounded by the kernel socket buffer, a 24-packet reorder window and an eight-buffer playback cap. It validates RTP v2 header lengths, padding, payload type, SSRC, sequence window and playout timestamp continuity using the 48 kHz RTP clock. This proof of concept uses an 80 ms initial buffer, a synthetic fixed PT 96/SSRC 1, and previous-frame Opus concealment when an expired gap precedes buffered packets. It is not a general adaptive jitter buffer or a live Roku client.

The end-of-run log includes received packets and average rate, accepted/rejected packets, buffered duplicates, concealed gaps, estimated arrival jitter, decoded frames, underrun ticks and output queue drops. Packets that arrive after playout are counted as rejected outside the reorder window. The jitter estimate is based on user-space receive times and is approximate. Output errors are printed separately. The app uses the default Mac output and the existing independent experimental volume. No packet payloads are logged. Normal deadlines and Control-C stop playback and close the socket.

### Next manual test

Select your playback device in **System Settings → Sound → Output**. Paste into Terminal:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-udp-fixture 0 5
```

Expect about five seconds of repeating synthetic tone and a summary with nonzero UDP and PCM frame counts. Use Control-C to stop early. To check the no-sender case, use `--experimental-listening-udp 0 3` instead. It should stay silent and show zero received packets. Port 0 avoids competing with Roam. For an explicit bind check use port 6970 instead of 0. A binding conflict should report an error and leave the existing owner alone. Share only the summary, any error and whether you heard the synthetic sound.

Automated tests exercise real loopback UDP, collision, release, rebind, RTP validation and decoding. Audible continuous playback and route selection for this new command require the manual test. No LAN bind, control/authentication traffic, or live TCL playback is part of this phase.

### Phase 1.5.5.1 playback regression

The tester reported that the UDP fixture decoded frames but was silent on the same output that played the single-buffer tone. The paths used the same engine and mixer configuration. The UDP path, however, started with one short buffer, paced each subsequent submission after the current tick (accumulating scheduling drift), blocked the main run loop between ticks, and stopped the engine at the receiver deadline without checking completion. Its decoded-frame counter measured none of those output stages. These are confirmed defects in playback scheduling and observability. The old run did not establish which defect caused the complete silence on the test Mac.

The Debug command now starts after four queued buffers, uses an anchored playout clock with bounded catch-up, services the main run loop, and drains remaining scheduled audio before stopping on a deadline or Control-C. The drain has a two-second cap and reports timeout or a stopped output. The original short-tone path is unchanged. The new summary reports submitted frames, scheduled buffers, data-played-back callbacks, pending counts before and after drain, engine/player state before shutdown, volume, and errors. Callback counts are not proof of audible speaker output.

Run the same five-second fixture from the updated build:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-udp-fixture 0 5
```

Share whether you heard the tone and the `Audio:` line. The regression test checks bounded submission, completion accounting and isolation across tracker restarts. The existing loopback test checks UDP-to-PCM; neither test exercises physical output.

## Phase 1.5.6 — Inbound RTP header inspection

The tester confirmed hearing the repaired synthetic UDP fixture through Mac speakers. The next test examines the candidate audio flow from a manually started, audible Roam session. It does not start a session, send packets, inspect outbound UDP, or collect TCP/WebSocket traffic.

1. In Roam, manually start Private Listening on the TCL and confirm sound is playing through the Mac. Find the TCL IPv4 address under **Settings → Network → About**.
2. With audio still playing, paste this into Terminal. The system `sudo` prompt grants tcpdump access to the packet interface. Enter any password only at that prompt. Python runs as your normal user.

   ```sh
   printf 'TCL IPv4 address: '; read -r TV
   TOOL="Tools/roku-rtp-format.py"
   REPORT="$HOME/roku-rtp-$(date +%Y%m%d-%H%M%S).json"
   sudo -v && /usr/bin/python3 "$TOOL" capture "$TV" "$REPORT"
   ```

3. Keep listening until Terminal returns, then stop listening manually in Roam. Run the offline analysis in the same Terminal tab:

   ```sh
   /usr/bin/python3 "$TOOL" analyze "$REPORT"
   ```

   Paste the printed report and say whether the audio stayed audible. If the count is zero, check the route, current TV IP and whether Roam was playing during the window.

The capture is limited to 12 seconds of sampling or 1,200 IPv4 UDP packets from the exact TCL address to the Mac route address on destination port 6970. Shutdown can take a few additional seconds. Ethernet-format capture uses a 58-byte snap length, which allows up to 16 bytes of UDP data with standard IPv4 headers, enough to look for a fixed RTP header at offsets zero through four. On devices or routes without Ethernet-format capture, stop rather than broadening the filter. IPv4 options or truncated headers can reduce visibility, and streams on other ports, VLAN framing, fragmentation, or prefixes longer than four bytes are outside this test.

Raw packet bytes pass through a local pipe into memory only. The saved JSON contains numeric header-derived fields, source ports, lengths and the first-byte classification value. It contains no IP addresses or raw packet/file dumps. Extension bits can be counted; full extension bodies and padding contents are outside the capture. The offline report compares sequence continuity, including wraparound, timestamp deltas, candidate offsets, and SSRC group consistency without printing SSRC values or packet payloads. A strong candidate requires at least 20 packets with at least 90% adjacent sequences and 90% consistent positive timestamp deltas among those adjacent pairs. This is a heuristic, so misses and false candidates are possible. A delta of 480 is compatible with 10 ms at the Opus RTP clock rate, but dynamic payload type, size, and cadence do not identify the codec. Even strong RTP evidence leaves codec, exact decoder configuration, and authentication unverified.

References: [Apple packet traces](https://developer.apple.com/documentation/network/recording-a-packet-trace), [RTP RFC 3550](https://www.rfc-editor.org/rfc/rfc3550.html), [Opus RTP RFC 7587](https://www.rfc-editor.org/rfc/rfc7587.html).

## Phase 1.5.7 — Arrival clock and opt-in Opus probe

The Phase 1.5.6 file contains 1,101 offset-zero RTP v2/PT 97 packets with one SSRC and 1,100 adjacent sequence transitions. Timestamp steps range from 6 to 14 and average exactly 10 ticks; 981 of 1,100 are 9–12. That format did not save arrival times. Independently, the earlier 2,668-packet Roam flow to UDP 6970 averaged 10.001 ms between arrivals (9.949 ms median). These are two sessions, so they support approximately one tick per millisecond but do not pair each timestamp step with its arrival interval. A sender time counter quantized in milliseconds, possibly reflecting variable send timing, is plausible. Its exact meaning cannot be distinguished from this evidence. At the [standard 48 kHz Opus RTP clock](https://www.rfc-editor.org/rfc/rfc7587.html), a 10 ms packet would advance 480 ticks, not 10. A nonstandard timestamp clock can coexist with valid Opus payloads.

Ordinary header capture now records per-packet arrival timestamps without changing its 58-byte snapshot. The report pairs arrivals with adjacent RTP sequences and estimates ticks per real second over the aggregate. Older header files still work and show no paired arrival estimate. This estimates rate against the Mac capture clock, not sender intent, and individual arrivals can jitter.

Opt-in `--probe-opus` expands the snapshot only on the selected inbound TV-to-Mac UDP 6970 flow, up to 2,048 bytes of UDP data with supported IPv4 headers. The same 12-second/1,200-packet bounds apply. Raw bytes are processed in memory and are never written by the tool. It validates complete unprefixed RTP v2/PT 97 packets, checks CSRC/extension/padding boundaries, and uses one source-port/SSRC pair. Duplicates and late packets are skipped. The separately installed Homebrew libopus dylib is the same decoder family used by the Debug app. The probe creates a 48 kHz stereo decoder, counts successfully decoded frames and packet-signaled channels, and zeros its PCM scratch buffer after each call. There is no sound output, media export, signaling inspection, or change to the app. Strong compatibility requires at least 100 decoded packets, at least 98% success among attempts, at least 90% coverage of captured packets, and coherent RTP evidence. This supports decoder acceptance, not audio fidelity, authentication, or live readiness.

Even if libopus accepts the real payloads, the existing Debug fixture receiver expects PT 96/SSRC 1 and a 48 kHz RTP timestamp progression. The observed PT 97 and steps around 10 mean it cannot accept the stream unchanged. This phase leaves that receiver alone.

### Manual compatibility run

Manually start audible Private Listening in Roam. Then paste:

```sh
printf 'TCL IPv4 address: '; read -r TV
TOOL="Tools/roku-rtp-format.py"
REPORT="$HOME/roku-rtp-opus-$(date +%Y%m%d-%H%M%S).json"
sudo -v && /usr/bin/python3 "$TOOL" capture "$TV" "$REPORT" --probe-opus &&
  /usr/bin/python3 "$TOOL" analyze "$REPORT"
```

The system sudo prompt grants packet-interface access only to tcpdump. The existing Homebrew libopus must be at `/opt/homebrew/opt/opus/lib/libopus.0.dylib`. Keep Roam playing until the command returns, then stop it manually. Share the printed `paired_arrival_timing` and `opus_probe` sections and whether Roam stayed audible. Omit `--probe-opus` to measure timing without asking the tool to decode the payload.

## Phase 1.5.8 — TCL timing compatibility profile

The saved probe report shows 1,101 successful libopus decodes, all 10 ms stereo, with 528,480 PCM frames per channel. For the primary RTP flow, 1,100 paired arrivals averaged 9.998 ms and estimated 1,000.0 RTP ticks/second. The report's generic fixed-step heuristic labels this flow inconclusive because the timestamp steps vary. The sustained decode results and the consecutive sequence numbers are the pertinent compatibility evidence.

The original fixture keeps PT 96 and its 48 kHz RTP timestamp clock. The separate TCL fixture uses PT 97 and a 1 kHz RTP clock. The pipeline pins the first SSRC, accepts positive wrap-safe TCL timestamp steps up to one second, and uses actual decoded frame counts for pacing. Timestamp variation does not drive PCM duration. The local fixture uses generated 10 ms stereo Opus, independent of the capture. It does not assume a remote source port. Existing bounded queue, prefill, callback accounting and drain behavior are shared between profiles.

With your Mac speakers selected, paste into Terminal:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-udp-tcl-fixture 0 5
```

Expect about five seconds of synthetic tone and a loopback banner showing PT 97 and 1000 Hz. Port 0 selects a free local port. At the end, check for roughly 100 UDP packets per second, decoded and submitted PCM, callbacks, pending buffers draining to zero, and any output errors. The ordinary `--experimental-listening-udp-fixture 0 5` command continues to use PT 96. Neither command starts a Roku session or accepts traffic from the TV.

## Phase 1.5.9 — Independent session authorization gate

**Decision:** An independently implementable, Roku-supported Headphone Mode session for a third-party macOS client could not be verified. The qualified result is format compatibility, not session compatibility. Keep the current Debug profiles and production behavior as-is.

### Evidence by source

- **Roku developer documentation:** Public ECP covers SSDP discovery and HTTP commands on port 8060. Its Roku OS 14.1 notes name `query/audio-device` among commands gated by **Control by mobile apps → Enabled**. Even if an authorized client can query audio capability, the public reference does not specify how to activate Headphone Mode or register an audio destination. It does not document `/ecp-session`, a third-party enrollment handshake, token issuance, expiry, or revocation. Roku's developer reference also warns against sending ECP from third-party platforms, while Roku Support describes third-party control settings. The documentation does not resolve how those statements apply to an independently distributed macOS client or confer Headphone Mode access. [ECP reference](https://developer.roku.com/dev/docs/external-control-api) · [Roku mobile app and control settings](https://support.roku.com/article/install-the-mobile-app).
- **Roku consumer documentation:** The official mobile app connects on the local network and toggles Headphone Mode in its Remote screen on supported devices. Roku also documents separate remote-headphone and supported Bluetooth paths. These are user-facing capabilities, not a third-party client pairing specification. Enabling local control, linking a Roku account, or enrolling in the channel development program does not establish access to this streaming interface. [Mobile Headphone Mode](https://support.roku.com/article/use-headphones-with-the-mobile-app-for-headphone-mode) · [Headphone Mode support and device limitations](https://support.roku.com/article/how-to-resolve-an-issue-with-headphone-mode) · [Developer setup](https://developer.roku.com/develop/getting-started/setup-guide).
- **Third-party implementation observation:** Roam's published notes and the pinned review above indicate a WebSocket control session with a challenge before audio setup, a destination request, and UDP control exchanges around streaming. Those observations do not establish the authorized challenge response for a new client, whether Roku issues any credential to external developers, or the mandatory message and timer requirements. No authentication data was inspected in this phase. [Roam audio protocol notes at reviewed revision](https://github.com/msdrigg/roam/blob/d44ef781ce825c785040ac68b1dceb3e18c84b23/Roam/AudioPlayer/audio-protocol.md).
- **Owner observations:** Roam played TV sound while the TCL sent PT 97 RTP to Mac UDP port 6970; an earlier run also showed traffic involving port 6971 and outgoing UDP to TV port 5150. TCP 8060 activity establishes a port, not WebSocket upgrade or authorization. The inbound flow yielded 1,101 successful Opus decodes; roughly 1 kHz RTP timing and 10 ms stereo packets describe this TV and session only. The owner also heard the independent synthetic PT 97 fixture play on the Mac (492 accepted packets, 482 completion callbacks, no underrun ticks or playback error, two output queue drops). Neither observation establishes audio negotiated or received live by Ukor Visor.

### Conditional client architecture

| Component | Reusable now | Required before implementing a live client |
| --- | --- | --- |
| Discovery and capability | Existing native device discovery and remote device selection in `Discovery.swift` and `Roku.swift`. | Supported Headphone Mode capability check, model/firmware scope and applicable API permission. |
| Establish and authorize | No existing authorized Headphone Mode session client. | Roku-confirmed endpoint, permitted client identity, pairing or registration steps, credential delivery, session lifecycle and explicit errors. |
| Configure destination | Existing loopback-only diagnostic proves local datagram handling. | Supported request schema, address and port policy, acknowledgments, protocol negotiation and failure semantics. No hardcoded capture port or TV source port as a production assumption. |
| Receive and play | Experimental RTP parsing, bounded reorder buffer, Opus decoding, PT 97 timing profile, and AVAudioEngine pipeline in `ExperimentalListening.swift`. | Review authorization-scoped socket binding and validate negotiated parameters. Manual live audio validation remains a separate step. |
| Control traffic and health | Existing playback counters, decoder errors and bounded diagnostic shutdown. | Official endpoint/transport separation, documented heartbeat and timeout, plus a confirmed control exchange if RTCP or another mechanism is required. Observed periodic traffic does not establish a keepalive requirement. |
| Terminate | Local socket cleanup and bounded audio drain in the experimental pipeline. | Supported stop/release procedure, expected acknowledgment or expiry, and verification that the TV restores its prior output on stop and failure. |

When a supported flow is available, start with a Debug-only client state machine backed by synthetic vendor-documented messages. Test denied authorization, one bounded startup timeout, missing media and stop-after-partial-setup before a separately authorized live test. Do not implement the production UI or change existing remote behavior in that phase.

### Smallest next investigation

Ask Roku for its supported third-party Headphone Mode path through its [official contact page](https://www.roku.com/about/contact), which lists product support and Partner Success. The question to send is:

> Does Roku offer an authorized SDK or partner program for a third-party macOS app to initiate Headphone Mode on a user's TCL Roku TV? If so, what are the permitted client enrollment, capability, session setup, destination, keepalive, and stop interfaces, and may a macOS app distribute that integration? If it is not available to independent developers, please confirm.

A further short, user-started before/during/after run of the existing metadata diagnostics would only refine port and timing hypotheses for another model or reproducibility check. It cannot establish pairing rules, approval, credential lifecycle, command semantics, or authorized distribution. No follow-up capture is needed to progress the present authorization question. No request was sent to Roku and no TV diagnostics ran in this phase.

### Licensing

Roam's repository states PolyForm Noncommercial 1.0.0 and describes a written permission process for protocol code. An offer to grant permission is not a grant. Even written permission to reuse code would not by itself establish third-party access to Roku's streaming service. No Roam source, implementation, or assets were copied. The existing Debug libopus dependency retains its redistribution notices in [Opus-LICENSE.txt](Opus-LICENSE.txt). The [standard RTP specification](https://www.rfc-editor.org/rfc/rfc3550.html) and [Opus RTP specification](https://www.rfc-editor.org/rfc/rfc7587.html) explain media framing independently of Roku authorization. [Roam license and permission terms](https://github.com/msdrigg/roam#license).

## Phase 1.5.10 — Session timeline

This standalone tool correlates a manually operated Roam session with transport headers. It observes traffic for the exact Mac/TCL IPv4 pair, not an application process. Close other apps that control the TCL during the run. Keep Roam connected with Private Listening off before beginning. Find the TV address under **Settings → Network → About**.

Paste this command into one Terminal window:

```sh
sudo -v && /usr/bin/python3 "Tools/roku-session-timeline.py"
```

1. Enter any administrator password only at the system sudo prompt, then supply the TV IPv4 address when asked.
2. Leave Private Listening off for 8 seconds. Turn it on manually in Roam, then immediately enter `on` in Terminal. When you hear the TV on the Mac, enter `heard`.
3. After roughly 15 seconds of playback, turn it off manually in Roam and immediately enter `off`. If the audio comes back on the TV, enter `tv`.
4. The tool ends after roughly 8 seconds of post-stop traffic. You can enter `q` or press Control-C sooner. The overall capture limit is 45 seconds or 8,000 matching packets, plus shutdown time. The private report is written to `~/roku-session-YYYYMMDD-HHMMSS-ffffff.json`. Terminal prints the exact path and a readable timeline. Send the JSON if you want the runs compared. Repeat the same steps for a second run if you want to check reproducibility.

The tool uses macOS tcpdump with a non-promiscuous, exact-endpoint filter for TCP and UDP. Only tcpdump needs sudo to open the capture interface. It uses a 54-byte Ethernet snapshot. That may contain up to 12 UDP payload bytes transiently in the local pipe; the parser never reads those bytes or saves a raw capture. The JSON contains aliased directions, ports, relative timestamps, TCP SYN/SYN-ACK/FIN/RST flags, IPv4 length summaries, per-stage counts, and heuristic periodic-flow candidates. It saves no addresses, payloads, credentials, or audio. It skips fragmented IPv4 packets and packets whose headers exceed the snapshot; it requires Ethernet-format capture on the routed interface.

Read the TCP flags and first/last observed UDP timestamps alongside the markers. Terminal markers reflect when Return was pressed, not the exact Roam UI event. A negative time since a marker is possible. TCP traffic across stages can be consistent with an already-open connection; unseen SYN or FIN does not establish that a connection was never opened or closed. The report does not identify the final TCP handshake ACK, authoritative socket state, or a UDP close event. The historical inbound port 6970 is labeled an audio candidate based on prior evidence. Periodic traffic is a candidate, and port numbers and cadence cannot identify control messages, WebSocket upgrades, authorization, or keepalives.

If two runs show stable ordering, use it to refine the startup/teardown state machine and timeout estimates for a future supported interface. Discovery and public HTTP ECP operations are already scoped in Phase 1.5.9. This diagnostic does not establish authorized enrollment, credential lifecycle, destination request/acknowledgment semantics, heartbeat requirements, or a supported stop command. Those still require Roku-supported documentation and separate live authorization.

[Apple packet trace documentation](https://developer.apple.com/documentation/network/recording-a-packet-trace) · [Roku public ECP reference](https://developer.roku.com/dev/docs/external-control-api).

## Phase 1.5.11 — Active, unauthenticated connection probe

Close Roam before manually invoking this Debug-only command. Replace the final argument if the TV address changed:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-session-probe 192.0.2.25
```

The probe accepts private or link-local IPv4 addresses and starts without opening the Mac UI. It sends a documented HTTP device-info query on port 8060. If a Roku device-info response is validated, it makes one documented audio-device read and one standard WebSocket upgrade attempt on the experimental `/ecp-session` path. It uses a fresh session per step, disallows redirects, rejects authentication challenges without credentials, and has a three-second timeout per step. There are no application-level retries. Device names, serials, response bodies and WebSocket application frames are not printed. The audio response may advertise datagram support, which is a capability hint only.

The result shows the HTTP status if Foundation exposes it, the upgrade callback, a close code, a URLSession error number, or a timeout. Foundation does not always expose the HTTP status of a failed upgrade. This checks a standard upgrade without a proprietary subprotocol. A rejection describes this request and does not establish why Roku rejected it or whether the endpoint accepts a different authorized client. An accepted upgrade proves transport reachability only. The probe requests a normal close after an upgrade and cancels locally otherwise. It does not wait for peer acknowledgment or read or send WebSocket application messages. No listening session, RTP binding, or audio routing change is attempted because the authorized setup and teardown commands are still unverified.

Automated tests use synthetic result events and assert cleanup after acceptance, rejection, close and timeout. They do not exercise a real WebSocket handshake on the TCL. This phase did not run the manual command or modify either audio fixture.

## Phase 1.5.12 — ECP-2 subprotocol probe

The prior standard upgrade reportedly returned HTTP 400. This build makes one change to the request: it offers `ecp-2` through Foundation's WebSocket subprotocol API. It reports an accepted upgrade with ECP-2 selected, no subprotocol selected, or an unexpected selection. Failed upgrades still report the HTTP status when Foundation exposes it and otherwise report the close, timeout, or URLSession error.

The [community discussion](https://stackoverflow.com/questions/77616691/private-listening-session-on-roku-tv) and [roku-tui repository](https://github.com/sloanb/roku-tui) are research leads, not vendor authorization. The [RPListening repository](https://github.com/runz0rd/RPListening) could not be retrieved in this environment. No third-party code or authentication material was incorporated. A Roku-authorized use of the proposed shared authentication material or mobile origin was not established. Authorization, destination negotiation, feedback, and speaker restoration therefore remain unavailable. No origin representing another app or platform is asserted; the probe closes at transport negotiation and does not read or send application messages.

With Roam closed, manually run:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-session-probe 192.0.2.25
```

Share the `WebSocket (offered ecp-2):` line. Acceptance would distinguish the ECP-2 transport from the earlier plain upgrade. It would not establish an authenticated listening session.

## Phase 1.5.13 — Authentication challenge observation

The tester confirmed that the Phase 1.5.12 probe negotiated ECP-2 on the TCL and that the audio capability read advertised datagram support. The new Debug command skips the HTTP capability reads and performs one ECP-2 connection. After the server selects ECP-2, it reads at most the first application message, capped at 4 KiB within the existing three-second operation deadline. The community-described challenge envelope is treated as a hypothesis. A JSON notification named authenticate with a nonempty Base64 challenge is classified as present; malformed and unrelated messages have separate fixed descriptions. No raw messages or challenge values are logged. A valid envelope does not establish authorization. The probe sends no application messages and closes the WebSocket without requesting audio.

The public [Roku ECP reference](https://developer.roku.com/dev/docs/external-control-api) does not establish an authorization path for an independent Headphone Mode client. The [community discussion](https://stackoverflow.com/questions/77616691/private-listening-session-on-roku-tv) and [roku-tui repository](https://github.com/sloanb/roku-tui) are research leads. Prior attempts to retrieve [RPListening](https://github.com/runz0rd/RPListening) failed in this environment. No third-party implementation code or authentication material was incorporated. There is no verified credential or vendor-supported procedure for this independent client. The proposed audio destination fields, authenticated response semantics, receiver feedback, and speaker restoration procedure also remain unverified. No serializer or command for those operations was added.

With Roam closed, use the Debug build:

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-auth-probe 192.0.2.25
```

Share the single `ECP-2 challenge probe:` line. The output can show the challenge envelope, protocol selection failure, close, rejection, or timeout. It cannot show successful authentication because the command sends no authentication response. No TV audio recovery action is needed for this probe because it never requests a routing change.

## Phase 1.5.14 — Live implementation decision

The manual Phase 1.5.13 run confirmed ECP-2 selection and receipt of a challenge matching the observer's expected envelope. The observer sent no authentication response. No server rejection or acceptance of an authentication attempt, audio negotiation, or audio restoration was observed.

The missing prerequisite is a Roku-authorized client enrollment or authentication mechanism for an independently distributed macOS application. The public ECP reference covers HTTP operations and does not supply that mechanism. The cited community discussion and repository references do not independently establish that Roku permits this client to use the proposed shared authentication material. RPListening was inaccessible during this review; the roku-tui listing was available through search, but its direct repository fetch failed. No third-party source or credential was incorporated.

The other gaps are the authorized audio destination request and acknowledgment, control feedback semantics, and a verified stop/restore exchange. Prior port and traffic observations do not resolve those gaps. The existing audio engine remains available for a supported integration. This phase adds no application code or experimental command, so there is no new end-to-end test build. No TV traffic was sent and no application was launched.

The next action is a developer or Partner Success inquiry through [Roku's official contact page](https://www.roku.com/about/contact). Ask specifically for a supported third-party macOS Headphone Mode enrollment or SDK, the authorized client credential or pairing workflow, and documented start, feedback, and stop/restore operations for a TCL Roku TV. Further local captures or challenge probes are unnecessary to answer that question.

[Roku ECP reference](https://developer.roku.com/dev/docs/external-control-api) · [Community discussion](https://stackoverflow.com/questions/77616691/private-listening-session-on-roku-tv) · [RPListening](https://github.com/runz0rd/RPListening) · [roku-tui](https://github.com/sloanb/roku-tui)

## Phase 1.5.15 — Media and control fixture

Roam's published implementation at [d44ef781](https://github.com/msdrigg/Roam/tree/d44ef781ce825c785040ac68b1dceb3e18c84b23) starts receiver feedback after the TV acknowledges audio routing. Its control flow includes delay and client-version negotiation, periodic receiver reports, and best-effort session shutdown. These describe Roam's implementation. TCL acceptance, port requirements, and restoration behavior for Ukor Visor still require an authorized session. The authentication code uses shared application material, and no independent client credential or Roku enrollment path was verified. Roam is offered under PolyForm Noncommercial 1.0.0. Its README offers separate written permission for protocol code reuse. No Roam code or authentication material was incorporated.

The Debug-only media fixture uses the existing PT 97 synthetic RTP/Opus playback pipeline and independently generated [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) compound receiver reports and BYE on a separate loopback socket. It checks report reception, audio queue drain, and shutdown feedback. It uses ephemeral ports when given port zero. It does not implement Roku-specific RTCP extensions, authenticate to the TCL, or change TV audio routing.

```sh
experimentalPrivateListeningEnabled=1 "build/DerivedData/Build/Products/Debug/Ukor Visor.app/Contents/MacOS/Ukor Visor" --experimental-listening-media-fixture 0 5
```

The expected result is approximately five seconds of synthetic audio and a summary of RTP, PCM playback, RTCP reports, and BYE. An authorized ECP-2 authentication method for Ukor Visor is the prerequisite for implementing and validating a live session.

## Phase 1.5.20 — Debug session controller

The Devices settings include a Debug-only Private Listening control. The application does not install an authentication provider. Starting with a selected device reports that a provider is required before any TV connection is attempted.

A future authorized provider implements `RokuListeningAuthenticationProvider` and `RokuListeningConnection`. It opens the ECP connection, supplies the selected interface's local IPv4 address and remote RTCP port, authenticates with a TV-confirmed result, exchanges correlated request/reply dictionaries, and implements verified TV audio restoration. Each asynchronous operation must have a bounded timeout. The controller opens RTP and RTCP listeners after authentication, checks the routing reply, negotiates VDLY/XDLY and CVER/NCLI, starts receiver reports, and passes PT 97 RTP through the existing reorder window, Opus decoder, and audio output. It marks the stream as listening after the first playback completion callback.

The RTCP format and ordering were independently implemented from [Roam's audio protocol notes](https://github.com/msdrigg/Roam/blob/d44ef781ce825c785040ac68b1dceb3e18c84b23/Roam/AudioPlayer/audio-protocol.md). Local tests use an injected connection and loopback sockets. They do not confirm TV authentication, live transport compatibility, or a particular TV speaker restoration command. Live device testing remains pending an authorized provider.
