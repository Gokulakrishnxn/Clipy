import AppKit
import ClipperCore
import SwiftUI

/// The popup's content: vibrancy → search → category tabs → list →
/// smart-action bar → footer.
struct ContentView: View {
    @Bindable var model: HistoryModel
    @AppStorage(PrefKey.showSearch) private var showSearch = true
    @AppStorage(PrefKey.showFooter) private var showFooter = true

    var body: some View {
        GeometryReader { geo in
            content.environment(\.panelWidth, PanelWidth(geo.size.width))
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .onChange(of: model.core.revision) { _, _ in model.reloadIfStale() }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if showSearch {
                    SearchFieldView(text: $model.query)
                }
                CategoryBar(model: model)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider()
            HistoryListView(model: model)
            SmartActionBar(model: model)
            if showFooter {
                Divider()
                FooterView(model: model)
            }
        }
    }
}

/// Width class of the popup, so every part can drop detail as it narrows.
enum PanelWidth: Comparable {
    case narrow   // < 340 pt
    case compact  // < 440 pt
    case regular

    init(_ width: CGFloat) {
        self = width < 340 ? .narrow : (width < 440 ? .compact : .regular)
    }
}

private struct PanelWidthKey: EnvironmentKey {
    static let defaultValue = PanelWidth.regular
}

extension EnvironmentValues {
    var panelWidth: PanelWidth {
        get { self[PanelWidthKey.self] }
        set { self[PanelWidthKey.self] = newValue }
    }
}

/// All · Text · Images · Links · Files, with live counts. Tab / ⇧Tab cycle.
/// Tabs never wrap: as the panel narrows the bar falls back from
/// icon + title + count, to icon + title, to icon + count, to icon only.
struct CategoryBar: View {
    @Bindable var model: HistoryModel

    enum Detail { case full, title, count, icon }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(.full)
            bar(.title)
            bar(.count)
            bar(.icon)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
        )
    }

    private func bar(_ detail: Detail) -> some View {
        HStack(spacing: 2) {
            ForEach(HistoryCategory.allCases) { cat in
                tab(cat, detail: detail)
            }
        }
    }

    private func tab(_ cat: HistoryCategory, detail: Detail) -> some View {
        let active = model.category == cat
        let count = model.counts[cat] ?? 0
        return Button {
            withAnimation(.snappy(duration: 0.18)) { model.category = cat }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: cat.symbol).font(.system(size: 10, weight: .semibold))
                if detail == .full || detail == .title {
                    Text(cat.title).font(.system(size: 11.5, weight: active ? .semibold : .regular))
                }
                if (detail == .full || detail == .count), count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(active ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.8))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, detail == .icon ? 6 : 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                }
            }
            .foregroundStyle(active ? Color.primary : (count == 0 ? Color.secondary.opacity(0.55) : Color.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(cat.title)\(count > 0 ? " (\(count))" : "") · Tab / ⇧Tab to switch")
        .accessibilityLabel("\(cat.title), \(count) items")
    }
}

/// `NSVisualEffectView` – the same material Maccy and system popovers use.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Plain text field that takes focus when the popup opens; arrow keys and
/// Enter are intercepted by the panel's key monitor so they never move the
/// insertion point.
struct SearchFieldView: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { focused = true }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
    }
}

