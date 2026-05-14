import Foundation
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ExportIconCommand {
    static let flag = "--export-icon"

    @MainActor
    static func run(arguments: [String]) -> Int32 {
        BundledFont.registerAll()
        guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: ClawdBar --export-icon <output.png>\n".utf8))
            return 1
        }
        let outPath = arguments[idx + 1]
        let url = URL(fileURLWithPath: outPath)

        let renderer = ImageRenderer(content: AppIconArt().frame(width: 1024, height: 1024))
        renderer.scale = 1.0
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: 1024, height: 1024)

        guard let cgImage = renderer.cgImage else {
            FileHandle.standardError.write(Data("failed to render icon\n".utf8))
            return 1
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            FileHandle.standardError.write(Data("could not open \(outPath) for write\n".utf8))
            return 1
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            FileHandle.standardError.write(Data("PNG finalize failed\n".utf8))
            return 1
        }

        print("wrote \(outPath) (1024x1024)")
        return 0
    }
}

private struct AppIconArt: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x20 / 255),
                    Color(red: 0x08 / 255, green: 0x08 / 255, blue: 0x0C / 255),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 224, style: .continuous))

            // Subtle bezel highlight.
            RoundedRectangle(cornerRadius: 224, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .clear],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 4
                )

            // Glow behind the mascot.
            Circle()
                .fill(Theme.accentWarm)
                .frame(width: 640, height: 640)
                .blur(radius: 120)
                .opacity(0.18)

            // Foreground mascot, centered. Frozen at t=0 so the icon bake is
            // identical across builds (no live TimelineView capture).
            MascotView(mood: .focused, severity: .ok, pixel: 36, frozen: true)
                .frame(width: 576, height: 576)

            // Subtle "5H" caption — references the 5-hour rate-limit window.
            VStack {
                Spacer()
                Text("5H")
                    .font(Theme.retro(size: 56, weight: .heavy))
                    .foregroundStyle(Theme.accentWarm.opacity(0.85))
                    .padding(.bottom, 96)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}
