import UIKit
import XCTest
@testable import ReadiumNavigator

@MainActor
final class EPUBPageTurnAnimatorTests: XCTestCase {
    func testCenterSpineLeavesRenderSeparatePhysicalHalves() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.blue.setFill(); context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        }
        let leaves = EPUBPageTurnAnimator.leaves(image, split: true)
        XCTAssertEqual(leaves.count, 2)
        for (index, leaf) in leaves.enumerated() {
            leaf.view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            leaf.view.layoutIfNeeded()
            let rendered = UIGraphicsImageRenderer(size: leaf.view.bounds.size).image { context in
                leaf.view.layer.render(in: context.cgContext)
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(rendered.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[index == 0 ? 0 : 2], 240)
            XCTAssertLessThan(pixel[index == 0 ? 2 : 0], 10, "Each leaf must contain only its physical half, not a scaled full spread")
        }
    }

    func testInteractiveCancellationDoesNotCommitAndCompletionCommitsOnce() async throws {
        for split in [false, true] {
            let parent = UIViewController()
            parent.view.frame = CGRect(x: 0, y: 0, width: 800, height: 700)
            let live = UIView(frame: parent.view.bounds); parent.view.addSubview(live)
            let image = UIGraphicsImageRenderer(size: parent.view.bounds.size).image { _ in }
            var commits = 0
            let turns = EPUBInteractivePageTurnController()
            turns.install(in: parent, liveView: live, current: image, previous: nil,
                          next: .init(image: image, commit: { commits += 1; return true }), centerSpine: split)
            let pager = try XCTUnwrap(turns.pager)
            XCTAssertEqual(pager.spineLocation, split ? .mid : .min)
            XCTAssertFalse(pager.gestureRecognizers.filter(\.isEnabled).isEmpty)
            XCTAssertTrue(pager.gestureRecognizers.allSatisfy { $0.view === parent.view })
            XCTAssertNil(turns.pageViewController(pager, viewControllerBefore: try XCTUnwrap(pager.viewControllers?.first)))
            let current = try XCTUnwrap(pager.viewControllers)
            let first = try XCTUnwrap(turns.pageViewController(pager, viewControllerAfter: try XCTUnwrap(current.last)))
            var next = [first]
            if split { next.append(try XCTUnwrap(turns.pageViewController(pager, viewControllerAfter: first))) }
            turns.pageViewController(pager, willTransitionTo: next)
            XCTAssertTrue(turns.busy)
            XCTAssertEqual(commits, 0)
            XCTAssertTrue(parent.view.subviews.last === pager.view)
            turns.pageViewController(pager, didFinishAnimating: true, previousViewControllers: current, transitionCompleted: false)
            XCTAssertEqual(commits, 0); XCTAssertFalse(turns.busy)
            XCTAssertTrue(parent.view.subviews.last === live)
            turns.pageViewController(pager, willTransitionTo: next)
            pager.setViewControllers(next, direction: .forward, animated: false)
            turns.pageViewController(pager, didFinishAnimating: true, previousViewControllers: current, transitionCompleted: true)
            for _ in 0..<30 where turns.busy { await Task.yield() }
            XCTAssertEqual(commits, 1); XCTAssertNil(turns.pager)
            turns.pageViewController(pager, didFinishAnimating: true, previousViewControllers: current, transitionCompleted: true)
            XCTAssertEqual(commits, 1, "Late UIKit callbacks cannot commit twice")
            XCTAssertTrue(parent.children.isEmpty)
        }
    }

    func testInteractiveInvalidationRejectsLateCompletion() async throws {
        let parent = UIViewController()
        parent.view.frame = CGRect(x: 0, y: 0, width: 800, height: 700)
        let live = UIView(frame: parent.view.bounds); parent.view.addSubview(live)
        let image = UIGraphicsImageRenderer(size: parent.view.bounds.size).image { _ in }
        let turns = EPUBInteractivePageTurnController()
        var commits = 0
        turns.install(in: parent, liveView: live, current: image, previous: nil,
                      next: .init(image: image, commit: { commits += 1; return true }), centerSpine: true)
        let pager = try XCTUnwrap(turns.pager)
        turns.pageViewController(pager, willTransitionTo: [])
        turns.invalidate()
        turns.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
        await Task.yield()
        XCTAssertEqual(commits, 0); XCTAssertFalse(turns.busy)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertTrue(parent.view.gestureRecognizers?.isEmpty ?? true)
    }

    func testFailedMoveLeavesNoOverlayAndUnlocksNextTurn() async {
        let parent = UIViewController()
        parent.view.frame = CGRect(x: 0, y: 0, width: 800, height: 700)
        let image = UIGraphicsImageRenderer(size: parent.view.bounds.size).image { context in
            UIColor.white.setFill()
            context.fill(parent.view.bounds)
        }
        let animator = EPUBPageTurnAnimator()
        let failed = await animator.turn(in: parent, centerSpine: true, direction: .forward,
                                         snapshot: { image }, move: { false })
        XCTAssertFalse(failed)
        XCTAssertFalse(animator.busy)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertTrue(parent.view.subviews.isEmpty)
        let moved = await animator.turn(in: parent, centerSpine: false, direction: .forward,
                                        snapshot: { nil }, move: { true })
        XCTAssertTrue(moved)
        XCTAssertFalse(animator.busy)
    }

    func testInvalidationWhileAwaitingMoveRemovesOverlayAndSkipsAnimation() async {
        let parent = UIViewController()
        parent.view.frame = CGRect(x: 0, y: 0, width: 800, height: 700)
        let image = UIGraphicsImageRenderer(size: parent.view.bounds.size).image { _ in }
        let animator = EPUBPageTurnAnimator()
        var resumeMove: CheckedContinuation<Bool, Never>?
        let task = Task {
            await animator.turn(in: parent, centerSpine: true, direction: .forward,
                                snapshot: { image }, move: {
                                    await withCheckedContinuation { resumeMove = $0 }
                                })
        }
        while resumeMove == nil { await Task.yield() }
        XCTAssertEqual(parent.view.subviews.count, 1)
        animator.invalidate()
        XCTAssertTrue(parent.view.subviews.isEmpty)
        resumeMove?.resume(returning: true)
        let moved = await task.value
        XCTAssertTrue(moved)
        XCTAssertFalse(animator.busy)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertTrue(parent.view.subviews.isEmpty)
    }
}
