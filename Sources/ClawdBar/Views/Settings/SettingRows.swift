import SwiftUI

/// Each control is its own View so that during a 60 fps slider drag, only the
/// row re-renders. If we inlined these inside the tab body, every tick would
/// re-render the entire Form, which propagates layout changes up to the
/// NSToolbar that backs Settings tabs — and made the tab icons "dance".

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let defaultValue: Double

    var body: some View {
        HStack {
            Text(label)
            Slider(value: $value, in: range, step: step)
            Text("\(Int(value))\(unit)")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            ResetButton(isModified: value != defaultValue) {
                value = defaultValue
            }
        }
    }
}

struct PercentSliderRow: View {
    let label: String
    @Binding var value: Double            // 0…1
    let range: ClosedRange<Double>
    let defaultValue: Double

    var body: some View {
        HStack {
            Text(label)
            Slider(value: $value, in: range)
            Text("\(Int(value * 100))%")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            ResetButton(isModified: abs(value - defaultValue) > 0.001) {
                value = defaultValue
            }
        }
    }
}

struct ToggleRow: View {
    let label: String
    @Binding var value: Bool
    let defaultValue: Bool

    var body: some View {
        HStack {
            Toggle(label, isOn: $value)
            Spacer()
            ResetButton(isModified: value != defaultValue) {
                value = defaultValue
            }
        }
    }
}

struct PickerRow<T: Hashable & CaseIterable & Identifiable>: View where T.AllCases: RandomAccessCollection {
    let label: String
    @Binding var value: T
    let defaultValue: T
    let displayName: (T) -> String

    var body: some View {
        HStack {
            Picker(label, selection: $value) {
                ForEach(Array(T.allCases)) { option in
                    Text(displayName(option)).tag(option)
                }
            }
            ResetButton(isModified: value != defaultValue) {
                value = defaultValue
            }
        }
    }
}
