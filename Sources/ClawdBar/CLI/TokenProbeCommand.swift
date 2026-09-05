import Foundation
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `ClawdBar --probe-tokens` — prints what the transcript scanner sees.
/// Useful for checking the numbers against `ccusage` without opening the app,
/// and for timing a cold vs warm scan.
enum TokenProbeCommand {
    static let flag = "--probe-tokens"

    static func run() -> Int32 {
        let scanner = TokenUsageScanner()
        print("ClawdBar token probe")
        print("====================")
        print("Transcripts : \(scanner.configuration.projectsDirectory.path)")
        print("Cache       : \(scanner.configuration.cacheURL.path)")
        print("Retention   : \(scanner.configuration.retentionDays) days")
        print("")

        let started = Date()
        let summary: TokenUsageSummary
        do {
            summary = try scanner.scan()
        } catch {
            print("Result: FAILED")
            print("Reason: \(error)")
            return 1
        }
        let elapsed = Date().timeIntervalSince(started)

        print(String(format: "Scanned %d transcript files in %.2fs", summary.filesSeen, elapsed))
        print("Days with data: \(summary.days.count)")
        print("")
        print("DAY              FRESH     INPUT    OUTPUT   CACHE W   CACHE R     TOTAL     TURNS")
        for day in summary.window(days: 14) {
            let counts = day.totals
            let columns = [
                TokenUsageFormat.compact(counts.fresh),
                TokenUsageFormat.compact(counts.input),
                TokenUsageFormat.compact(counts.output),
                TokenUsageFormat.compact(counts.cacheCreation),
                TokenUsageFormat.compact(counts.cacheRead),
                TokenUsageFormat.compact(counts.total),
                "\(day.messages)",
            ]
            .map { pad($0, to: 10) }
            .joined()
            print("\(dayFormatter.string(from: day.day))  \(columns)")
        }
        print("")
        for range in [1, 7, 30] {
            let counts = summary.total(lastDays: range)
            print("Last \(range) day\(range == 1 ? "" : "s"): \(TokenUsageFormat.exact(counts.fresh)) produced/sent, "
                + "\(TokenUsageFormat.exact(counts.cacheRead)) replayed from cache, across \(summary.messages(lastDays: range)) turns")
        }
        print("")
        print("By model (30 days)")
        for entry in summary.modelBreakdown(lastDays: 30) {
            print("  \(entry.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)) \(TokenUsageFormat.exact(entry.counts.fresh)) (+\(TokenUsageFormat.exact(entry.counts.cacheRead)) cached)")
        }
        return 0
    }

    /// Right-aligns a column without dragging `String(format:)` and NSString
    /// bridging into a debug helper.
    private static func pad(_ value: String, to width: Int) -> String {
        String(repeating: " ", count: max(0, width - value.count)) + value
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// `ClawdBar --render-tokens <out.png>` — renders the token panel exactly as
/// the popover draws it, from the real transcript data. A UI change to a
/// menu-bar popover is otherwise only reviewable by launching the app, which
/// on a rebuilt binary costs a keychain prompt.
enum TokenRenderCommand {
    static let flag = "--render-tokens"

    @MainActor
    static func run(arguments: [String]) -> Int32 {
        BundledFont.registerAll()
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: ClawdBar --render-tokens <output.png>\n".utf8))
            return 1
        }
        let outPath = arguments[index + 1]

        let summary = (try? TokenUsageScanner().scan()) ?? .empty
        let monitor = TokenUsageMonitor(seeded: summary)

        // Drawn with the tab strip above it, the way the popover stacks them,
        // so the render shows what the user will actually see.
        let content = VStack(alignment: .leading, spacing: 0) {
            PopoverTabStrip(
                tabs: PopoverTab.allCases,
                selection: .constant(.tokens),
                badge: { _ in nil }
            )
            .padding(.horizontal, 16)
            .padding(.top, 10)

            TokenUsageView(monitor: monitor)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 340)
        .background(Theme.bgDeep)
        .colorScheme(.dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        renderer.isOpaque = true

        guard let cgImage = renderer.cgImage else {
            FileHandle.standardError.write(Data("failed to render token panel\n".utf8))
            return 1
        }
        let url = URL(fileURLWithPath: outPath)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            FileHandle.standardError.write(Data("could not open \(outPath) for write\n".utf8))
            return 1
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            FileHandle.standardError.write(Data("PNG finalize failed\n".utf8))
            return 1
        }
        print("wrote \(outPath) (\(cgImage.width)x\(cgImage.height))")
        return 0
    }
}
