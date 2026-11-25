import Foundation

struct StartFolder: Equatable, Codable {
    var id = UUID()
    var name = "Новая папка"
    var items: [Item]
}

enum StartPin: Equatable, Codable {
    case app(Item)
    case folder(StartFolder)

    var key: String {
        switch self {
        case .app(let item): return item.key
        case .folder(let folder): return "folder:" + folder.id.uuidString
        }
    }

    var name: String {
        switch self {
        case .app(let item): return item.name
        case .folder(let folder): return folder.name
        }
    }

    var items: [Item] {
        switch self {
        case .app(let item): return [item]
        case .folder(let folder): return folder.items
        }
    }
}