struct HistoryListView: View {
    @Bindable var model: HistoryModel
    @AppStorage(PrefKey.showPreview) private var showPreview = true
    @AppStorage(PrefKey.previewDelayMs) private var previewDelayMs = 1500

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    let pinnedEnd = model.items.lastIndex(where: \.pinned)
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if index == 0, pinnedEnd != nil { SectionLabel(title: "Pinned", symbol: "pin.fill") }
                        if let pinnedEnd, index == pinnedEnd + 1 { SectionLabel(title: "Recent", symbol: "clock") }
                        row(item, index: index)
                    }
                    if model.items.isEmpty { EmptyStateView(model: model) }
                }
                .padding(.vertical, 5)
            }
            .onChange(of: model.selectedId) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ItemSummary, index: Int) -> some View {
        let smart = model.smart(for: item)
        HistoryRow(
            item: item,
            ordinal: index < 9 ? index + 1 : nil,
            selected: item.id == model.selectedId,
            thumbnail: item.hasThumbnail ? model.core.thumbnail(item.id) : nil,
            badge: smart.badge
        )
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture { model.activate(item.id, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
        .onHover { inside in
            if inside {
                model.selectedId = item.id
                schedulePreview(for: item.id)
            } else if model.previewedId == item.id {
                model.previewedId = nil
            }
        }
        .popover(isPresented: previewBinding(for: item.id), arrowEdge: .trailing) {
            PreviewView(item: item, core: model.core)
        }
        .contextMenu {
            Button("Paste") { model.activate(item.id) }
            Button("Paste as Plain Text") { model.activate(item.id, modifiers: .option) }
            Button("Copy Only") { model.activate(item.id, modifiers: .shift) }
            if !smart.actions.isEmpty {
                Menu("Smart Actions") {
                    ForEach(smart.actions) { action in
                        Button {
                            model.perform(action, on: item.id)
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                    }
                }
            }
            Divider()
            Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item.id) }
            Button("Delete", role: .destructive) { model.delete(item.id) }
        }
    }

    private func previewBinding(for id: UInt64) -> Binding<Bool> {
        Binding(
            get: { model.previewedId == id },
            set: { if !$0, model.previewedId == id { model.previewedId = nil } }
        )
    }

    private func schedulePreview(for id: UInt64) {
        guard showPreview else { return }
        let delay = Double(max(0, previewDelayMs)) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if model.selectedId == id, model.dismiss != nil {
                model.previewedId = id
            }
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6)
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct EmptyStateView: View {
    let model: HistoryModel

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: ClipLogo.image(.mark))
                .renderingMode(.template)
                .resizable()
                .frame(width: 34, height: 34)
                .foregroundStyle(.tertiary)
            Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var message: String {
        if !model.query.isEmpty { return "No matches" }
        switch model.category {
        case .all: return "No clipboard history yet"
        case .text: return "No text clips"
        case .images: return "No images"
        case .links: return "No links"
        case .files: return "No files"
        }
    }

    private var hint: String {
        model.query.isEmpty ? "Copy something and it shows up here." : "Try another tab with Tab ⇥"
    }
}

/// One row: kind tile · title · smart badge · age · ⌘n hint.
struct HistoryRow: View {
    let item: ItemSummary
    let ordinal: Int?
    let selected: Bool
    let thumbnail: NSImage?
    let badge: SmartBadge?
    @AppStorage(PrefKey.showApplicationIcons) private var showAppIcons = false
    @AppStorage(PrefKey.imageMaxHeight) private var imageMaxHeight = 40
    @Environment(\.panelWidth) private var width

