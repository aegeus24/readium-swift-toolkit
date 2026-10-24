// Copyright 2026 Readium Foundation. All rights reserved.
// Use of this source code is governed by the BSD-style license in LICENSE.

import UIKit

/// Animation used for paginated navigation. Continuous scrolling remains live.
public enum EPUBPageTurnStyle: Equatable {
    case slide, curl, instant
}

/// Short-lived raster leaves over the live HTML navigator. The navigator is
/// never replaced: selection, links and accessibility return when the turn ends.
@MainActor final class EPUBPageTurnAnimator {
    private(set) var busy = false
    private var generation = 0
    private var overlay: UIView?
    private var controller: UIPageViewController?
    private var finishAnimation: (() -> Void)?
    private var animationTimeout: Task<Void, Never>?

    func invalidate() {
        generation += 1
        finishAnimation?()
        removeOverlay()
    }

    private func removeOverlay() {
        controller?.willMove(toParent: nil)
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
        controller = nil
        overlay?.removeFromSuperview()
        overlay = nil
    }

    func turn(in parent: UIViewController, centerSpine: Bool, direction: UIPageViewController.NavigationDirection,
              snapshot: () async -> UIImage?, move: () async -> Bool) async -> Bool {
        guard !busy else { return false }
        busy = true
        let revision = generation
        let size = parent.view.bounds.size
        defer {
            animationTimeout?.cancel(); animationTimeout = nil
            finishAnimation = nil
            removeOverlay(); busy = false
        }
        guard let before = await snapshot(), revision == generation else { return await move() }
        let cover = UIImageView(image: before)
        cover.frame = parent.view.bounds
        cover.isUserInteractionEnabled = true
        cover.isAccessibilityElement = false
        parent.view.addSubview(cover)
        overlay = cover
        let moved = await move()
        guard moved, revision == generation, size == parent.view.bounds.size,
              let after = await snapshot(), revision == generation else { return moved }

        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                        options: [.spineLocation: NSNumber(value: (centerSpine ? UIPageViewController.SpineLocation.mid : .min).rawValue)])
        pager.isDoubleSided = centerSpine
        pager.view.backgroundColor = parent.view.backgroundColor
        // These controllers are animation surfaces, not alternate accessibility content.
        pager.view.accessibilityElementsHidden = true
        pager.view.isUserInteractionEnabled = false
        pager.setViewControllers(Self.leaves(before, split: centerSpine), direction: direction, animated: false)
        parent.addChild(pager)
        pager.view.frame = parent.view.bounds
        parent.view.addSubview(pager.view)
        pager.didMove(toParent: parent)
        controller = pager
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            finishAnimation = finish
            pager.setViewControllers(Self.leaves(after, split: centerSpine), direction: direction, animated: true) { _ in finish() }
            // UIKit may omit completion when a containing view is dismissed/resized.
            animationTimeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                finish()
            }
        }
        return moved
    }

    static func leaves(_ image: UIImage, split: Bool) -> [UIViewController] {
        let ranges: [CGRect] = split
            ? [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
            : [CGRect(x: 0, y: 0, width: 1, height: 1)]
        return ranges.map { range in
            let controller = UIViewController()
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            imageView.layer.contentsRect = range
            controller.view = imageView
            return controller
        }
    }
}
