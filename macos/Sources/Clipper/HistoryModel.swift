import AppKit
import ClipperCore
import KeyboardShortcuts
import Observation

/// The tabs above the list. Each maps to an engine-side kind filter, so
/// switching is as cheap as searching.
enum HistoryCategory: String, CaseIterable, Identifiable {
    case all, text, images, links, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .links: "Links"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .text: "text.alignleft"
        case .images: "photo"
        case .links: "link"
        case .files: "doc"
        }
    }

    /// Engine kinds shown under this tab (`nil` = everything).
    var kinds: [ItemKind]? {
        switch self {
        case .all: nil
        case .text: [.text, .color]
        case .images: [.image]
        case .links: [.link]
        case .files: [.files]
        }
    }

    static func of(_ kind: ItemKind) -> HistoryCategory {
        switch kind {
        case .text, .color: .text
        case .image: .images
        case .link: .links
        case .files: .files
        }
    }
}

/// State behind the popup: the visible items, the search query, the
/// selection, and the actions the keyboard/mouse trigger on them.
@MainActor
@Observable
final class HistoryModel {
    let core: CoreService
    let watcher: ClipboardWatcher

    private(set) var items: [ItemSummary] = []
    /// Bound to the search field; `ContentView` calls `queryChanged()`.
    var query = ""
    var selectedId: UInt64?
    var previewedId: UInt64?
    /// Set by the panel controller so actions can close the popup.
    var dismiss: (() -> Void)?
    /// Set while the ⇧ key is down (footer's trash then clears pinned too).
    private(set) var shiftDown = false
    @ObservationIgnored private var shiftTimer: Timer?

