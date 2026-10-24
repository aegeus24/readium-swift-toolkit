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
