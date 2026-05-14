import SwiftUI

extension View {
    /// Apply a transformation only if a condition is true. Lets callers
    /// conditionally attach a chain of modifiers without losing type safety.
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
