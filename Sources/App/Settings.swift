import AppKit
import SwiftUI

struct VisorSettings: View {
    @ObservedObject var model: RokuModel
    @ObservedObject var navigation: SettingsNavigation
    let quit: () -> Void

    #if EXPERIMENTAL_LISTENING
    @ObservedObject var privateListening: RokuPrivateListening
    #endif

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                SettingsSidebarLabel(section: section, selected: navigation.selection == section)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(SettingsTheme.sidebar)
            .overlay(alignment: .trailing) {
                SettingsTheme.border.frame(width: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 210)
            .accessibilityLabel("Settings sections")
        } detail: {
            let page = navigation.selection ?? .devices
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(page.rawValue)
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Group {
                            switch page {
                            case .devices:
                                DeviceSettings(model: model)
                                #if EXPERIMENTAL_LISTENING
                                SettingsCard("Private Listening (Experimental)") {
                                    SettingsNote(privateListening.state.label)
                                    Button(privateListening.active ? "Stop Listening" : "Start Listening") {
                                        if privateListening.active { privateListening.stop() }
                                        else if let address = model.selected?.address { privateListening.start(address: address) }
                                    }
                                    .disabled(model.selected == nil && !privateListening.active)
                                }
                                #endif
                            case .shortcuts: ShortcutSettings(model: model, navigation: navigation, scroll: proxy)
                            case .appearance: appearance
                            case .controls: controls
                            case .about: about
                            }
                        }
                        .buttonStyle(SettingsButtonStyle())
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .id(page)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    SettingsDivider()
                    Button("Quit Ukor Visor", action: quit)
                        .buttonStyle(SettingsButtonStyle())
                        .accessibilityLabel("Quit Ukor Visor")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .background(SettingsTheme.background)
            }
            .scrollContentBackground(.hidden)
            .background(SettingsTheme.background)
        }
        .environment(\.colorScheme, .dark)
        .background { SettingsTheme.background.ignoresSafeArea() }
        .foregroundStyle(SettingsTheme.primaryText)
        .tint(SettingsTheme.accent)
    }

    private var appearance: some View {
        SettingsCard("Motion") {
            Toggle("Animate the visor", isOn: $model.animations)
            SettingsNote("Ukor Visor follows macOS Reduce Motion even when animations are enabled here.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard("Keyboard") {
                SettingsNote("These keys work while the expanded visor has keyboard focus. Ukor Visor has no global keyboard shortcuts.")
                LabeledContent("Return or Enter", value: "OK")
                LabeledContent("Delete", value: "Backspace in Roku text fields")
                LabeledContent("Type or press ⌘V", value: "Enter text in a Roku text field")
                LabeledContent("Tab or Shift–Tab", value: "Move focus between visor buttons")
                LabeledContent("Escape", value: "Close the visor")
            }
            SettingsCard("Directional pad") {
                SettingsNote("Click the on-screen arrows to navigate. Hold an arrow button to repeat. The Mac’s arrow keys are currently unassigned.")
            }
        }
    }

    private var about: some View {
        let metadata = SettingsMetadata(info: Bundle.main.infoDictionary ?? [:])
        return VStack(alignment: .leading, spacing: 22) {
            SettingsCard(metadata.name) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 60, height: 60)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        if let version = metadata.versionLabel { Text(version).font(.headline) }
                        if let developer = metadata.developer { Text(developer) }
                        if let copyright = metadata.copyright { SettingsNote(copyright) }
                    }
                }
                SettingsNote("Ukor Visor is an independent third-party app and is not affiliated with Roku.")
                if let roamURL = URL(string: "https://github.com/msdrigg/Roam") {
                    Link("Roam by Scott Driggers", destination: roamURL)
                }
                if let url = metadata.supportURL { Link("Support", destination: url) }
                if let url = metadata.websiteURL { Link("Website", destination: url) }
            }
            SettingsCard("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                if !model.loginMessage.isEmpty { SettingsNote(model.loginMessage) }
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(SettingsTheme.border)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(SettingsTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsDetails: View {
    let details: String

    var body: some View {
        DisclosureGroup("Details") {
            SettingsNote(details).textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct DeviceSettings: View {
    @ObservedObject var model: RokuModel

    @FocusState private var manualIPFocused: Bool

    private var validAddress: Bool { RokuAddress.ipv4(model.manualAddress) != nil }

    var body: some View {
        SettingsCard("Selected Roku") {
            LabeledContent("Device", value: model.selected?.name ?? "No saved device")
            LabeledContent("Status") {
                Label(model.status.settingsTitle, systemImage: "circle.fill")
                    .labelStyle(StatusLabelStyle(color: statusColor))
            }
            if let device = model.selected {
                LabeledContent("IP address", value: device.address)
            }
            if let message = model.status.settingsMessage { SettingsNote(message) }
            if case let .disconnected(details) = model.status { SettingsDetails(details: details) }
            HStack {
                Button("Reconnect", action: model.reconnect)
                    .disabled(!model.canReconnect || model.status == .connecting)
                Button(model.scanning ? "Searching…" : "Refresh Devices", action: model.refresh)
                    .disabled(model.scanning)
            }
        }
        SettingsCard("Discovered devices") {
            if model.scanning && model.devices.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    SettingsNote("Looking for Roku devices on your local network…")
                }
            } else if model.devices.isEmpty {
                SettingsNote(SettingsPresentation.discoveryEmpty(savedDevice: model.selected))
            }
            if !model.scanning && !model.discoveryMessage.isEmpty {
                SettingsDetails(details: model.discoveryMessage)
            }
            ForEach(model.devices) { device in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "tv").foregroundStyle(SettingsTheme.secondaryText).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).fontWeight(.medium)
                        SettingsNote(device.address)
                    }
                    Spacer()
                    if device.id == model.selected?.id, model.status == .connected || model.status == .standby {
                        Label("Selected", systemImage: "checkmark").font(.callout)
                    } else {
                        Button("Connect") { model.select(device) }
                            .buttonStyle(SettingsButtonStyle(prominent: true))
                            .accessibilityLabel("Connect to \(device.name)")
                            .disabled(model.status == .connecting)
                    }
                }
            }
        }
        SettingsCard("Manual connection") {
            SettingsNote("Find the address on your Roku under Settings › Network › About.")
            Text("Manual IP address").font(.callout.weight(.medium)).accessibilityHidden(true)
            HStack {
                TextField("Manual IP address", text: $model.manualAddress, prompt: Text("192.168.1.25").foregroundStyle(SettingsTheme.mutedText))
                    .focused($manualIPFocused)
                    .modifier(SettingsFieldSurface(focused: manualIPFocused))
                    .onSubmit(connectManually)
                    .accessibilityLabel("Manual IP address")
                Button("Connect", action: connectManually)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .accessibilityLabel("Connect by IP address")
                    .disabled(!validAddress || model.status == .connecting)
            }
            if !model.manualAddress.isEmpty && !validAddress {
                Label("Enter a valid local IPv4 address, such as 192.168.1.25.", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .secondary
        case .standby, .connecting: .orange
        case .connected: .green
        case .disconnected: .red
        }
    }

    private func connectManually() {
        guard validAddress, model.status != .connecting else { return }
        model.useManualAddress(model.manualAddress)
    }
}

private struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color).accessibilityHidden(true)
            configuration.title
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var model: RokuModel
    @ObservedObject var navigation: SettingsNavigation
    let scroll: ScrollViewProxy
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var matching: [RokuChannel] {
        SettingsPresentation.channels(model.installedChannels ?? [], matching: model.channelSearch)
    }

    var body: some View {
        Group {
            SettingsCard("Quick Launch") {
                SettingsNote(model.selected.map { "Shortcuts for \($0.name)" } ?? "Connect a Roku in Devices to discover channels and choose shortcuts.")
                if model.selected != nil, model.favorites.isEmpty {
                    SettingsNote("Add your first shortcut from Installed Channels below.")
                }
                ForEach(0..<QuickLaunchFavorites.limit, id: \.self) { index in
                    if index > 0 { SettingsDivider() }
                    slot(index) {
                        model.replacingShortcut = $0
                        model.channelSearch = ""
                        if model.installedChannels == nil { model.refreshChannels() }
                    }
                }
            }
            SettingsCard("Installed Channels") {
                catalog
            }
            .id("catalog")
            .onChange(of: model.replacingShortcut, initial: true) { _, replacement in
                if replacement != nil, !navigation.shortcutRequest { focusSearch() }
            }
        }
        .onAppear(perform: model.refreshChannels)
        .task(id: navigation.shortcutRequest) {
            guard navigation.shortcutRequest else { return }
            focusSearch()
            navigation.consumeShortcutRequest()
        }
        .onChange(of: model.selected?.id) { _, _ in model.refreshChannels() }
        .onChange(of: model.status) { _, status in
            if status == .connected, model.installedChannels == nil { model.refreshChannels() }
        }
    }

    private func focusSearch() {
        let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.18)
        withAnimation(animation) { scroll.scrollTo("catalog", anchor: .top) }
        searchFocused = true
    }

    private func slot(_ index: Int, replace: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(SettingsTheme.secondaryText)
                .frame(width: 16)
                .accessibilityLabel("Position \(index + 1)")
            if model.favorites.indices.contains(index) {
                let channel = model.favorites[index]
                ChannelArtwork(model: model, channel: channel)
                Text(channel.name).fontWeight(.medium).lineLimit(2)
                if model.isUnavailable(channel.id) {
                    Image(systemName: "exclamationmark.circle").help("Unavailable on this Roku")
                        .accessibilityLabel("Unavailable on this Roku")
                }
                Spacer(minLength: 8)
                moveButton(channel, offset: -1, disabled: index == 0)
                moveButton(channel, offset: 1, disabled: index == model.favorites.count - 1)
                Menu {
                    Button("Replace…") { replace(channel.id) }
                    Button("Remove Shortcut", role: .destructive) { model.removeShortcut(channel.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(SettingsTheme.primaryText)
                        .padding(.horizontal, 4)
                        .background(SettingsTheme.button, in: RoundedRectangle(cornerRadius: 4))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Actions for \(channel.name)")
            } else {
                Image(systemName: "plus.app").foregroundStyle(SettingsTheme.secondaryText).accessibilityHidden(true)
                    .frame(width: 33, height: 26)
                SettingsNote("Empty slot")
                Spacer()
            }
        }
        .frame(minHeight: 27)
    }

    private func moveButton(_ channel: RokuChannel, offset: Int, disabled: Bool) -> some View {
        let direction = offset < 0 ? "up" : "down"
        return Button { model.moveShortcut(channel.id, by: offset) } label: {
            Image(systemName: "arrow.\(direction)")
        }
        .help("Move \(direction)").accessibilityLabel("Move \(channel.name) \(direction)")
        .disabled(disabled)
    }

    @ViewBuilder private var catalog: some View {
        if model.selected == nil {
            SettingsNote("Installed channels appear after you connect to a Roku.")
        } else {
            if let replacement = model.favorites.first(where: { $0.id == model.replacingShortcut }) {
                HStack {
                    Text("Replace \(replacement.name)")
                    Spacer()
                    Button("Cancel") { model.replacingShortcut = nil }
                }
            }
            HStack {
                TextField("Search installed channels", text: $model.channelSearch, prompt: Text("Search channels").foregroundStyle(SettingsTheme.mutedText))
                    .modifier(SettingsFieldSurface(focused: searchFocused))
                    .accessibilityLabel("Search installed channels")
                    .focused($searchFocused)
                Button(model.catalogError == nil ? "Refresh" : "Retry", action: model.refreshChannels)
                    .disabled(model.loadingChannels || model.status == .connecting)
            }
            if model.loadingChannels {
                HStack {
                    ProgressView().controlSize(.small)
                    SettingsNote("Loading channels…")
                }
            }
            if let error = model.catalogError {
                SettingsNote("Couldn’t load installed channels. Check that the Roku is awake and try again. Your shortcuts are saved.")
                SettingsDetails(details: error)
            } else if !model.loadingChannels, matching.isEmpty {
                if model.installedChannels == nil {
                    SettingsNote("Connect to your Roku to load its channels.")
                } else {
                    SettingsNote(model.installedChannels?.isEmpty == true ? "This Roku reported no installed channels." : "No channels match your search.")
                }
            }
            LazyVStack(spacing: 0) {
                ForEach(matching) { channel in
                    SettingsDivider()
                    HStack(spacing: 10) {
                        ChannelArtwork(model: model, channel: channel)
                        Text(channel.name)
                        Spacer(minLength: 12)
                        if model.favorites.contains(where: { $0.id == channel.id }) {
                            Label("Selected", systemImage: "checkmark").foregroundStyle(SettingsTheme.secondaryText)
                        } else {
                            let replacing = model.replacingShortcut != nil
                            Button(replacing ? "Choose" : "Add") { model.chooseShortcut(channel) }
                                .accessibilityLabel(replacing ? "Choose \(channel.name)" : "Add \(channel.name)")
                                .disabled(!replacing && model.favorites.count >= QuickLaunchFavorites.limit)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct ChannelArtwork: View {
    @ObservedObject var model: RokuModel
    let channel: RokuChannel

    var body: some View {
        let key = model.iconKey(for: channel)
        Group {
            if let icon = model.channelIcons[key] {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "play.rectangle").foregroundStyle(SettingsTheme.secondaryText)
            }
        }
        .frame(width: 33, height: 26)
        .background(SettingsTheme.sidebar, in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
        .task(id: key) { await model.loadIcon(for: channel) }
    }
}

enum SettingsTheme {
    static let background = color(SettingsPalette.background)
    static let sidebar = color(SettingsPalette.sidebar)
    static let card = color(SettingsPalette.card)
    static let selection = color(SettingsPalette.selection)
    static let button = color(SettingsPalette.button)
    static let border = color(SettingsPalette.border)
    static let accent = color(SettingsPalette.accent)
    static let primaryText = color(SettingsPalette.primaryText)
    static let secondaryText = color(SettingsPalette.secondaryText)
    static let mutedText = color(SettingsPalette.mutedText)

    private static func color(_ hex: UInt32) -> Color {
        let rgb = SettingsPalette.rgb(hex)
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

private final class SettingsHover: ObservableObject {
    @Published var active = false
}

private struct SettingsSidebarLabel: View {
    let section: SettingsSection
    let selected: Bool
    @StateObject private var hover = SettingsHover()

    var body: some View {
        Label(section.rawValue, systemImage: section.symbol)
            .foregroundStyle(selected ? SettingsTheme.primaryText : SettingsTheme.secondaryText)
            .symbolVariant(.none)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .listRowBackground(
                RoundedRectangle(cornerRadius: 7)
                    .fill(SettingsTheme.selection.opacity(selected ? 1 : hover.active ? 0.45 : 0))
            )
            .onHover { hover.active = $0 }
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonFace(configuration: configuration, prominent: prominent)
    }
}

private struct SettingsButtonFace: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var hover = SettingsHover()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        let fill = prominent && enabled ? SettingsTheme.accent : SettingsTheme.button
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(prominent && enabled ? SettingsTheme.background :
                                enabled ? SettingsTheme.primaryText : SettingsTheme.mutedText)
            .background(enabled ? fill : SettingsTheme.sidebar, in: shape)
            .overlay {
                shape.fill(configuration.isPressed ? .black.opacity(0.16) :
                            enabled && hover.active ? .white.opacity(0.10) : .clear)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(focused ? SettingsTheme.accent : SettingsTheme.border,
                                   lineWidth: focused || contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .onHover { hover.active = $0 }
    }
}

private struct SettingsFieldSurface: ViewModifier {
    let focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(SettingsTheme.background, in: shape)
            .overlay {
                shape.strokeBorder(focused ? SettingsTheme.accent : SettingsTheme.border,
                                   lineWidth: focused || contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        SettingsTheme.border.frame(height: 1).accessibilityHidden(true)
    }
}