    var body: some View {
        HStack(spacing: 8) {
            leading
            titleView
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let badge { BadgeView(badge: badge, selected: selected, iconOnly: width == .narrow) }
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
            if width != .narrow {
                Text(Self.age(item.lastCopiedAt))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? .white.opacity(0.7) : Color.secondary.opacity(0.8))
            }
            if let ordinal {
                Text("⌘\(ordinal)")
                    .font(.system(size: 11, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .padding(.vertical, item.kind == .image ? 3 : 0)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : .clear)
                .padding(.horizontal, 5)
        )
        .animation(.easeOut(duration: 0.08), value: selected)
    }

    @ViewBuilder
    private var titleView: some View {
        if item.kind == .link, let parts = SmartDetector.linkParts(item.title) {
            HStack(spacing: 0) {
                Text(parts.host).fontWeight(.medium)
                Text(parts.rest).foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.system(size: 13))
        } else {
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13))
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .image:
            if let thumbnail {
                // Fixed tile, image fills and is cropped: no letterbox frame.
                let h = CGFloat(min(max(imageMaxHeight, 24), width == .narrow ? 40 : 120))
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: h * 1.25, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                KindTile(symbol: "photo", tint: .purple, selected: selected)
            }
        case .color:
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: NSColor(hex: item.color ?? "") ?? .gray))
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        case .files:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let first = item.files.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
        case .link:
            if showAppIcons, let icon = appIcon { icon } else {
                KindTile(symbol: "link", tint: .blue, selected: selected)
            }
        case .text:
            if showAppIcons, let icon = appIcon { icon } else {
                KindTile(symbol: "text.alignleft", tint: .gray, selected: selected)
            }
        }
    }

    private var appIcon: AnyView? {
        guard let bundle = item.source?.bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return AnyView(Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20))
    }

    /// "now", "5m", "3h", "2d", "Mar 4".
    static func age(_ ms: Int64) -> String {
        let seconds = Date().timeIntervalSince1970 - Double(ms) / 1000
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(86400 * 7): return "\(Int(seconds / 86400))d"
        default:
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("MMMd")
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
    }
}

/// Small tinted square holding the kind's SF Symbol.
private struct KindTile: View {
    let symbol: String
    let tint: Color
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(selected ? Color.white.opacity(0.2) : tint.opacity(0.15))
            .frame(width: 20, height: 20)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : tint)
            )
    }
}

/// Capsule label from the smart detector ("JSON", "= 42", "Token", …).
struct BadgeView: View {
    let badge: SmartBadge
    let selected: Bool
    var iconOnly = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = badge.symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            if !iconOnly || badge.symbol == nil {
                Text(badge.text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
        }
        .help(badge.text)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(selected ? Color.white : tint)
        .background(Capsule().fill(selected ? Color.white.opacity(0.22) : tint.opacity(0.14)))
        .fixedSize()
    }

    private var tint: Color {
        switch badge.tone {
        case .neutral: .secondary
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }
}

/// Offline assistant strip for the selected item: facts + one-key actions.
struct SmartActionBar: View {
    @Bindable var model: HistoryModel
    @Environment(\.panelWidth) private var width

    var body: some View {
        if let toast = model.toast {
            bar {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                Spacer()
            }
        } else if let item = model.selectedItem {
            let smart = model.smart(for: item)
            if !smart.actions.isEmpty || smart.stats != nil {
                bar {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                            Text("Smart actions").font(.system(size: 10, weight: .semibold)).fixedSize()
                            if let stats = smart.stats, width != .narrow {
                                Text("· \(stats)").font(.system(size: 10)).lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 4)
                            Text("⌃1–\(min(9, smart.actions.count))")
                                .font(.system(size: 10, design: .rounded))
                                .opacity(smart.actions.isEmpty ? 0 : 1)
                        }
                        .foregroundStyle(.secondary)
                        if !smart.actions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 5) {
                                    ForEach(Array(smart.actions.prefix(9).enumerated()), id: \.element.id) { i, action in
                                        ActionChip(action: action, index: i + 1, iconOnly: width == .narrow) { model.perform(action) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func bar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
    }
}

private struct ActionChip: View {
    let action: SmartAction
    let index: Int
    var iconOnly = false
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: action.symbol).font(.system(size: 10, weight: .medium))
                if !iconOnly {
                    Text(action.title).font(.system(size: 11)).lineLimit(1).fixedSize()
                }
                Text("\(index)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(.tertiary, lineWidth: 0.5))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor).opacity(0.7))
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(action.title) (⌃\(index))")
    }
}

extension NSColor {
    /// Parses `#rgb`, `#rrggbb`, `#rrggbbaa` (what the engine normalises to).
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            (r, g, b, a) = (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, 1)
        case 8:
            (r, g, b, a) = (
                CGFloat((v >> 24) & 0xFF) / 255, CGFloat((v >> 16) & 0xFF) / 255,
                CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255
            )
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
