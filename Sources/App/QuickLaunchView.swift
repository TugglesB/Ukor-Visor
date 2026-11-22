import AppKit
import SwiftUI

struct QuickLaunchView: View {
    @ObservedObject var model: RokuModel
    @ObservedObject var presentation: VisorPresentation
    let edit: (String?) -> Void
    let toggle: () -> Void

    var body: some View {
        let scale = presentation.shortcutScale
        let expanded = presentation.shortcutsExpanded
        let progress: CGFloat = expanded ? 1 : 0
        let shape = QuickLaunchShape(progress: progress, rise: presentation.topExtension)
        let height = QuickLaunchLayout.tileHeight * scale
        ZStack(alignment: .topLeading) {
            shape.fill(Color(red: 196 / 255, green: 90 / 255, blue: 242 / 255))
                .contentShape(shape)
                .onTapGesture(perform: toggle)
                .accessibilityLabel(expanded ? "Hide Quick Launch" : "Show Quick Launch")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggle() }

            HStack(spacing: QuickLaunchLayout.spacing * scale) {
                if model.favorites.isEmpty {
                    addButton(scale: scale, height: height)
                } else {
                    ForEach(model.favorites) { channel in
                        shortcut(channel, scale: scale, height: height)
                            .frame(width: QuickLaunchLayout.tileWidth * scale)
                    }
                }
            }
            .offset(x: (QuickLaunchLayout.rowInset + QuickLaunchLayout.leadingEdge(progress: progress)) * scale,
                    y: QuickLaunchLayout.rowTop * scale)
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
            .animation(model.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? .easeInOut(duration: 0.18) : nil, value: model.favorites.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    private func addButton(scale: CGFloat, height: CGFloat) -> some View {
        Button(action: { edit(nil) }) {
            Label("Add Shortcut", systemImage: "plus")
                .font(.system(size: 10 * scale, weight: .semibold))
                .fixedSize()
                .padding(.horizontal, 6 * scale)
                .frame(height: height)
        }
        .buttonStyle(ShortcutButtonStyle(scale: scale))
        .help("Add Shortcut")
    }

    private func shortcut(_ channel: RokuChannel, scale: CGFloat, height: CGFloat) -> some View {
        let key = model.iconKey(for: channel)
        let unavailable = model.isUnavailable(channel.id)
        return Button(action: { model.launchShortcut(channel) }) {
            Group {
                if model.launchingChannel == channel.id {
                    ProgressView().controlSize(.mini)
                } else if let image = model.channelIcons[key] {
                    Image(nsImage: image).resizable().scaledToFit().padding(3 * scale)
                } else {
                    Image(systemName: unavailable ? "exclamationmark.triangle" : "play.rectangle")
                        .font(.system(size: 14 * scale))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
        .buttonStyle(ShortcutButtonStyle(scale: scale))
        .opacity(unavailable ? 0.63 : 1)
        .help(channel.name + (model.shortcutLaunchError.map { " — " + $0 } ?? (unavailable ? " — unavailable" : "")))
        .overlay(alignment: .topTrailing) {
            if model.shortcutLaunchError != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 8 * scale))
                    .foregroundStyle(.orange)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(channel.name)
        .accessibilityHint(unavailable ? "Unavailable on this Roku" : "Launches the channel on your Roku")
        .contextMenu {
            Button("Replace…") { edit(channel.id) }
            Button("Remove Shortcut") { model.removeShortcut(channel.id) }
        }
        .task(id: key) { await model.loadIcon(for: channel) }
    }
}

private struct ShortcutButtonStyle: ButtonStyle {
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.black.opacity(configuration.isPressed ? 0.55 : 0.38),
                        in: RoundedRectangle(cornerRadius: 6 * scale))
            .clipShape(RoundedRectangle(cornerRadius: 6 * scale))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}
