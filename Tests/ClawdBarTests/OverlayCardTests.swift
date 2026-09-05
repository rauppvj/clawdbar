import XCTest
import SwiftUI
@testable import ClawdBar

/// Pixel-level regression guard for the water leak: the tamagotchi page paints
/// a full-width water rect, and before `OverlayCard` clipped its content that
/// rect covered the card's rounded corner cut-outs — blue pixels outside the
/// panel silhouette, top and bottom.
@MainActor
final class OverlayCardTests: XCTestCase {

    private let side: CGFloat = 200

    func testFullTankLeavesCornersTransparent() async throws {
        let bitmap = try await render(level: 100)

        for (name, point) in bitmap.corners {
            let pixel = bitmap[point]
            XCTAssertLessThan(
                pixel.a, 24,
                "\(name) corner is outside the card's rounded shape — nothing may paint there (got \(pixel))"
            )
        }
    }

    func testFullTankStillFillsTheCardWithWater() async throws {
        let bitmap = try await render(level: 100)

        // Guards the test above against passing vacuously: the water has to be
        // there in the first place. Sampled near the bottom edge, below the
        // mascot, where the water body is solid.
        let bottom = bitmap[CGPoint(x: side / 2, y: 6)]
        XCTAssertGreaterThan(bottom.b, bottom.r, "expected water blue at the bottom of a full tank, got \(bottom)")
        XCTAssertGreaterThan(bottom.b, bottom.g, "expected water blue at the bottom of a full tank, got \(bottom)")
        XCTAssertGreaterThan(bottom.a, 200, "the card body must stay opaque")

        // And at 100% the water reaches the top rows too — the case where the
        // unclipped rect used to spill over the top corners.
        let top = bitmap[CGPoint(x: side / 2, y: side - 6)]
        XCTAssertGreaterThan(top.b, top.r, "expected water blue at the top of a full tank, got \(top)")
    }

    func testEmptyTankLeavesCornersTransparent() async throws {
        let bitmap = try await render(level: 0)
        for (name, point) in bitmap.corners {
            XCTAssertLessThan(bitmap[point].a, 24, "\(name) corner must stay clear with no water either")
        }
    }

    // MARK: - Rendering

    private func render(level: Double) async throws -> Bitmap {
        let usage = UsageData(
            sessionPercent: level, sessionResetAt: nil,
            weeklyPercent: level, weeklyResetAt: nil,
            lastUpdated: .now, isStale: false, rawHeaders: [:]
        )
        let daemon = UsageDaemon(
            client: MockUsageFetcher(behavior: .success(usage)),
            credentialStore: MockCredentialLoader(.success(MockCredentialLoader.dummy)),
            history: .temporary(), profileStore: NoProfileStore(),
            autoStart: false
        )
        // Populates `daemon.usage` through the real code path — the mock
        // client hands back the level we want the water at.
        await daemon.refreshNow()

        let card = OverlayCard { TamagotchiPage(daemon: daemon) }
            .frame(width: side, height: side)
            .colorScheme(.dark)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        return try Bitmap(image)
    }

    /// Minimal RGBA reader over a rendered `CGImage`, in SwiftUI-ish
    /// coordinates (origin bottom-left, points == pixels at scale 1).
    private struct Bitmap {
        let width: Int
        let height: Int
        private let pixels: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &buffer,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = buffer
        }

        struct Pixel: CustomStringConvertible {
            let r, g, b, a: Int
            var description: String { "rgba(\(r), \(g), \(b), \(a))" }
        }

        subscript(point: CGPoint) -> Pixel {
            let x = min(max(Int(point.x), 0), width - 1)
            let y = min(max(Int(point.y), 0), height - 1)
            let i = (y * width + x) * 4
            return Pixel(r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]), a: Int(pixels[i + 3]))
        }

        /// 4 pt in from each corner — comfortably outside an 18 pt radius.
        var corners: [(String, CGPoint)] {
            let inset: CGFloat = 4
            return [
                ("bottom-left",  CGPoint(x: inset, y: inset)),
                ("bottom-right", CGPoint(x: CGFloat(width) - inset, y: inset)),
                ("top-left",     CGPoint(x: inset, y: CGFloat(height) - inset)),
                ("top-right",    CGPoint(x: CGFloat(width) - inset, y: CGFloat(height) - inset)),
            ]
        }
    }
}
