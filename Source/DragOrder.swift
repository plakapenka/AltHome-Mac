import Foundation

// Keep the user's relative order. Newly seen items enter beside their nearest known neighbor.
func arranged<Key: Hashable>(_ keys: [Key], preferred: [Key]) -> [Key] {
    guard !preferred.isEmpty else { return keys }
    let visible = Set(keys)
    var result = preferred.filter(visible.contains)
    let known = Set(result)
    var next: Key?
    for key in keys.reversed() {
        if !known.contains(key) {
            result.insert(key, at: next.flatMap { result.firstIndex(of: $0) } ?? result.count)
        }
        next = key
    }
    return result
}

func rememberedOrder(_ visible: [String], previous: [String]) -> [String] {
    let old = Set(previous)
    return arranged(previous + visible.filter { !old.contains($0) }, preferred: visible)
}

// Cross a neighbor's center before moving the slot, even when the two tiles have different widths.
func dragDestination(from source: Int, centers: [CGFloat], x: CGFloat) -> Int {
    if let right = centers.indices.last(where: { $0 > source && x >= centers[$0] }) { return right }
    return centers.indices.first(where: { $0 < source && x <= centers[$0] }) ?? source
}
