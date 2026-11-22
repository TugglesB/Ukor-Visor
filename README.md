# Ukor Visor

Public repository name: `Ukor-Visor`.

A native macOS Roku remote that unfolds around your MacBook’s camera notch. Use the notch or the TV icon in the menu bar to open the remote.

The gear on the right wing opens Settings, which are also available from the menu bar.

## Features

- Directional pad with hold-to-repeat, OK, Home, Back, and Options.
- Play/pause, rewind, and fast forward. Stop is disabled because Roku ECP has no universal Stop command.
- Power and volume on compatible Roku TVs. Standby power-on depends on network availability.
- Mac keyboard input for compatible Roku text fields. With the visor focused, type directly, use Return for OK, Delete for Backspace, and ⌘V to paste a single line.
- Customizable channel shortcuts, automatic IPv4 discovery, manual IP entry, and saved devices.
- Optional Launch at Login and support for macOS Reduce Motion.

## Screenshots

Screenshots pending. Capture the expanded visor on a notched MacBook, the expanded channel shortcut drawer, and Settings → Devices using a demo device. Crop out unrelated windows and redact device names and addresses before adding the images.

## Requirements and installation

- Apple Silicon Mac running macOS 14 or later. A built-in camera notch is optional because the menu bar also opens the visor.
- Xcode with macOS build tools. The Release configuration has no external build dependencies.
- A compatible Roku on the same local network.

From the repository root:

```sh
xcodebuild -project "Roku Visor.xcodeproj" -scheme "Ukor Visor" \
  -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData build
```

Open `build/DerivedData/Build/Products/Release/Ukor Visor.app`. This produces an ad-hoc-signed local build. Downloadable binaries are not currently published.

## Roku setup

1. Turn on your Roku and connect it to the same local network as the Mac.
2. If needed, enable **Control by mobile apps** under **Settings → System → Advanced system settings** on the Roku. The exact labels vary by Roku OS version.
3. Open the Mac menu bar’s TV icon and choose **Settings → Devices**. Allow local-network access if prompted.
4. Choose your Roku from discovered devices, or enter its IPv4 address manually. Find it on the Roku under **Settings → Network → About**.
5. Open the visor using the camera notch, the narrow strip below it, or **Open Ukor Visor** in the menu bar. Use the integrated shortcut drawer to launch saved channels. Manage shortcuts under **Settings → Shortcuts**.

[Official Roku ECP documentation](https://developer.roku.com/dev/docs/external-control-api)

## Experimental Private Listening

Private Listening is Debug-only. The session and audio pipeline are under development, and live audio still requires an authorized authentication provider. The Release build excludes the experiment. See [development notes](Docs/Private-Listening.md).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and testing, and [SECURITY.md](SECURITY.md) for reporting sensitive issues.

Ukor Visor’s original code is licensed under [Apache License 2.0](LICENSE). Third-party material carries its own terms. Scott Driggers’ separate permission applies specifically to the notch-based Ukor Visor and does not grant downstream reuse rights for his protocol implementation. See [third-party notices](Docs/Third-Party-Notices.md).

Thanks to Scott Driggers and [Roam](https://github.com/msdrigg/Roam) for the Private Listening protocol reference. Ukor Visor is an independent project.
