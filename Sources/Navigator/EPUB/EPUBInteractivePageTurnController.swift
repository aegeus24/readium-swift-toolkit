// Copyright 2026 Readium Foundation. All rights reserved.
// BSD-style license: see LICENSE.
import UIKit

/// Native, reversible curls over bounded neighboring viewport snapshots. Live HTML
/// stays on top at rest; only a completed native transition commits navigation.
@MainActor final class EPUBInteractivePageTurnController: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    struct Page {
        let image: UIImage
        let commit: () async -> Bool
    }
    private final class Leaf: UIViewController {
        let index: Int
        init(index: Int, image: UIImage, split: Bool) {
            self.index = index
            super.init(nibName: nil, bundle: nil)
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            if split { imageView.layer.contentsRect = CGRect(x: CGFloat((index % 2 + 2) % 2) / 2, y: 0, width: 0.5, height: 1) }
            imageView.accessibilityElementsHidden = true
            view = imageView
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    private(set) var busy = false
    private(set) var pager: UIPageViewController?
    private weak var parent: UIViewController?
    private weak var liveView: UIView?
    private var pages: [Int: Page] = [:]
    private var split = false
    private var generation = 0
    private var commitTask: Task<Void, Never>?
    var canBegin: () -> Bool = { true }
    var didComplete: () -> Void = {}

    func install(in parent: UIViewController, liveView: UIView, current: UIImage, previous: Page?, next: Page?, centerSpine: Bool) {
        invalidate()
        self.parent = parent; self.liveView = liveView; split = centerSpine
        pages = [0: Page(image: current, commit: { false })]
        pages[-1] = previous; pages[1] = next
        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                        options: [.spineLocation: NSNumber(value: (split ? UIPageViewController.SpineLocation.mid : .min).rawValue)])
        self.pager = pager
        pager.isDoubleSided = split
        pager.view.backgroundColor = parent.view.backgroundColor
        pager.view.accessibilityElementsHidden = true
        pager.setViewControllers(initialLeaves(), direction: .forward, animated: false)
        pager.dataSource = self; pager.delegate = self
        parent.addChild(pager)
        pager.view.frame = parent.view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.insertSubview(pager.view, belowSubview: liveView)
        pager.didMove(toParent: parent)
        // Public UIKit API permits moving these recognizers to a containing view.
        // Native taps are disabled: Readium continues to filter links and edge taps.
        for gesture in pager.gestureRecognizers {
            parent.view.addGestureRecognizer(gesture)
            gesture.isEnabled = !(gesture is UITapGestureRecognizer)
        }
    }
    func setInputEnabled(_ enabled: Bool) {
        pager?.gestureRecognizers.forEach { $0.isEnabled = enabled && !($0 is UITapGestureRecognizer) }
    }
    func invalidate() {
        generation += 1
        commitTask?.cancel(); commitTask = nil
        guard let pager else { busy = false; pages.removeAll(); return }
        pager.dataSource = nil; pager.delegate = nil
        for gesture in pager.gestureRecognizers { gesture.view?.removeGestureRecognizer(gesture) }
        pager.willMove(toParent: nil); pager.view.removeFromSuperview(); pager.removeFromParent()
        self.pager = nil; pages.removeAll(); busy = false
    }
    private func leaf(_ index: Int) -> UIViewController? {
        let spread = split ? Int(floor(Double(index) / 2)) : index
        guard let page = pages[spread] else { return nil }
        return Leaf(index: index, image: page.image, split: split)
    }
    private func initialLeaves() -> [UIViewController] { (split ? [0, 1] : [0]).compactMap(leaf) }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard pageViewController === pager, let leaf = viewController as? Leaf else { return nil }
        return self.leaf(leaf.index - 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard pageViewController === pager, let leaf = viewController as? Leaf else { return nil }
        return self.leaf(leaf.index + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard pageViewController === pager else { return }
        guard canBegin(), !busy else { invalidate(); return }
        busy = true
        parent?.view.bringSubviewToFront(pageViewController.view)
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === pager, commitTask == nil else { return }
        guard completed, let index = pageViewController.viewControllers?.compactMap({ ($0 as? Leaf)?.index }).min() else {
            if let liveView { parent?.view.bringSubviewToFront(liveView) }
            pageViewController.setViewControllers(initialLeaves(), direction: .forward, animated: false)
            busy = false
            return
        }
        let spread = split ? Int(floor(Double(index) / 2)) : index
        guard spread != 0, let page = pages[spread] else {
            if let liveView { parent?.view.bringSubviewToFront(liveView) }
            pageViewController.setViewControllers(initialLeaves(), direction: .forward, animated: false)
            busy = false
            return
        }
        let revision = generation
        commitTask = Task { @MainActor [weak self] in
            _ = await page.commit()
            guard let self, revision == self.generation, !Task.isCancelled else { return }
            self.invalidate()
            self.didComplete()
        }
    }
}
