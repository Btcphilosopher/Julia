1. Core latency engine
import Foundation
import Photos
import UIKit

final class AureomPhotoLatencyEngine: NSObject {

    private let imageManager = PHCachingImageManager()

    private(set) var assets:
        PHFetchResult<PHAsset>?

    private let processingQueue =
        DispatchQueue(
            label: "ai.aureom.photos.processing",
            qos: .userInitiated
        )

    private let cacheQueue =
        DispatchQueue(
            label: "ai.aureom.photos.cache",
            qos: .utility
        )

    private var imageRequests:
        [IndexPath: PHImageRequestID] = [:]

    private var currentPreheatRect =
        CGRect.zero

    private var currentTargetSize =
        CGSize.zero

    override init() {

        super.init()

        PHPhotoLibrary.shared()
            .register(self)
    }

    deinit {

        PHPhotoLibrary.shared()
            .unregisterChangeObserver(self)

        imageManager
            .stopCachingImagesForAllAssets()
    }
}
2. Photo-library access
extension AureomPhotoLatencyEngine {

    func requestAccess() async -> Bool {

        let status =
            await PHPhotoLibrary
                .requestAuthorization(
                    for: .readWrite
                )

        switch status {

        case .authorized,
             .limited:

            return true

        default:

            return false
        }
    }
}

This deliberately supports Apple's limited Photos-library permission model rather than assuming the app can see everything.

3. Fast asset indexing
extension AureomPhotoLatencyEngine {

    func loadPhotos() {

        processingQueue.async { [weak self] in

            guard let self else {
                return
            }

            let options =
                PHFetchOptions()

            options.sortDescriptors = [
                NSSortDescriptor(
                    key: "creationDate",
                    ascending: false
                )
            ]

            options.fetchLimit = 0

            let result =
                PHAsset.fetchAssets(
                    with: .image,
                    options: options
                )

            DispatchQueue.main.async {

                self.assets = result
            }
        }
    }
}

For a real photo browser, I'd fetch both images and videos, but keeping the fetch result metadata-only is important. Don't request image pixels during indexing.

4. The important part: predictive prefetching

Apple's PHCachingImageManager is designed specifically to prepare images before they're requested, and Apple's own Photos browsing guidance uses a preheat rectangle that follows the collection view's scrolling position.

Here's the engine:

extension AureomPhotoLatencyEngine {

    func updatePreheat(
        visibleRect: CGRect,
        scrollVelocity: CGFloat,
        collectionViewWidth: CGFloat,
        collectionViewHeight: CGFloat
    ) {

        guard
            let assets,
            assets.count > 0
        else {
            return
        }

        let direction =
            scrollVelocity >= 0 ? 1.0 : -1.0

        let multiplier =
            min(
                max(
                    abs(scrollVelocity) / 800.0,
                    1.5
                ),
                5.0
            )

        let preheatDistance =
            collectionViewHeight * multiplier

        var preheatRect =
            visibleRect

        if direction > 0 {

            preheatRect =
                visibleRect.insetBy(
                    dx: 0,
                    dy: -preheatDistance
                )

        } else {

            preheatRect =
                visibleRect.insetBy(
                    dx: 0,
                    dy: -preheatDistance
                )
        }

        let targetSize =
            CGSize(
                width:
                    collectionViewWidth * 2.0,
                height:
                    collectionViewHeight * 2.0
            )

        updateCache(
            preheatRect: preheatRect,
            targetSize: targetSize
        )
    }
}

I'd make the next version more sophisticated by having the engine predict the next N rows, rather than merely enlarging a rectangle.

5. Cache management
private extension AureomPhotoLatencyEngine {

    func updateCache(
        preheatRect: CGRect,
        targetSize: CGSize
    ) {

        guard
            let assets
        else {
            return
        }

        let changed =
            preheatRect != currentPreheatRect ||
            targetSize != currentTargetSize

        guard changed else {
            return
        }

        currentPreheatRect =
            preheatRect

        currentTargetSize =
            targetSize

        let indexes =
            indexesForRect(
                preheatRect,
                assetCount: assets.count
            )

        let objects =
            indexes.map {
                assets.object(at: $0)
            }

        cacheQueue.async { [weak self] in

            guard let self else {
                return
            }

            self.imageManager
                .startCachingImages(
                    for: objects,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: self.thumbnailOptions()
                )
        }
    }

    func indexesForRect(
        _ rect: CGRect,
        assetCount: Int
    ) -> [Int] {

        // Replace with the collection-view's actual
        // layout mapping in production.

        let rowHeight: CGFloat = 150

        let firstRow =
            max(
                Int(rect.minY / rowHeight),
                0
            )

        let lastRow =
            min(
                Int(rect.maxY / rowHeight) + 1,
                assetCount
            )

        return Array(
            firstRow..<lastRow
        )
    }

    func thumbnailOptions()
        -> PHImageRequestOptions {

        let options =
            PHImageRequestOptions()

        options.deliveryMode =
            .opportunistic

        options.resizeMode =
            .fast

        options.isNetworkAccessAllowed =
            true

        return options
    }
}

The key idea is:

scroll slowly
    → small preheat region

scroll quickly
    → large predictive preheat region

stop scrolling
    → high-quality requests

That prevents the classic problem where the app tries to decode dozens of enormous images while the user is rapidly scrolling.

