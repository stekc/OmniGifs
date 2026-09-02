import AppKit

@MainActor
protocol WaterfallLayoutDelegate: AnyObject {
    func collectionView(
        _ collectionView: NSCollectionView,
        aspectRatioAt indexPath: IndexPath
    ) -> CGFloat
}

final class WaterfallLayout: NSCollectionViewLayout {
    weak var delegate: WaterfallLayoutDelegate?

    var columnCount = 2
    var spacing: CGFloat = 10
    var sectionInsets = NSEdgeInsets(top: 10, left: 10, bottom: 14, right: 10)

    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var attributesByColumn: [[NSCollectionViewLayoutAttributes]] = []
    private var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat = 0
    private var preparedItemCount = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let itemCount: Int
        if collectionView.dataSource != nil, collectionView.numberOfSections > 0 {
            itemCount = collectionView.numberOfItems(inSection: 0)
        } else {
            itemCount = 0
        }
        if abs(width - preparedWidth) < 0.5,
            itemCount == preparedItemCount,
            !attributes.isEmpty
        {
            return
        }

        preparedWidth = width
        preparedItemCount = itemCount
        attributes.removeAll(keepingCapacity: true)
        let columns = max(columnCount, 1)
        attributesByColumn = Array(repeating: [], count: columns)
        let usableWidth =
            width - sectionInsets.left - sectionInsets.right
            - CGFloat(columns - 1) * spacing
        let itemWidth = floor(usableWidth / CGFloat(columns))
        var columnHeights = Array(repeating: sectionInsets.top, count: columns)

        attributes.reserveCapacity(itemCount)
        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let ratio = max(
                delegate?.collectionView(collectionView, aspectRatioAt: indexPath) ?? 1,
                0.25
            )
            // Discord's picker gives each masonry tile its intrinsic media
            // aspect ratio and does not cap portrait items. A height cap makes
            // the card wider than its media and exposes letterbox gutters.
            let itemHeight = max(round(itemWidth / ratio), 50)
            let column =
                columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let x = sectionInsets.left + CGFloat(column) * (itemWidth + spacing)
            let y = columnHeights[column]

            let itemAttributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            itemAttributes.frame = NSRect(x: x, y: y, width: itemWidth, height: itemHeight)
            attributes.append(itemAttributes)
            attributesByColumn[column].append(itemAttributes)
            columnHeights[column] = itemAttributes.frame.maxY + spacing
        }

        contentHeight = (columnHeights.max() ?? 0) + sectionInsets.bottom - spacing
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: collectionView?.bounds.width ?? 0, height: max(contentHeight, 1))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes]
    {
        Self.visibleAttributes(in: attributesByColumn, intersecting: rect)
    }

    static func visibleAttributes(
        in columns: [[NSCollectionViewLayoutAttributes]],
        intersecting rect: NSRect
    ) -> [NSCollectionViewLayoutAttributes] {
        columns.flatMap { column in
            var lower = 0
            var upper = column.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if column[middle].frame.maxY < rect.minY {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            var visible: [NSCollectionViewLayoutAttributes] = []
            var index = lower
            while index < column.count, column[index].frame.minY <= rect.maxY {
                if column[index].frame.intersects(rect) { visible.append(column[index]) }
                index += 1
            }
            return visible
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath)
        -> NSCollectionViewLayoutAttributes?
    {
        guard indexPath.item < attributes.count else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    override func invalidateLayout() {
        attributes.removeAll(keepingCapacity: true)
        attributesByColumn.removeAll(keepingCapacity: true)
        preparedItemCount = 0
        super.invalidateLayout()
    }
}
