import SwiftUI
import Combine
import Carbon
import OpenDirectory

final class StartLibrary: ObservableObject {
    @Published private(set) var apps: [Item] = []
    @Published private(set) var pins: [Item]
    private let defaults: UserDefaults
    private let pinKey = "startMenuPins"
    private var scanGeneration = 0
    private var loading = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pins = defaults.data(forKey:pinKey).flatMap { try? JSONDecoder().decode([Item].self, from:$0) } ?? []
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
        if pins.contains(where: { $0.path == item.path }) {
            savePins(pins.filter { $0.path != item.path })
        }
        refresh()
    }

    func setPinned(_ item: Item, _ pinned: Bool) {
        guard pins.contains(where:{ $0.key == item.key }) != pinned else { return }
        var updated = pins.filter { $0.key != item.key }
        if pinned { updated.append(item) }
        savePins(updated)
    }

    func movePin(_ key: String, to index: Int) {
        guard let source = pins.firstIndex(where: { $0.key == key }),
              pins.indices.contains(index), source != index else { return }
        var updated = pins
        updated.insert(updated.remove(at: source), at: index)
        savePins(updated)
    }

    private func savePins(_ updated: [Item]) {
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

struct StartMenu: View {
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

    private func icon(_ item: Item, _ side: CGFloat) -> some View {
        Image(nsImage:NSWorkspace.shared.icon(forFile:item.path)).renderingMode(.original)
            .resizable().scaledToFit().frame(width:side,height:side)
    }

    private func row(_ item: Item) -> some View {
        let pinned = library.pins.contains { $0.key == item.key }
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
                    ScrollView {
                        VStack(alignment:.leading,spacing:0) {
                            if library.pins.isEmpty {
                                Text("Нажмите правой кнопкой на программу и выберите «Закрепить».")
                                    .font(.callout).foregroundStyle(.secondary).padding(.top,8)
                            }
                            StartPinGrid(pins: library.pins, launch: launch,
                                         unpin: { library.setPinned($0, false) }, move: library.movePin)
                                .frame(height: StartPinGrid.height(count: library.pins.count, width: area.size.width))
                            Color.clear.frame(maxWidth:.infinity,minHeight:12,maxHeight:.infinity)
                                .contentShape(Rectangle())
                                .contextMenu { Button("Добавить программу…", action:browse) }
                        }.frame(minHeight:area.size.height,alignment:.topLeading)
                    }
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
         .background(Color(nsColor:.windowBackgroundColor))
    }
}
