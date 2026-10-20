import AppKit
import RAMKit
import SwiftUI

/// Monochrome instrument (spec 7): system grays and label levels, 0.5 pt hairlines, SF Pro 11-13 pt,
/// SF Mono tabular numbers. Meaning comes from shape and words. The single accent colour exists for
/// the download moment only; amber and red mark the wall.
enum Theme {
    static let width: CGFloat = 360
    /// Mutable only so `--render-ui` can lift the caps and show every row.
    @MainActor static var maxHeight: CGFloat = 720
    @MainActor static var sectionsMaxHeight: CGFloat = 300
    static let hairline: CGFloat = 0.5
    static let gutter: CGFloat = 14

    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let quaternary = Color(nsColor: .quaternaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let fill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let inverted = Color(nsColor: .windowBackgroundColor)
    /// The download moment.
    static let accent = Color(nsColor: .systemBlue)
    static let amber = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)

    static func title(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold) }
    static let body = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let caption = Font.system(size: 10, weight: .semibold)
    static let mono = Font.system(size: 11, design: .monospaced).monospacedDigit()
    static let monoBody = Font.system(size: 12, design: .monospaced).monospacedDigit()
    static let monoBig = Font.system(size: 28, weight: .medium, design: .monospaced).monospacedDigit()
    static let numberBig = Font.system(size: 34, weight: .semibold).monospacedDigit()

    /// Amber from 70, red from 85 (spec 7); nil below.
    static func wallColor(_ percent: Double) -> Color? {
        percent >= 85 ? red : percent >= 70 ? amber : nil
    }

    static func wallTint(_ percent: Double) -> NSColor? {
        percent >= 85 ? .systemRed : percent >= 70 ? .systemOrange : nil
    }
}

/// A hairline divider.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
    }
}

/// Section caption: small caps-style label with an optional right-aligned total.
struct SectionHeader: View {
    var title: String
    var detail: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.secondary).tracking(0.6)
            Spacer()
            if !detail.isEmpty { Text(detail).font(Theme.mono).foregroundStyle(Theme.secondary) }
        }
        .padding(.horizontal, Theme.gutter).padding(.top, 10).padding(.bottom, 4)
    }
}

/// A thin horizontal meter. `fraction` 0...1; `tint` nil = secondary gray.
struct Meter: View {
    var fraction: Double
    var height: CGFloat = 3
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(tint ?? Theme.secondary)
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * min(1, max(0, fraction.isFinite ? fraction : 0))))
            }
        }
        .frame(height: height)
    }
}

/// Small bordered button in gray (no accent anywhere).
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small.weight(prominent ? .semibold : .regular))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed || prominent ? Theme.fill : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.separator, lineWidth: Theme.hairline))
            .contentShape(Rectangle())
    }
}

/// Plain icon/text button without chrome.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1).contentShape(Rectangle())
    }
}

/// The one big button: filled with the label colour, text inverted.
struct BigButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? Theme.inverted : Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(enabled ? (configuration.isPressed ? Theme.secondary : Theme.primary) : Theme.fill))
            .contentShape(Rectangle())
    }
}

/// Monochrome switch (system toggles would use the accent colour).
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.secondary : Theme.fill)
                        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: Theme.hairline))
                        .frame(width: 26, height: 15)
                    Circle().fill(Theme.inverted).frame(width: 11, height: 11).padding(2)
                        .overlay(Circle().strokeBorder(Theme.separator, lineWidth: Theme.hairline).padding(2))
                }
                configuration.label
            }
        }
        .buttonStyle(BareButtonStyle())
    }
}

/// "+1.84 GB" / "-100.0 MB" in mono, right-aligned at a fixed width so columns line up.
struct SignedBytes: View {
    var bytes: Int64
    var width: CGFloat = 72
    var body: some View {
        Text(Format.bytes(bytes, signed: true))
            .font(Theme.mono)
            .foregroundStyle(bytes < 0 ? Theme.secondary : Theme.primary)
            .frame(width: width, alignment: .trailing)
    }
}