6. Ultra-low-latency thumbnail requests
extension AureomPhotoLatencyEngine {

    func requestThumbnail(
        at indexPath: IndexPath,
        targetSize: CGSize,
        completion:
        @escaping (UIImage?) -> Void
    ) {

        guard
            let assets,
            indexPath.item < assets.count
        else {
            completion(nil)
            return
        }

        let asset =
            assets.object(
                at: indexPath.item
            )

        let options =
            PHImageRequestOptions()

        options.deliveryMode =
            .opportunistic

        options.resizeMode =
            .fast

        options.isNetworkAccessAllowed =
            true

        let requestID =
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, info in

                DispatchQueue.main.async {

                    completion(image)

                    if let self {

                        self.imageRequests[
                            indexPath
                        ] = nil
                    }
                }
            }

        imageRequests[indexPath] =
            requestID
    }
}

PHCachingImageManager can return prepared thumbnails, and Apple's current sample uses it to populate scrolling photo grids.

7. Cancel obsolete requests

This is an underrated latency optimisation.

extension AureomPhotoLatencyEngine {

    func cancelRequest(
        at indexPath: IndexPath
    ) {

        guard
            let requestID =
                imageRequests[indexPath]
        else {
            return
        }

        imageManager
            .cancelImageRequest(
                requestID
            )

        imageRequests[indexPath] =
            nil
    }

    func cancelAllRequests() {

        for requestID
            in imageRequests.values {

            imageManager
                .cancelImageRequest(
                    requestID
                )
        }

        imageRequests.removeAll()
    }
}

If the user flicks from photo 100 to photo 10, there's no reason to keep decoding photos 101–150.

8. Adaptive quality

I'd make the engine dynamically choose image quality.

enum PhotoQualityMode {

    case scrolling
    case settling
    case selected
    case editing
}

Then:

extension AureomPhotoLatencyEngine {

    func options(
        for mode: PhotoQualityMode
    ) -> PHImageRequestOptions {

        let options =
            PHImageRequestOptions()

        switch mode {

        case .scrolling:

            options.deliveryMode =
                .fast

            options.resizeMode =
                .fast

            options.isNetworkAccessAllowed =
                false

        case .settling:

            options.deliveryMode =
                .opportunistic

            options.resizeMode =
                .fast

            options.isNetworkAccessAllowed =
                true

        case .selected:

            options.deliveryMode =
                .highQualityFormat

            options.resizeMode =
                .exact

            options.isNetworkAccessAllowed =
                true

        case .editing:

            options.deliveryMode =
                .highQualityFormat

            options.resizeMode =
                .exact

            options.isNetworkAccessAllowed =
                true
        }

        return options
    }
}

That gives you a very Apple-like progression:

             USER SCROLLS
                  │
                  ▼
          LOW LATENCY IMAGE
                  │
                  ▼
            USER STOPS
                  │
                  ▼
        HIGHER QUALITY IMAGE
                  │
                  ▼
           USER OPENS PHOTO
                  │
                  ▼
          FULL QUALITY IMAGE
9. Photo library change intelligence

Don't repeatedly rescan the entire library.

PhotoKit provides change observation and persistent change tokens specifically so an application can keep its model synchronized with the library.

extension AureomPhotoLatencyEngine:
    PHPhotoLibraryChangeObserver {

    func photoLibraryDidChange(
        _ changeInstance: PHChange
    ) {

        guard
            let assets
        else {
            return
        }

        guard
            let details =
                changeInstance.changeDetails(
                    for: assets
                )
        else {
            return
        }

        let updated =
            details.fetchResultAfterChanges

        DispatchQueue.main.async { [weak self] in

            self?.assets = updated
        }
    }
}

This means:

Photos changes
      ↓
PhotoKit notification
      ↓
Aureom updates affected model
      ↓
invalidate only affected thumbnails

rather than:

Photos changes
      ↓
rescan 80,000 photos
      ↓
freeze UI
10. The "Julia brain"

This is where I'd connect your previous Julia work.

Swift handles the real-time PhotoKit machinery:

PhotoKit
AVFoundation
Core Image
Metal
SwiftUI

Julia handles prediction:

Which photos will probably be viewed next?

How much cache should be allocated?

Which thumbnails deserve high priority?

Is the user scrolling rapidly or browsing carefully?

Which assets are likely to be requested next?

How aggressively should we prefetch?

A Julia model could receive:

struct PhotoAccessEvent

    timestamp::Float64

    asset_index::Int

    scroll_velocity::Float64

    direction::Float64

    visible_count::Int

end

and calculate:

function prefetch_depth(
    velocity,
    visible_count
)

    speed =
        abs(velocity)

    multiplier =
        clamp(
            1.0 + speed / 600.0,
            1.0,
            8.0
        )

    return round(
        Int,
        visible_count * multiplier
    )
end

So if you're browsing:

slow:
20 photos visible
→ prefetch 30

medium:
20 visible
→ prefetch 60

fast:
20 visible
→ prefetch 120

But it can become much smarter by learning your browsing pattern.

For example:

User repeatedly opens:
  photos from 2026
  photos near current date
  portrait photos
  recent screenshots

Julia learns:
  P(next asset) distribution

Then prefetch becomes probabilistic rather than purely geometric.