    /// Called from the flags monitor. Because the key-up can be missed (e.g.
    /// when the popup was opened with ⇧⌘V), while ⇧ is reported down we
    /// re-check the real keyboard state and clear it once released.
    func updateShift(_ down: Bool) {
        shiftDown = down && NSEvent.modifierFlags.contains(.shift)
        shiftTimer?.invalidate()
        shiftTimer = nil
        guard shiftDown else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if !NSEvent.modifierFlags.contains(.shift) {
                    self.shiftDown = false
                    timer.invalidate()
                    self.shiftTimer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        shiftTimer = t
    }

    /// Active tab; remembered across launches.
    var category: HistoryCategory = HistoryCategory(
        rawValue: UserDefaults.standard.string(forKey: PrefKey.selectedCategory) ?? ""
    ) ?? .all {
        didSet {
            UserDefaults.standard.set(category.rawValue, forKey: PrefKey.selectedCategory)
            reload(keepSelection: false)
        }
    }
    /// Item count per tab for the current query.
    private(set) var counts: [HistoryCategory: Int] = [:]
    /// Items checked for a bulk action (⌘-click, ⇧-click, ⌘A, select mode).
    var marked: Set<UInt64> = []
    /// Select mode: rows show checkboxes and a click toggles instead of pasting.
    var selecting = false {
        didSet { if !selecting { marked.removeAll() } }
    }
    /// Where a ⇧-click range starts.
    @ObservationIgnored private var markAnchor: UInt64?

    /// Brief confirmation shown in the action bar ("Copied clean link").
    var toast: String?

    private var observedRevision = -1
    /// Smart analysis per item id, invalidated on every reload. Not observed:
    /// it is a cache filled lazily while rows render.
    @ObservationIgnored private var smartCache: [UInt64: SmartInfo] = [:]

    init(core: CoreService, watcher: ClipboardWatcher) {
        self.core = core
        self.watcher = watcher
        reload(keepSelection: false)
    }

    // MARK: Data

    func reload(keepSelection: Bool = true) {
        let previous = selectedId
        let everything = core.list(query: query)
        var tally: [HistoryCategory: Int] = [.all: everything.count]
        for item in everything { tally[HistoryCategory.of(item.kind), default: 0] += 1 }
        counts = tally
        if let kinds = category.kinds {
            items = everything.filter { kinds.contains($0.kind) }
        } else {
            items = everything
        }
        smartCache.removeAll(keepingCapacity: true)
        let visible = Set(items.map(\.id))
        marked.formIntersection(visible)
        observedRevision = core.revision
        if keepSelection, let previous, items.contains(where: { $0.id == previous }) {
            selectedId = previous
        } else {
            selectedId = items.first?.id
        }
        if let previewedId, !items.contains(where: { $0.id == previewedId }) {
            self.previewedId = nil
        }
    }

    func queryChanged() { reload(keepSelection: false) }

    /// Cheap check views call from `onChange(of: core.revision)`.
    func reloadIfStale() {
        if observedRevision != core.revision { reload() }
    }

    var selectedItem: ItemSummary? {
        items.first { $0.id == selectedId }
    }

    var pinnedCount: Int { items.filter(\.pinned).count }

    // MARK: Categories

    /// Tab / ⇧Tab (and ⌘← / ⌘→) cycle the tabs.
    func cycleCategory(_ step: Int) {
        let all = HistoryCategory.allCases
        let idx = all.firstIndex(of: category) ?? 0
        category = all[(idx + step + all.count) % all.count]
    }

    // MARK: Smart assistant (offline heuristics)

    func smart(for item: ItemSummary) -> SmartInfo {
        if let cached = smartCache[item.id] { return cached }
        var info: SmartInfo
        switch item.kind {
        case .text, .link:
            let text = core.detail(item.id, maxTextBytes: 256 * 1024)?.text ?? item.title
            info = SmartDetector.analyze(text)
        case .color:
            info = SmartDetector.analyze(item.color ?? item.title)
        case .image:
            info = SmartInfo()
            if let meta = item.image {
                info.stats = "\(meta.width) × \(meta.height) · \(meta.format.uppercased())"
                info.actions.append(SmartAction(id: "dims", title: "Copy size", symbol: "ruler", effect: .text("\(meta.width)x\(meta.height)")))
            }
            info.actions.insert(SmartAction(id: "save", title: "Save to Downloads", symbol: "square.and.arrow.down", effect: .saveImage), at: 0)
        case .files:
            let urls = item.files.map { URL(fileURLWithPath: $0.path) }
            info = SmartInfo()
            info.stats = item.files.count == 1 ? item.files[0].name : "\(item.files.count) files"
            info.actions.append(SmartAction(id: "reveal", title: "Reveal in Finder", symbol: "folder", effect: .reveal(urls)))
            if let first = urls.first {
                info.actions.append(SmartAction(id: "open", title: "Open", symbol: "arrow.up.forward.app", effect: .open(first)))
            }
            info.actions.append(SmartAction(id: "paths", title: "Copy path", symbol: "doc.on.doc", effect: .text(urls.map(\.path).joined(separator: "\n"))))
            info.actions.append(SmartAction(id: "names", title: "Copy name", symbol: "textformat", effect: .text(item.files.map(\.name).joined(separator: "\n"))))
        }
        smartCache[item.id] = info
        return info
    }

    var selectedSmart: SmartInfo? {
        selectedItem.map(smart(for:))
    }

    /// Runs a smart action for `id` (default: the selection).
    func perform(_ action: SmartAction, on id: UInt64? = nil) {
        guard let id = id ?? selectedId, let item = items.first(where: { $0.id == id }) else { return }
        switch action.effect {
        case let .text(value):
            Paster.writeString(value)
            AppDelegate.shared?.animateStatusIcon()
            dismiss?()
            if UserDefaults.standard.bool(forKey: PrefKey.pasteOnSelect) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if !Paster.pressCommandV() { Paster.requestAccessibility() }
                }
            }
        case let .open(url):
            dismiss?()
            NSWorkspace.shared.open(url)
        case let .reveal(urls):
            dismiss?()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .saveImage:
            saveImage(item)
        case .delete:
            delete(id)
            flash("Forgotten")
        }
    }

    private func saveImage(_ item: ItemSummary) {
        guard let image = core.image(item.id),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { flash("Could not read image"); return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = downloads.appendingPathComponent("Clip \(stamp).png")
        do {
            try png.write(to: url)
            AppDelegate.shared?.animateStatusIcon()
            dismiss?()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            flash("Save failed")
        }
    }

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }

    // MARK: Selection

    func select(offset: Int) {
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.id == selectedId } ?? -1
        let next = min(max(idx + offset, 0), items.count - 1)
        selectedId = items[next].id
    }

    func selectFirst() { selectedId = items.first?.id }
    func selectLast() { selectedId = items.last?.id }

    /// ⌘1…⌘9 pick the n-th visible row.
    func select(ordinal: Int) -> Bool {
        guard ordinal >= 1, ordinal <= min(9, items.count) else { return false }
        selectedId = items[ordinal - 1].id
        return true
    }

    // MARK: Multi-select

    var showsCheckboxes: Bool { selecting || !marked.isEmpty }

    /// Row click: ⌘ toggles, ⇧ extends a range (once something is marked),
    /// in select mode a plain click toggles; otherwise paste as before.
    func click(_ id: UInt64, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            toggleMark(id)
        } else if flags.contains(.shift), showsCheckboxes {
            markRange(to: id)
        } else if selecting {
            toggleMark(id)
        } else {
            activate(id, modifiers: flags)
        }
    }

    func toggleMark(_ id: UInt64) {
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
        markAnchor = id
        selectedId = id
    }

    func markRange(to id: UInt64) {
        let anchor = markAnchor ?? selectedId ?? id
        guard let a = items.firstIndex(where: { $0.id == anchor }),
              let b = items.firstIndex(where: { $0.id == id }) else { return toggleMark(id) }
        for item in items[min(a, b)...max(a, b)] { marked.insert(item.id) }
        selectedId = id
    }

    func markAll() {
        selecting = true
        marked = Set(items.map(\.id))
    }

    func clearMarks() {
        marked.removeAll()
        selecting = false
        markAnchor = nil
    }

    /// Deletes the checked items (confirming when there is more than one).
    func deleteMarked() {
        let ids = items.map(\.id).filter { marked.contains($0) }
        guard !ids.isEmpty else { return }
        if ids.count > 1 {
            let pinned = items.filter { marked.contains($0.id) && $0.pinned }.count
            let alert = NSAlert()
            alert.messageText = "Delete \(ids.count) items?"
            alert.informativeText = pinned > 0
                ? "\(pinned) of them \(pinned == 1 ? "is" : "are") pinned. This cannot be undone."
                : "This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let firstIdx = items.firstIndex { marked.contains($0.id) } ?? 0
        for id in ids { core.delete(id) }
        clearMarks()
        reload(keepSelection: false)
        if !items.isEmpty { selectedId = items[min(firstIdx, items.count - 1)].id }
        flash("Deleted \(ids.count) \(ids.count == 1 ? "item" : "items")")
    }

    /// Pins all checked items, or unpins them if they are all pinned already.
    func togglePinMarked() {
        let chosen = items.filter { marked.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let pin = !chosen.allSatisfy(\.pinned)
        for item in chosen where item.pinned != pin { core.setPinned(item.id, pin) }
        reload()
        flash(pin ? "Pinned \(chosen.count)" : "Unpinned \(chosen.count)")
    }

    // MARK: Actions

    /// Enter / click: copy back and (by default) paste into the previous app.
    /// ⌥ inverts the plain-text preference, ⇧ inverts the paste-vs-copy one.
    func activate(_ id: UInt64? = nil, modifiers: NSEvent.ModifierFlags = []) {
        guard let id = id ?? selectedId else { return }
        let d = UserDefaults.standard
        var paste = d.bool(forKey: PrefKey.pasteOnSelect)
        var plain = d.bool(forKey: PrefKey.pastePlainByDefault)
        if modifiers.contains(.shift) { paste.toggle() }
        if modifiers.contains(.option) { plain.toggle() }

        guard let content = core.pasteContent(id, plainTextOnly: plain) else { return }
        Paster.write(content, watcher: watcher)
        core.touch(id)
        AppDelegate.shared?.animateStatusIcon()
        dismiss?()

        if paste {
            // Give the previous app a moment to regain key status.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !Paster.pressCommandV() {
                    Paster.requestAccessibility()
                }
            }
        }
    }

    func togglePin(_ id: UInt64? = nil) {
        guard let id = id ?? selectedId, let item = items.first(where: { $0.id == id }) else { return }
        core.setPinned(id, !item.pinned)
        reload()
        selectedId = id
    }

    func delete(_ id: UInt64? = nil) {
        guard let id = id ?? selectedId else { return }
        let idx = items.firstIndex { $0.id == id } ?? 0
        core.delete(id)
        reload(keepSelection: false)
        if !items.isEmpty {
            selectedId = items[min(idx, items.count - 1)].id
        }
    }

    /// Clear (unpinned) or clear everything, with the confirmation Maccy shows.
    func clear(all: Bool) {
        let d = UserDefaults.standard
        if !d.bool(forKey: PrefKey.suppressClearAlert) {
            let alert = NSAlert()
            alert.messageText = all ? "Clear all history?" : "Clear history?"
            alert.informativeText = all
                ? "Every item, including pinned ones, will be removed. This cannot be undone."
                : "Pinned items are kept. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                d.set(true, forKey: PrefKey.suppressClearAlert)
            }
            guard response == .alertFirstButtonReturn else { return }
        }
        core.clear(keepPinned: !all)
        reload(keepSelection: false)
    }

    // MARK: Keyboard

    /// Handles a key event from the panel's local monitor. Returns `true`
    /// when consumed.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)

        // Bulk keys while items are checked: ⌫ / ⌦ delete them, esc unchecks.
        if !marked.isEmpty {
            if event.keyCode == 51 || event.keyCode == 117, flags.subtracting([.option, .function]).isEmpty, query.isEmpty || flags.contains(.option) {
                deleteMarked(); return true
            }
        }
        if event.keyCode == 53, showsCheckboxes { clearMarks(); return true }
        // ⌘A: select every visible item (when the search field is empty).
        if cmd, event.charactersIgnoringModifiers == "a", query.isEmpty {
            markAll(); return true
        }
        // Space toggles the highlighted row in select mode.
        if selecting, query.isEmpty, event.keyCode == 49, let id = selectedId {
            toggleMark(id); return true
        }

        // Pin / delete shortcuts are user-configurable (Preferences › General).
        if let shortcut = KeyboardShortcuts.Shortcut(event: event) {
            if shortcut == KeyboardShortcuts.getShortcut(for: .pin) {
                if marked.isEmpty { togglePin() } else { togglePinMarked() }
                return true
            }
            if shortcut == KeyboardShortcuts.getShortcut(for: .delete) {
                if marked.isEmpty { delete() } else { deleteMarked() }
                return true
            }
        }

        // ⌃1…⌃9 run the selected item's smart actions.
        if flags == .control, let chars = event.charactersIgnoringModifiers,
           let n = Int(chars), (1...9).contains(n),
           let actions = selectedSmart?.actions, n <= actions.count {
            perform(actions[n - 1])
            return true
        }

        switch event.keyCode {
        case 48: // tab / ⇧tab: next / previous category
            cycleCategory(flags.contains(.shift) ? -1 : 1)
            return true
        case 123 where cmd: cycleCategory(-1); return true // ⌘←
        case 124 where cmd: cycleCategory(1); return true // ⌘→
        case 125: select(offset: 1); return true // ↓
        case 126: select(offset: -1); return true // ↑
        case 121: select(offset: 10); return true // page down
        case 116: select(offset: -10); return true // page up
        case 115: selectFirst(); return true // home
        case 119: selectLast(); return true // end
        case 36, 76: // return / keypad enter
            activate(modifiers: flags)
            return true
        case 53: // escape
            if !query.isEmpty { query = "" } else { dismiss?() }
            return true
        case 51 where cmd && flags.contains(.option): // ⌥⌘⌫
            clear(all: flags.contains(.shift))
            return true
        default:
            break
        }

        if cmd, let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if select(ordinal: Int(chars)!) { activate(modifiers: flags.subtracting(.command)); return true }
            case ",":
                dismiss?()
                AppDelegate.shared?.openPreferences()
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            case "j": select(offset: 1); return true
            case "k": select(offset: -1); return true
            default: break
            }
        }
        return false
    }
}
