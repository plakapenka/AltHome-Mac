import SwiftUI
import Combine
import Carbon
import OpenDirectory

final class StartLibrary: ObservableObject {
    @Published private(set) var apps: [Item] = []
    @Published private(set) var pins: [StartPin]
    private let defaults: UserDefaults
    private let pinKey = "startMenuPins"
    private var scanGeneration = 0
    private var loading = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let data = defaults.data(forKey: pinKey)
        let decoder = JSONDecoder()
        pins = data.flatMap { try? decoder.decode([StartPin].self, from: $0) }
            ?? data.flatMap { try? decoder.decode([Item].self, from: $0) }?.map(StartPin.app)
            ?? []
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let generation = scanGeneration
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        DispatchQueue.global(qos:.userInitiated).async {
            let fm = FileManager.default
            let directories = fm.urls(for:.applicationDirectory, in:[.userDomainMask, .localDomainMask, .systemDomainMask])
            var urls: [URL] = []
            for directory in directories {
                guard let entries = fm.enumerator(at:directory, includingPropertiesForKeys:nil,
                                                  options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
                for case let url as URL in entries where url.pathExtension.lowercased() == "app" {
                    entries.skipDescendants()
                    urls.append(url)
                }
            }
            urls += [URL(fileURLWithPath:"/System/Library/CoreServices/Finder.app")] + running
            var seen = Set<String>()
            let result = urls.map { Item($0) }.filter { seen.insert($0.key).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.loading = false
                if self.scanGeneration == generation { self.apps = result }
                else { self.refresh() }
            }
        }
    }

    static func canTrash(_ item: Item) -> Bool {
        let url = item.url.resolvingSymlinksInPath().standardizedFileURL
        return url.pathExtension.lowercased() == "app"
            && !url.path.hasPrefix("/System/")
            && url != Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func didTrash(_ item: Item) {
        scanGeneration += 1
        apps.removeAll { $0.path == item.path }
        removePins { $0.path == item.path }
        refresh()
    }

    func isPinned(_ item: Item) -> Bool {
        pins.contains { $0.items.contains { $0.key == item.key } }
    }

    func setPinned(_ item: Item, _ pinned: Bool) {
        guard isPinned(item) != pinned else { return }
        if pinned { savePins(pins + [.app(item)]) }
        else { removePins { $0.key == item.key } }
    }

    private func removePins(where matches: (Item) -> Bool) {
        let updated: [StartPin] = pins.compactMap { pin in
            switch pin {
            case .app(let item): return matches(item) ? nil : pin
            case .folder(var folder):
                folder.items.removeAll(where: matches)
                return Self.compacted(folder)
            }
        }
        savePins(updated)
    }

    // A lone remaining app takes its folder's place in the grid.
    private static func compacted(_ folder: StartFolder) -> StartPin? {
        folder.items.count > 1 ? .folder(folder) : folder.items.first.map(StartPin.app)
    }

    func folder(_ key: String?) -> StartFolder? {
        guard let key, case .folder(let folder) = pins.first(where: { $0.key == key }) else { return nil }
        return folder
    }

    func movePin(_ key: String, to index: Int, in folderKey: String?) {
        var updated = pins
        if let folderKey {
            guard let i = updated.firstIndex(where: { $0.key == folderKey }), case .folder(var folder) = updated[i],
                  let source = folder.items.firstIndex(where: { $0.key == key }),
                  folder.items.indices.contains(index), source != index else { return }
            folder.items.insert(folder.items.remove(at: source), at: index)
            updated[i] = .folder(folder)
        } else {
            guard let source = updated.firstIndex(where: { $0.key == key }),
                  updated.indices.contains(index), source != index else { return }
            updated.insert(updated.remove(at: source), at: index)
        }
        savePins(updated)
    }

    func group(_ key: String, with target: String) {
        guard key != target, case .app(let item) = pins.first(where: { $0.key == key }) else { return }
        var updated = pins.filter { $0.key != key }
        guard let index = updated.firstIndex(where: { $0.key == target }) else { return }
        switch updated[index] {
        case .app(let other): updated[index] = .folder(StartFolder(items: [other, item]))
        case .folder(var folder):
            folder.items.append(item)
            updated[index] = .folder(folder)
        }
        savePins(updated)
    }

    func renameFolder(_ key: String, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = pins.firstIndex(where: { $0.key == key }),
              case .folder(var folder) = pins[index] else { return }
        folder.name = title
        var updated = pins
        updated[index] = .folder(folder)
        savePins(updated)
    }

    func extract(_ item: Item, from key: String) {
        guard let index = pins.firstIndex(where: { $0.key == key }), case .folder(var folder) = pins[index],
              let member = folder.items.firstIndex(where: { $0.key == item.key }) else { return }
        let extracted = folder.items.remove(at: member)
        var updated = pins
        updated.replaceSubrange(index...index, with: [Self.compacted(folder), .app(extracted)].compactMap { $0 })
        savePins(updated)
    }

    func dissolve(_ key: String) {
        guard let index = pins.firstIndex(where: { $0.key == key }), case .folder(let folder) = pins[index] else { return }
        var updated = pins
        updated.replaceSubrange(index...index, with: folder.items.map(StartPin.app))
        savePins(updated)
    }

    private func savePins(_ updated: [StartPin]) {
        guard pins != updated else { return }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey:pinKey)
        pins = updated
    }
}

