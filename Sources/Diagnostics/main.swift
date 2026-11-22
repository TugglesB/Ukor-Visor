import AppKit

// Query WindowServer through AppKit and exit without starting an application event loop.
_ = NSApplication.shared
let displays = NSScreen.screens.map(NotchDisplay.init(screen:))
print("Ukor Visor display diagnostics")
print("Frames are in global AppKit points with a bottom-left origin. No GUI is opened.")
if let selected = NotchDisplay.preferred(from: displays, mouse: NSEvent.mouseLocation) {
    if let builtIn = displays.first(where: \.builtIn), builtIn.displayID != selected.displayID {
        print("\nBuilt-in display")
        builtIn.diagnosticLines().forEach { print($0) }
    }
    print("\nVisor display")
    selected.diagnosticLines().forEach { print($0) }
} else {
    print("No display data is available in this session. Run this tool from Terminal on the MacBook desktop.")
    exit(1)
}
