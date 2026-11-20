import AppKit
import ClipperCore
import SwiftUI

/// Compact footer: item count on the left, icon buttons on the right.
/// Shortcuts are unchanged: Clear ⌥⌘⌫ (Clear all ⇧⌥⌘⌫), Preferences ⌘,, Quit ⌘Q.
struct FooterView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: ClipLogo.image(.mark))
                .renderingMode(.template)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            FooterButton(
                symbol: "trash",
                help: model.shiftDown ? "Clear all, including pinned (⇧⌥⌘⌫)" : "Clear unpinned (⌥⌘⌫)",
                tint: model.shiftDown ? .red : nil
            ) { model.clear(all: model.shiftDown) }
            FooterButton(symbol: "gearshape", help: "Preferences… (⌘,)") {
                model.dismiss?()
                AppDelegate.shared?.openPreferences()
            }
            FooterButton(symbol: "info.circle", help: "About") {
                model.dismiss?()
                AppDelegate.shared?.showAbout()
            }
            FooterButton(symbol: "power", help: "Quit (⌘Q)") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var summary: String {
        if model.shiftDown { return "⇧ Clear all mode" }
        let n = model.items.count
        let clips = "\(n) \(n == 1 ? "clip" : "clips")"
        return model.category == .all ? clips : "\(clips) · \(model.category.title)"
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint ?? (hovering ? .primary : .secondary))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color(nsColor: .quaternaryLabelColor).opacity(0.6) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The "look deeper" popover: content preview plus the metadata Maccy shows.
struct PreviewView: View {
    let item: ItemSummary
    let core: CoreService

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
                .frame(maxWidth: 480, maxHeight: 320, alignment: .topLeading)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let source = item.source {
                    GridRow {
                        Text("Application:").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            if let bundle = source.bundleId,
                               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 14, height: 14)
                            }
                            Text(source.name)
                        }
                    }
                }
                GridRow {
                    Text("First copy:").foregroundStyle(.secondary)
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(item.firstCopiedAt) / 1000)))
                }
                GridRow {
                    Text("Last copy:").foregroundStyle(.secondary)
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(item.lastCopiedAt) / 1000)))
                }
                GridRow {
                    Text("Number of copies:").foregroundStyle(.secondary)
                    Text("\(item.copyCount)")
                }
                GridRow {
                    Text("Size:").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                }
                if !item.flavors.isEmpty {
                    GridRow(alignment: .top) {
                        Text("Formats:").foregroundStyle(.secondary)
                        Text(item.flavors.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
            Text("Press ⏎ to paste, ⌥⏎ for plain text, ⇧⏎ to copy only.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let img = core.image(item.id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("Image").foregroundStyle(.secondary)
            }
        case .files:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.files, id: \.path) { f in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 16, height: 16)
                        Text(f.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        case .color:
            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: NSColor(hex: item.color ?? "") ?? .gray))
                    .frame(width: 48, height: 48)
                Text(item.title).font(.system(size: 13, design: .monospaced))
            }
        case .text, .link:
            ScrollView {
                Text(core.detail(item.id, maxTextBytes: 64 * 1024)?.text ?? item.title)
                    .font(.system(size: 12, design: item.kind == .text ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
