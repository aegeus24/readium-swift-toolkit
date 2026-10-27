// Copyright 2026 Readium Foundation. All rights reserved.
// BSD-style license: see LICENSE.
import UIKit

/// A rolling native pager. Raster pages advance independently of the serialized
/// live-HTML synchronization, so a second cached turn never waits on WebKit.
@MainActor final class EPUBInteractivePageTurnController: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    struct Page {
        let image: UIImage
        let commit: () async -> Bool
        var byteCount: Int { image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }
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
    static let radius = 2
    static let byteLimit = 64 * 1024 * 1024
    private(set) var busy = false
    private(set) var pager: UIPageViewController?
    private(set) var currentIndex = 0
    private(set) var synchronizedIndex = 0
    private(set) var synchronizationTask: Task<Void, Never>?
    var hasPendingSynchronization: Bool { synchronizationTask != nil || currentIndex != synchronizedIndex }
    var cachedIndices: Set<Int> { Set(pages.keys) }
    var cachedImageBytes: Int { pages.values.reduce(0) { $0 + $1.byteCount } }
    private weak var parent: UIViewController?
    private weak var liveView: UIView?
    private var pages: [Int: Page] = [:]
    private var leavesInUse = NSHashTable<Leaf>.weakObjects()
    private var split = false
    private var generation = 0
    private var transitionStart = 0
    private var pendingIndex: Int?
    private var overlayTap: UITapGestureRecognizer?
    private var cancelProgrammaticTurn: (() -> Void)?
    var canBegin: () -> Bool = { true }
    var didComplete: () -> Void = {}