enum LoginWindowAction {
    case sleep, restart, shutdown, logOut

    func perform() throws {
        NSApp.activate(ignoringOtherApps:true)
        let eventID: AEEventID
        switch self {
        case .logOut: eventID = AEEventID(kAELogOut)
        case .sleep: eventID = AEEventID(kAESleep)
        case .restart: eventID = AEEventID(kAEShowRestartDialog)
        case .shutdown: eventID = AEEventID(kAEShowShutdownDialog)
        }
        let event = NSAppleEventDescriptor(eventClass:AEEventClass(kCoreEventClass), eventID:eventID,
                                           targetDescriptor:NSAppleEventDescriptor(bundleIdentifier:"com.apple.loginwindow"),
                                           returnID:AEReturnID(kAutoGenerateReturnID), transactionID:AETransactionID(kAnyTransactionID))
        _ = try event.sendEvent(options:[.noReply,.canInteract], timeout:5)
    }
}

private struct StartUserLabel: View {
    private static let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    private static let picture: NSImage? = {
        guard let node = try? ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)),
              let user = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                          attributes: [kODAttributeTypeJPEGPhoto, kODAttributeTypePicture]) else { return nil }
        if let photos = try? user.values(forAttribute: kODAttributeTypeJPEGPhoto) as? [Data],
           let data = photos.first, let image = NSImage(data: data) { return image }
        if let paths = try? user.values(forAttribute: kODAttributeTypePicture) as? [String],
           let path = paths.first { return NSImage(contentsOfFile: path) }
        return nil
    }()

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let picture = Self.picture {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.primary.opacity(0.12))
                        Text(String(Self.name.prefix(1))).font(.caption.weight(.semibold))
                    }
                }
            }
            .frame(width: 26, height: 26).clipShape(Circle()).accessibilityHidden(true)
            Text(Self.name).font(.callout.weight(.medium)).lineLimit(1)
        }
    }
}

private struct StartFooterIcon: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        let outline = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content.frame(width: 32, height: 30)
            .background(outline.fill(Color.primary.opacity(hovered ? 0.09 : 0)))
            .overlay(outline.strokeBorder(Color.primary.opacity(hovered ? 0.2 : 0), lineWidth: 1)
                .allowsHitTesting(false))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct StartActionMenuButton: NSViewRepresentable {
    let title: String
    var symbol: String?
    let makeMenu: () -> NSMenu

    final class Coordinator: NSObject {
        var makeMenu: () -> NSMenu
        init(_ makeMenu: @escaping () -> NSMenu) { self.makeMenu = makeMenu }
        @objc func show(_ button: NSButton) {
            guard let window = button.window, let screen = window.screen else { return }
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = screen.visibleFrame
            let menu = makeMenu()
            let size = menu.size
            let x = max(visible.minX + 4, min(anchor.minX, visible.maxX - size.width - 4))
            let edge = (window as? SlidingShelfPanel)?.edge ?? .bottom
            let top = edge.menuTop(beside: anchor, height: size.height, visible: visible)
            let point = button.convert(window.convertPoint(fromScreen: NSPoint(x: x, y: top)), from: nil)
            menu.popUp(positioning: nil, at: point, in: button)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(makeMenu) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.title = ""
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.show(_:))
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            button.imagePosition = .imageOnly
        }
        button.contentTintColor = .labelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.makeMenu = makeMenu }
}

