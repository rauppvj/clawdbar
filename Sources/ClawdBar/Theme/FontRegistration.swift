import Foundation
import AppKit
import CoreText

enum BundledFont {
    static let pressStart2P = "PressStart2P-Regular"

    @MainActor private static var pressStart2PIsRegistered = false

    @MainActor
    static func registerAll() {
        guard !pressStart2PIsRegistered else { return }
        if let url = Bundle.module.url(forResource: "PressStart2P-Regular", withExtension: "ttf") {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                pressStart2PIsRegistered = true
            }
        }
    }

    @MainActor
    static var hasPressStart2P: Bool {
        registerAll()
        return NSFont(name: "PressStart2P-Regular", size: 12) != nil
    }
}
