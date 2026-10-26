import SwiftUI

/// Whether a space follows this word (`LyricWord.spaceAfter`).
struct SpaceAfterKey: LayoutValueKey {
    static let defaultValue = true
}

/// Whether a line may wrap before this word: after a space, or between characters of a script
/// written without spaces. Syllables of one word (some word-timed lyrics split words) stay together.
struct BreakBeforeKey: LayoutValueKey {
    static let defaultValue = true
}

/// Lays words out like text: left to right, wrapping at `maxWidth`, each row centered. The words
/// are separate views so each can fill on its own as it's sung.
struct WordFlowLayout: Layout {
    /// Gap after a word followed by a space.
    var spacing: CGFloat
    /// Gap between rows.
    var lineSpacing: CGFloat
    /// Widest a row may be, however much room is offered; the layout is only as wide as its
    /// widest row, so a backdrop behind it hugs the words.
    var maxWidth: CGFloat = .infinity

    struct Row {
        var items: [(index: Int, size: CGSize, x: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: min(proposal.width ?? .infinity, maxWidth))
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        // Half a point of slack: bounds.width is the measured width, and rounding must not rewrap.
        for row in arrange(subviews, maxWidth: min(bounds.width + 0.5, maxWidth)) {
            let originX = bounds.minX + (bounds.width - row.width) / 2
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: originX + item.x, y: y + row.height - item.size.height),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
            }
            y += row.height + lineSpacing
        }
    }

    /// Greedy wrapping over clusters of words that can't be split.
    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var clusters: [[Int]] = []
        for index in subviews.indices {
            if index == 0 || subviews[index][BreakBeforeKey.self] || clusters.isEmpty {
                clusters.append([index])
            } else {
                clusters[clusters.count - 1].append(index)
            }
        }

        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        func gap(after index: Int) -> CGFloat { subviews[index][SpaceAfterKey.self] ? spacing : 0 }

        var rows: [Row] = []
        var row = Row()
        for cluster in clusters {
            var width: CGFloat = 0
            for (offset, index) in cluster.enumerated() {
                width += sizes[index].width + (offset < cluster.count - 1 ? gap(after: index) : 0)
            }
            let lead = row.items.last.map { gap(after: $0.index) } ?? 0
            if !row.items.isEmpty, row.width + lead + width > maxWidth {
                rows.append(row)
                row = Row()
            }
            var x = row.items.isEmpty ? 0 : row.width + lead
            for index in cluster {
                row.items.append((index, sizes[index], x))
                x += sizes[index].width + gap(after: index)
                row.height = max(row.height, sizes[index].height)
            }
            row.width = x - (cluster.last.map(gap(after:)) ?? 0)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