private struct StartBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfBackdrop { ShelfBackdrop(frame: .zero) }
    func updateNSView(_ view: ShelfBackdrop, context: Context) {}
}

private struct FolderZoom: AnimatableModifier {
    let icon: CGRect
    let size: CGSize
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let remaining = 1 - progress
        content
            .scaleEffect(x: progress + remaining * icon.width / max(1, size.width),
                         y: progress + remaining * icon.height / max(1, size.height), anchor: .topLeading)
            .offset(x: remaining * icon.minX, y: remaining * icon.minY)
            .opacity(min(1, progress * 1.6))
    }
}

struct StartMenu: View {
    @AppStorage("blurShelfBackground") private var blurBackground = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var library: StartLibrary
    let size: CGSize
    let launch: (Item) -> Void
    let remove: (Item) -> Void
    let browse: () -> Void
    let settings: () -> Void
    let accountMenu: () -> NSMenu
    let powerMenu: () -> NSMenu
    let focusSearch = PassthroughSubject<Void,Never>()
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var hover: String?
    @State private var folderKey: String?
    @State private var folderIcon = CGRect.zero
    @State private var editingName = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private func icon(_ item: Item, _ side: CGFloat) -> some View {
        Image(nsImage:NSWorkspace.shared.icon(forFile:item.path)).renderingMode(.original)
            .resizable().scaledToFit().frame(width:side,height:side)
    }

