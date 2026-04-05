import SwiftUI

struct WrappingHStack: Layout {
    typealias Cache = [CGRect]

    var alignment: HorizontalAlignment = .leading
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> [CGRect] {
        []
    }

    func updateCache(_ cache: inout [CGRect], subviews: Subviews) {
        cache.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [CGRect]
    ) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = arrangeRows(in: availableWidth, subviews: subviews)
        cache = rows.frames

        let width = rows.frames.map(\.maxX).max() ?? 0
        let height = rows.frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [CGRect]
    ) {
        if cache.count != subviews.count {
            let availableWidth = proposal.width ?? bounds.width
            let rows = arrangeRows(in: availableWidth, subviews: subviews)
            cache = rows.frames
        }

        for (index, subview) in subviews.enumerated() {
            guard cache.indices.contains(index) else { continue }
            let frame = cache[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrangeRows(in availableWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], totalHeight: CGFloat) {
        struct Row {
            var indices: [Int] = []
            var widths: [CGFloat] = []
            var heights: [CGFloat] = []

            var width: CGFloat {
                widths.reduce(0, +)
            }

            var height: CGFloat {
                heights.max() ?? 0
            }
        }

        let measured = subviews.map { $0.sizeThatFits(.unspecified) }
        let maxWidth = max(availableWidth, 1)

        var rows: [Row] = []
        var current = Row()
        var currentLineWidth: CGFloat = 0

        for (index, size) in measured.enumerated() {
            let spacing = current.indices.isEmpty ? 0 : horizontalSpacing
            let proposedWidth = min(size.width, maxWidth)

            if current.indices.isEmpty == false && currentLineWidth + spacing + proposedWidth > maxWidth {
                rows.append(current)
                current = Row()
                currentLineWidth = 0
            }

            current.indices.append(index)
            current.widths.append(proposedWidth)
            current.heights.append(size.height)
            currentLineWidth += (current.indices.count == 1 ? 0 : horizontalSpacing) + proposedWidth
        }

        if current.indices.isEmpty == false {
            rows.append(current)
        }

        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var yOffset: CGFloat = 0

        for row in rows {
            let totalRowWidth = row.width + CGFloat(max(row.indices.count - 1, 0)) * horizontalSpacing
            let xOrigin: CGFloat
            switch alignment {
            case .trailing:
                xOrigin = max(maxWidth - totalRowWidth, 0)
            case .center:
                xOrigin = max((maxWidth - totalRowWidth) / 2, 0)
            default:
                xOrigin = 0
            }

            var xOffset = xOrigin
            let rowHeight = row.height
            for (position, index) in row.indices.enumerated() {
                let width = row.widths[position]
                let height = row.heights[position]
                let y = yOffset + (rowHeight - height) / 2
                frames[index] = CGRect(x: xOffset, y: y, width: width, height: height)
                xOffset += width + horizontalSpacing
            }
            yOffset += rowHeight + verticalSpacing
        }

        if rows.isEmpty == false {
            yOffset -= verticalSpacing
        }

        return (frames, yOffset)
    }
}
