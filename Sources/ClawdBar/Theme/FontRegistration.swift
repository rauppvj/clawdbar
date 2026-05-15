import Foundation
import AppKit
import CoreText

enum BundledFont {
    static let pressStart2P = "PressStart2P-Regular"

    @MainActor private static var pressStart2PIsRegistered = false

    @MainActor
    static func registerAll() {
        guard !pressStart2PIsRegistered else { return }
        guard let url = locateFont() else { return }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            pressStart2PIsRegistered = true
        }
    }

    /// Find PressStart2P-Regular.ttf across the two layouts the binary can run
    /// in: a wrapped .app bundle (Contents/Resources/Fonts/) and an SPM dev
    /// build (Bundle.module via .build/<arch>/<config>/ClawdBar_ClawdBar.bundle).
    ///
    /// We deliberately avoid `Bundle.module` in the .app case — SPM's
    /// auto-generated accessor `fatalError`s if its compile-time-baked bundle
    /// path is absent, which is exactly the case for any .app shipped to a
    /// machine other than the one that built it (e.g. the GitHub Actions
    /// runner). Bundle.main works for the .app; Bundle.module is the dev
    /// fallback only.
    private static func locateFont() -> URL? {
        // .app path: Contents/Resources/Fonts/PressStart2P-Regular.ttf
        if let url = Bundle.main.url(
            forResource: "PressStart2P-Regular",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) {
            return url
        }
        // .app path without subdirectory (flat layout):
        if let url = Bundle.main.url(
            forResource: "PressStart2P-Regular",
            withExtension: "ttf"
        ) {
            return url
        }
        // Dev mode: SPM emits a bundle at .build/<arch>/<cfg>/ClawdBar_ClawdBar.bundle
        // sitting next to the binary. Walk in by hand so we never touch
        // `Bundle.module` (whose initializer can crash on .app builds where
        // its compile-time path is gone).
        let binDir = Bundle.main.bundleURL
        let devCandidates = [
            binDir.appendingPathComponent("ClawdBar_ClawdBar.bundle/Contents/Resources/Fonts/PressStart2P-Regular.ttf"),
            binDir.appendingPathComponent("ClawdBar_ClawdBar.bundle/Contents/Resources/PressStart2P-Regular.ttf"),
            binDir.appendingPathComponent("ClawdBar_ClawdBar.bundle/PressStart2P-Regular.ttf"),
        ]
        return devCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor
    static var hasPressStart2P: Bool {
        registerAll()
        return NSFont(name: "PressStart2P-Regular", size: 12) != nil
    }
}
