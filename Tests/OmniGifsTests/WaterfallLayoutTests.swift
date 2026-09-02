import AppKit
import Foundation
import Testing

@testable import OmniGifs

@MainActor
struct WaterfallLayoutTests {
    @Test func emptyDiffableDataSourceProducesAnEmptyLayout() {
        let layout = WaterfallLayout()
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 510, height: 600)
        )
        let dataSource = NSCollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { _, _, _ in nil }

        collectionView.collectionViewLayout = layout
        layout.prepare()

        #expect(dataSource.snapshot().sectionIdentifiers.isEmpty)
        #expect(layout.collectionViewContentSize.height >= 1)
        #expect(
            layout.layoutAttributesForElements(
                in: NSRect(x: 0, y: 0, width: 510, height: 600)
            ).isEmpty
        )
    }

    @Test func indexedVisibleLookupMatchesFullScan() {
        var columns = Array(repeating: [NSCollectionViewLayoutAttributes](), count: 2)
        var all: [NSCollectionViewLayoutAttributes] = []
        for item in 0..<846 {
            let column = item % 2
            let row = item / 2
            let attribute = NSCollectionViewLayoutAttributes(
                forItemWith: IndexPath(item: item, section: 0)
            )
            attribute.frame = NSRect(
                x: CGFloat(column * 260),
                y: CGFloat(row * 130),
                width: 250,
                height: 120
            )
            columns[column].append(attribute)
            all.append(attribute)
        }
        let rects = (0..<200).map { index in
            NSRect(x: 0, y: CGFloat((index * 31) % 53_000), width: 526, height: 530)
        }

        for rect in rects {
            let expected = Set(all.filter { $0.frame.intersects(rect) }.map(\.indexPath))
            let actual = Set(
                WaterfallLayout.visibleAttributes(
                    in: columns,
                    intersecting: rect
                ).map(\.indexPath))
            #expect(actual == expected)
        }

    }

    @Test func usesIntrinsicAspectRatiosWithA50PointMinimum() throws {
        let layout = WaterfallLayout()
        layout.sectionInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        layout.spacing = 10
        let fixture = LayoutFixture(aspectRatios: [2, 10, 0.5])
        let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 510, height: 600))
        collectionView.dataSource = fixture
        collectionView.collectionViewLayout = layout
        layout.delegate = fixture
        collectionView.reloadData()
        layout.prepare()

        let wide = try #require(
            layout.layoutAttributesForItem(
                at: IndexPath(item: 0, section: 0)
            ))
        let extremelyWide = try #require(
            layout.layoutAttributesForItem(
                at: IndexPath(item: 1, section: 0)
            ))
        let portrait = try #require(
            layout.layoutAttributesForItem(
                at: IndexPath(item: 2, section: 0)
            ))

        #expect(wide.frame.height == 125)
        #expect(extremelyWide.frame.height == 50)
        #expect(portrait.frame.height == 500)
    }
}

@MainActor
private final class LayoutFixture: NSObject, NSCollectionViewDataSource, WaterfallLayoutDelegate {
    let aspectRatios: [CGFloat]

    init(aspectRatios: [CGFloat]) {
        self.aspectRatios = aspectRatios
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        aspectRatios.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        NSCollectionViewItem()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        aspectRatioAt indexPath: IndexPath
    ) -> CGFloat {
        aspectRatios[indexPath.item]
    }
}
