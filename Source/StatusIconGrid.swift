import SwiftUI

struct StatusIconGrid: View {
    let entries: [Extra]
    let open: (Extra) -> Void
    let contextMenu: (Extra) -> NSMenu

    private let cell: CGFloat = 40
    private let spacing: CGFloat = 3
    private var columns: Int { max(1,min(entries.count,5)) }
    private var rows: Int { (entries.count + columns - 1) / columns }

    var size: NSSize {
        let visibleRows = min(rows,6)
        return NSSize(width:CGFloat(columns)*cell + CGFloat(columns-1)*spacing + 16,
                      height:CGFloat(visibleRows)*cell + CGFloat(visibleRows-1)*spacing + 16)
    }

    var body: some View {
        let layout = Array(repeating:GridItem(.fixed(cell),spacing:spacing),count:columns)
        let content = LazyVGrid(columns:layout,alignment:.leading,spacing:spacing) {
            ForEach(entries.indices,id:\.self) { index in
                let entry = entries[index]
                let name = entry.app.localizedName ?? entry.label
                StatusIconButton(entry: entry, name: name, open: { open(entry) },
                                 contextMenu: { contextMenu(entry) })
                    .frame(width: cell, height: cell)
            }
        }
        Group {
            if rows > 6 { ScrollView { content }.frame(height:6*cell+5*spacing) }
            else { content }
        }
        .frame(width:size.width-16,height:size.height-16)
        .padding(8)
        .background(MenuAppearance.wash(MenuAppearance.sky))
    }
}

private struct StatusIconButton: NSViewRepresentable {
    let entry: Extra
    let name: String
    let open: () -> Void
    let contextMenu: () -> NSMenu

    final class Button: ShelfButton {
        var onOpen: (() -> Void)?
        var makeMenu: (() -> NSMenu)?
        @objc func openIcon() { onOpen?() }
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = makeMenu?() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                super.mouseDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> Button {
        let button = Button(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = button
        button.action = #selector(Button.openIcon)
        return button
    }

    func updateNSView(_ button: Button, context: Context) {
        let icon = (entry.app.icon?.copy() as? NSImage) ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        icon?.size = NSSize(width: 24, height: 24)
        button.image = icon
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.onOpen = open
        button.makeMenu = contextMenu
    }
}
