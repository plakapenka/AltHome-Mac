import SwiftUI
import Carbon

final class StartLibrary: ObservableObject {
    @Published private(set) var apps: [Item] = []
    @Published private(set) var pins: [Item]
    private let defaults: UserDefaults
    private let pinKey = "startMenuPins"
    private var loading = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pins = defaults.data(forKey:pinKey).flatMap { try? JSONDecoder().decode([Item].self, from:$0) } ?? []
    }

    func refresh() {
        guard !loading else { return }
        loading = true
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
                self.apps = result
                self.loading = false
            }
        }
    }

    func setPinned(_ item: Item, _ pinned: Bool) {
        guard pins.contains(where:{ $0.key == item.key }) != pinned else { return }
        var updated = pins.filter { $0.key != item.key }
        if pinned { updated.append(item) }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey:pinKey)
        pins = updated
    }
}

enum StartPowerAction {
    case restart, shutdown

    func requestDialog() throws {
        NSApp.activate(ignoringOtherApps:true)
        let eventID = self == .restart ? kAEShowRestartDialog : kAEShowShutdownDialog
        let event = NSAppleEventDescriptor(eventClass:AEEventClass(kCoreEventClass), eventID:AEEventID(eventID),
                                           targetDescriptor:NSAppleEventDescriptor(bundleIdentifier:"com.apple.loginwindow"),
                                           returnID:AEReturnID(kAutoGenerateReturnID), transactionID:AETransactionID(kAnyTransactionID))
        _ = try event.sendEvent(options:[.noReply,.canInteract], timeout:5)
    }
}

struct StartMenu: View {
    @ObservedObject var library: StartLibrary
    let size: CGSize
    let launch: (Item) -> Void
    let browse: () -> Void
    let power: (StartPowerAction) -> Void
    @State private var query = ""
    @State private var hover: String?
    @State private var showPower = false

    private func icon(_ item: Item, _ side: CGFloat) -> some View {
        Image(nsImage:NSWorkspace.shared.icon(forFile:item.path)).renderingMode(.original)
            .resizable().scaledToFit().frame(width:side,height:side)
    }

    private func row(_ item: Item) -> some View {
        let pinned = library.pins.contains { $0.key == item.key }
        let pinLabel = pinned ? "Открепить" : "Закрепить"
        return HStack(spacing:3) {
            Button { launch(item) } label: {
                HStack(spacing:9) {
                    icon(item,24)
                    Text(item.name).lineLimit(1)
                    Spacer(minLength:0)
                }.contentShape(Rectangle())
            }.accessibilityLabel(item.name)
            Button { library.setPinned(item,!pinned) } label: {
                Image(systemName:pinned ? "pin.fill" : "pin").font(.system(size:12))
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
                    .frame(width:26,height:28).contentShape(Rectangle())
            }.help(pinLabel).accessibilityLabel(pinLabel + " " + item.name)
        }
        .buttonStyle(.plain).padding(.horizontal,7).frame(height:34)
        .background(RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(hover == "row"+item.key ? 0.09 : 0)))
        .onHover { inside in updateHover("row"+item.key, inside) }
        .contextMenu { Button(pinLabel) { library.setPinned(item,!pinned) } }
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
            }
            .padding(10).background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.065)))
            .padding([.top,.horizontal],16)

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
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Text("Закреплённые").font(.headline)
                        Spacer()
                        Button(action:browse) { Image(systemName:"plus").frame(width:26,height:26) }
                            .buttonStyle(.plain).help("Добавить программу…").accessibilityLabel("Добавить программу…")
                    }.frame(height:26)
                    if library.pins.isEmpty {
                        Text("Нажмите булавку рядом с программой.")
                            .font(.callout).foregroundStyle(.secondary).padding(.top,8)
                    }
                    ScrollView {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:72),spacing:4)],spacing:4) {
                            ForEach(library.pins,id:\.key) { item in
                                Button { launch(item) } label: {
                                    VStack(spacing:5) {
                                        icon(item,32)
                                        Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                    }.padding(5).frame(maxWidth:.infinity,minHeight:72,alignment:.top)
                                        .background(RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(hover == "pin"+item.key ? 0.09 : 0)))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel(item.name).help(item.name)
                                 .onHover { inside in updateHover("pin"+item.key, inside) }
                                 .contextMenu { Button("Открепить") { library.setPinned(item,false) } }
                            }
                        }
                    }
                }.frame(maxWidth:.infinity)
            }.padding(16).frame(maxHeight:.infinity)
            Divider()
            HStack(spacing:14) {
                Spacer()
                if showPower {
                    Button("Перезагрузить…") { power(.restart) }
                    Button("Выключить…") { power(.shutdown) }
                }
                Button { showPower.toggle() } label: {
                    Image(systemName:"power").font(.system(size:16,weight:.medium))
                        .frame(width:30,height:28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Питание").accessibilityLabel("Питание")
            }.padding(.horizontal,16).frame(height:46).background(Color.primary.opacity(0.04))
        }.frame(width:size.width,height:size.height)
         .background(Color(nsColor:.windowBackgroundColor))
    }
}