    func install(in parent: UIViewController, liveView: UIView, current: UIImage, previous: Page?, next: Page?, centerSpine: Bool, currentCommit: @escaping () async -> Bool = { false }) {
        invalidate()
        self.parent = parent; self.liveView = liveView; split = centerSpine
        currentIndex = 0; synchronizedIndex = 0
        pages = [0: Page(image: current, commit: currentCommit)]
        pages[-1] = previous; pages[1] = next
        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                        options: [.spineLocation: NSNumber(value: (split ? UIPageViewController.SpineLocation.mid : .min).rawValue)])
        self.pager = pager
        // Expanded spreads provide real printed front/back leaves. Compact
        // mode uses UIKit's native paper reverse without advancing two pages.
        pager.loadViewIfNeeded()
        pager.isDoubleSided = split
        pager.view.backgroundColor = parent.view.backgroundColor
        pager.view.accessibilityElementsHidden = true
        pager.setViewControllers(leaves(at: 0), direction: .forward, animated: false)
        pager.dataSource = self; pager.delegate = self
        parent.addChild(pager)
        pager.view.frame = parent.view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.insertSubview(pager.view, belowSubview: liveView)
        pager.didMove(toParent: parent)
        for gesture in pager.gestureRecognizers {
            parent.view.addGestureRecognizer(gesture)
            gesture.isEnabled = !(gesture is UITapGestureRecognizer)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedCache(_:)))
        pager.view.addGestureRecognizer(tap)
        overlayTap = tap
    }
    func insert(_ page: Page, at index: Int) {
        guard pager != nil else { return }
        pages[index] = page
        for leaf in leavesInUse.allObjects where spreadIndex(for: leaf.index) == index {
            (leaf.view as? UIImageView)?.image = page.image
        }
        trim()
    }
    func trim(radius: Int = EPUBInteractivePageTurnController.radius) {
        let protected = Set([currentIndex, synchronizedIndex, pendingIndex].compactMap { $0 })
        for index in pages.keys where abs(index - currentIndex) > radius && !protected.contains(index) { pages[index] = nil }
        for index in pages.keys.sorted(by: { abs($0 - currentIndex) > abs($1 - currentIndex) }) {
            guard cachedImageBytes > Self.byteLimit else { break }
            if !protected.contains(index) { pages[index] = nil }
        }
    }
    func setInputEnabled(_ enabled: Bool) {
        pager?.gestureRecognizers.forEach { $0.isEnabled = enabled && !($0 is UITapGestureRecognizer) }
    }
    func invalidate() {
        generation += 1
        cancelProgrammaticTurn?(); cancelProgrammaticTurn = nil
        synchronizationTask?.cancel(); synchronizationTask = nil
        if let pager {
            pager.dataSource = nil; pager.delegate = nil
            for gesture in pager.gestureRecognizers { gesture.view?.removeGestureRecognizer(gesture) }
            pager.willMove(toParent: nil); pager.view.removeFromSuperview(); pager.removeFromParent()
        }
        pager = nil; overlayTap = nil; pages.removeAll(); leavesInUse.removeAllObjects(); busy = false; pendingIndex = nil
        currentIndex = 0; synchronizedIndex = 0
    }
    private func spreadIndex(for leaf: Int) -> Int {
        split ? Int(floor(Double(leaf) / 2)) : leaf
    }
    private func leaf(_ index: Int) -> UIViewController? {
        guard let page = pages[spreadIndex(for: index)] else { return nil }
        let leaf = Leaf(index: index, image: page.image, split: split)
        leavesInUse.add(leaf)
        return leaf
    }
    private func leaves(at index: Int) -> [UIViewController] {
        (split ? [index * 2, index * 2 + 1] : [index]).compactMap(leaf)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard pageViewController === pager, let leaf = viewController as? Leaf else { return nil }
        let index = leaf.index - 1
        return self.leaf(index)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard pageViewController === pager, let leaf = viewController as? Leaf else { return nil }
        return self.leaf(leaf.index + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard pageViewController === pager, !busy else { return }
        guard canBegin() else { setInputEnabled(false); return }
        transitionStart = currentIndex; busy = true
        if let index = pendingViewControllers.compactMap({ ($0 as? Leaf)?.index }).min() {
            pendingIndex = spreadIndex(for: index)
        }
        parent?.view.bringSubviewToFront(pageViewController.view)
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === pager, busy else { return }
        if let previous = previousViewControllers.compactMap({ ($0 as? Leaf)?.index }).min(),
           spreadIndex(for: previous) != transitionStart { return }
        let front = pageViewController.viewControllers?.compactMap { ($0 as? Leaf)?.index }.min()
        let target = front.map { spreadIndex(for: $0) } ?? transitionStart
        if completed, target != transitionStart, pages[target] != nil { complete(target) }
        else {
            currentIndex = transitionStart; busy = false; pendingIndex = nil
            pageViewController.setViewControllers(leaves(at: currentIndex), direction: .forward, animated: false)
            revealLiveIfReady()
        }
    }
    @discardableResult func turn(right: Bool) async -> Bool {
        guard let pager, !busy, canBegin(), pages[currentIndex + (right ? 1 : -1)] != nil else { return false }
        let target = currentIndex + (right ? 1 : -1)
        busy = true; transitionStart = currentIndex; pendingIndex = target
        parent?.view.bringSubviewToFront(pager.view)
        let revision = generation
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Bool) -> Void = { moved in
                guard !resumed else { return }
                resumed = true; continuation.resume(returning: moved)
            }
            self.cancelProgrammaticTurn = { finish(false) }
            pager.setViewControllers(leaves(at: target), direction: right ? .forward : .reverse, animated: true) { [weak self] finished in
                guard let self, revision == self.generation else { finish(false); return }
                self.cancelProgrammaticTurn = nil
                if finished { self.complete(target) }
                else { self.busy = false; self.pendingIndex = nil; self.revealLiveIfReady() }
                finish(finished)
            }
        }
    }
    @objc private func tappedCache(_ tap: UITapGestureRecognizer) {
        guard let view = pager?.view, !busy else { return }
        let x = tap.location(in: view).x, edge = min(max(44, view.bounds.width * 0.2), view.bounds.width / 3)
        if x <= edge || x >= view.bounds.width - edge { Task { await turn(right: x >= view.bounds.midX) } }
    }
    private func complete(_ index: Int) {
        guard busy || index != currentIndex else { return }
        currentIndex = index; busy = false; pendingIndex = nil
        trim()
        didComplete()
        synchronize()
    }
    private func synchronize() {
        guard synchronizationTask == nil, currentIndex != synchronizedIndex else { revealLiveIfReady(); return }
        let revision = generation
        synchronizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while revision == self.generation, !Task.isCancelled, self.currentIndex != self.synchronizedIndex {
                let target = self.currentIndex
                guard let page = self.pages[target] else { break }
                let moved = await page.commit()
                guard revision == self.generation, !Task.isCancelled else { return }
                guard moved else {
                    self.currentIndex = self.synchronizedIndex
                    if !self.busy { self.pager?.setViewControllers(self.leaves(at: self.currentIndex), direction: .reverse, animated: false) }
                    break
                }
                self.synchronizedIndex = target
            }
            guard revision == self.generation else { return }
            self.synchronizationTask = nil
            self.trim(); self.revealLiveIfReady()
            self.didComplete()
        }
    }
    private func revealLiveIfReady() {
        guard !busy, !hasPendingSynchronization, let liveView else { return }
        parent?.view.bringSubviewToFront(liveView)
    }
    func waitUntilSynchronized() async {
        while let task = synchronizationTask { await task.value }
    }
}