    private func row(_ item: Item) -> some View {
        let pinned = library.isPinned(item)
        let pinLabel = pinned ? "Открепить" : "Закрепить"
        return Button { launch(item) } label: {
            HStack(spacing:9) {
                icon(item,24)
                Text(item.name).lineLimit(1)
                Spacer(minLength:0)
            }
            .padding(.horizontal,7).frame(height:34)
            .background(MenuAppearance.selection(hover == "row"+item.key))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(item.name)
        .onHover { inside in updateHover("row"+item.key, inside) }
        .contextMenu {
            Button(pinLabel) { library.setPinned(item,!pinned) }
            Divider()
            Button("Удалить", role: .destructive) { remove(item) }
                .disabled(!StartLibrary.canTrash(item))
        }
    }

    private func updateHover(_ key: String, _ inside: Bool) {
        if inside { hover = key } else if hover == key { hover = nil }
    }

    private func folderHeader(_ folder: StartFolder, key: String) -> some View {
        HStack(spacing: 6) {
            Button {
                editingName = false
                withAnimation(folderAnimation) { folderKey = nil }
            } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Назад к закреплённым")
            if editingName {
                TextField("Название папки", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onAppear { nameFocused = true }
                    .onSubmit { finishRename(key) }
                    .onExitCommand { editingName = false }
                Button { finishRename(key) } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("Сохранить название")
            } else {
                Text(folder.name).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    draftName = folder.name
                    editingName = true
                } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Переименовать папку")
            }
        }.buttonStyle(.borderless).frame(height: 26)
    }

    private func finishRename(_ key: String) {
        library.renameFolder(key, to: draftName)
        editingName = false
    }

    private var folderAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.28)
    }

    private func pinList(_ entries: [StartPin], in key: String?, width: CGFloat, height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text("Нажмите правой кнопкой на программу и выберите «Закрепить».")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                }
                GeometryReader { grid in
                    let origin = grid.frame(in: .named("startPinnedArea")).origin
                    StartPinGrid(pins: entries, open: { pin, icon in
                        switch pin {
                        case .app(let item): launch(item)
                        case .folder:
                            folderIcon = icon.offsetBy(dx: origin.x, dy: origin.y)
                            editingName = false
                            withAnimation(folderAnimation) { folderKey = pin.key }
                        }
                    }, unpin: { library.setPinned($0, false) },
                       extract: key.map { key in { library.extract($0, from: key) } },
                       dissolve: library.dissolve, group: key == nil ? library.group : nil,
                       move: { library.movePin($0, to: $1, in: key) })
                }
                .frame(height: StartPinGrid.height(count: entries.count, width: width))
                Color.clear.frame(maxWidth: .infinity, minHeight: 12, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .contextMenu { if key == nil { Button("Добавить программу…", action: browse) } }
            }.frame(minHeight: max(0, height), alignment: .topLeading)
        }
    }

    private func pinnedArea(width: CGFloat, height: CGFloat) -> some View {
        let folder = library.folder(folderKey)
        return ZStack(alignment: .topLeading) {
            // Keep the source grid mounted so closing returns to the same scroll position.
            pinList(library.pins, in: nil, width: width, height: height)
                .opacity(folder == nil ? 1 : 0)
                .animation(.easeOut(duration: 0.12).delay(folder == nil && !reduceMotion ? 0.14 : 0),
                           value: folder != nil)
                .allowsHitTesting(folder == nil)
                .accessibilityHidden(folder != nil)
            if let folder, let key = folderKey {
                VStack(alignment: .leading, spacing: 8) {
                    folderHeader(folder, key: key).padding(.horizontal, 8).padding(.top, 5)
                    pinList(folder.items.map(StartPin.app), in: key, width: width, height: height - 39)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                .transition(reduceMotion ? .opacity : .modifier(
                    active: FolderZoom(icon: folderIcon, size: CGSize(width: width, height: height), progress: 0),
                    identity: FolderZoom(icon: folderIcon, size: CGSize(width: width, height: height), progress: 1)))
                .zIndex(1)
            }
        }
        .coordinateSpace(name: "startPinnedArea")
        .clipped()
    }

    var body: some View {
        let results = library.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:9) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Найти программу", text:$query).textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onAppear { searchFocused = true }
                    .onReceive(focusSearch) { _ in searchFocused = true }
            }
            .padding(10).background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.065)))
            .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.accentColor.opacity(searchFocused ? 0.65 : 0),lineWidth:1))
            .padding([.top,.horizontal],16).padding(.bottom,8)
            .background(MenuAppearance.wash(MenuAppearance.sky))

            HStack(alignment:.top,spacing:14) {
                VStack(alignment:.leading,spacing:8) {
                    Text("Все программы").font(.headline).frame(height:26)
                    ScrollView {
                        LazyVStack(spacing:1) {
                            ForEach(results, id:\.key) { row($0) }
                            if !query.isEmpty && results.isEmpty {
                                Text("Ничего не найдено").foregroundStyle(.secondary).padding(.top,8)
                            }
                        }
                    }
                }.frame(maxWidth:.infinity)
                Divider()
                GeometryReader { area in
                    pinnedArea(width: area.size.width, height: area.size.height)
                }.frame(maxWidth:.infinity)
            }.padding(16).frame(maxHeight:.infinity)
            Divider()
            HStack(spacing:8) {
                StartUserLabel().accessibilityHidden(true)
                    .padding(.horizontal, 5).frame(height: 32)
                    .background(MenuAppearance.selection(hover == "account"))
                    .overlay(StartActionMenuButton(title: "Меню пользователя, " + NSFullUserName(), makeMenu: accountMenu))
                    .onHover { updateHover("account", $0) }
                Spacer(minLength: 8)
                Button(action: settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(StartFooterIcon())
                .accessibilityLabel("Системные настройки")
                .help("Системные настройки")
                StartActionMenuButton(title: "Питание", symbol: "power", makeMenu: powerMenu).modifier(StartFooterIcon())
            }.padding(.horizontal,16).frame(height:46).background(Color.primary.opacity(0.04))
        }.frame(width:size.width,height:size.height)
        .background {
            if blurBackground && !reduceTransparency {
                StartBackdrop()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }
}
