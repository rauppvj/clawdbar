import Foundation
import Observation

@MainActor
@Observable
final class OverlaySettings {
    var opacity: Double = 1.0
    var clickThrough: Bool = false
    var locked: Bool = false
}
