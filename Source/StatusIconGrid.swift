import SwiftUI

struct StatusIconGrid: View {
    let entries: [Extra]
    let open: (Extra) -> Void
    @State private var hovered: Int?

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
                Button {
                    open(entry)
                } label: {
                    Group {
                        if let icon = entry.app.icon {
                            Image(nsImage:icon).renderingMode(.original).resizable().scaledToFit()
                        } else {
                            Image(systemName:"app").resizable().scaledToFit()
                        }
                    }
                    .frame(width:24,height:24)
                    .frame(width:cell,height:cell)
                    .background(RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(hovered == index ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(name))
                .help(name)
                .onHover { inside in
                    if inside { hovered = index }
                    else if hovered == index { hovered = nil }
                }
            }
        }
        Group {
            if rows > 6 { ScrollView { content }.frame(height:6*cell+5*spacing) }
            else { content }
        }
        .frame(width:size.width-16,height:size.height-16)
        .padding(8)
    }
}
