import AppKit
import RAMKit
import SwiftUI

/// DESIGN.md section 3, verbatim: ink at four opacities over an opaque canvas, one accent (memory
/// coming back), one status red (the wall). SF Pro for everything, SF Mono only for live numbers in
/// the download sheet and the receipt. 4 pt grid, radii 6/10/12, springs without bounce.
enum Theme {
    static let width: CGFloat = 360
    /// The "All" list scrolls past this height; everything else is content-sized.
    static let listMaxHeight: CGFloat = 320
    static let hairline: CGFloat = 0.5
    static let gutter: CGFloat = 16
    static let radiusControl: CGFloat = 6
    static let radiusPanel: CGFloat = 10
    static let radiusSheet: CGFloat = 12

    /// One appearance's tokens (the share card and the clip always use `dark`).
    struct Palette: Sendable {
        var canvas: Color
        var surface: Color
        var hairline: Color
        var ink: Color
        var ink2: Color
        var ink3: Color
        var accent: Color
        var danger: Color
    }

    static let light = Palette(canvas: fixed("#FFFFFF"), surface: fixed("#F4F4F4"), hairline: fixed("#E3E3E3"),
                               ink: fixed("#111111"), ink2: fixed("#5C5C5C"), ink3: fixed("#6E6E6E"),
                               accent: fixed("#0F7B4F"), danger: fixed("#C4291C"))
    static let dark = Palette(canvas: fixed("#161616"), surface: fixed("#202020"), hairline: fixed("#2E2E2E"),
                              ink: fixed("#F2F2F2"), ink2: fixed("#A8A8A8"), ink3: fixed("#8F8F8F"),
                              accent: fixed("#3DDC97"), danger: fixed("#FF6B5E"))

    // Dynamic tokens: resolve against the hosting view's appearance (the panel follows the system).
    static let canvas = dynamic("#FFFFFF", "#161616")
    static let surface = dynamic("#F4F4F4", "#202020")
    static let hairlineColor = dynamic("#E3E3E3", "#2E2E2E")
    static let ink = dynamic("#111111", "#F2F2F2")
    static let ink2 = dynamic("#5C5C5C", "#A8A8A8")
    static let ink3 = dynamic("#6E6E6E", "#8F8F8F")
    static let accent = dynamic("#0F7B4F", "#3DDC97")
    static let danger = dynamic("#C4291C", "#FF6B5E")

    static let canvasNSColor = dynamicNSColor("#FFFFFF", "#161616")
    static let hairlineNSColor = dynamicNSColor("#E3E3E3", "#2E2E2E")

    // Type.
    static let hero = Font.system(size: 56, weight: .semibold).monospacedDigit()
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let bodyMedium = Font.system(size: 12, weight: .medium)
    static let bodyNumber = Font.system(size: 12).monospacedDigit()
    static let small = Font.system(size: 11)
    static let smallNumber = Font.system(size: 11).monospacedDigit()
    /// Live numbers only (download sheet, receipt).
    static let mono = Font.system(size: 11, design: .monospaced).monospacedDigit()
    static let monoBody = Font.system(size: 12, design: .monospaced).monospacedDigit()
    static let monoBig = Font.system(size: 32, weight: .medium, design: .monospaced).monospacedDigit()
    static let payoff = Font.system(size: 34, weight: .semibold).monospacedDigit()

    // Motion: springs with no bounce; entrances 200 ms, exits 0.6x; Reduce Motion = cross-fades.
    static let spring = Animation.spring(response: 0.30, dampingFraction: 1.0)
    static let enter = Animation.easeOut(duration: 0.20)
    static let exit = Animation.easeIn(duration: 0.12)
    static let crossFade = Animation.linear(duration: 0.15)
    static let blinkMs = 90

    /// The wall is red from 85% or when the panel can appear any second; nothing else is.
    static func atWall(_ wall: WallStatus?) -> Bool {
        guard let wall else { return false }
        return wall.imminent || wall.percent >= 85
    }

    static func fixed(_ hex: String) -> Color {
        let (r, g, b) = rgb(hex)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = rgb(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func dynamic(_ light: String, _ dark: String) -> Color { Color(nsColor: dynamicNSColor(light, dark)) }

    static func dynamicNSColor(_ light: String, _ dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        }
    }

    static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }
}

/// 0.5 pt divider in the hairline token.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairlineColor).frame(height: Theme.hairline)
    }
}

/// A thin bar: surface track, ink (or red) fill. No animation at rest.
struct Bar: View {
    var fraction: Double
    var height: CGFloat = 4
    var fill: Color = Theme.ink
    var track: Color = Theme.surface

    var body: some View {
        GeometryReader { geo in
            let f = min(1, max(0, fraction.isFinite ? fraction : 0))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(track)
                RoundedRectangle(cornerRadius: height / 2).fill(fill)
                    .frame(width: f > 0 ? max(height, geo.size.width * f) : 0)
            }
        }
        .frame(height: height)
    }
}

/// Small bordered control: surface fill on press, hairline border, radius 6.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small.weight(prominent ? .semibold : .regular))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(configuration.isPressed || prominent ? Theme.surface : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline))
            .contentShape(Rectangle())
    }
}

/// Text-only button in ink-2 (the "All" control, Done).
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small)
            .foregroundStyle(configuration.isPressed ? Theme.ink : Theme.ink2)
            .contentShape(Rectangle())
    }
}

/// Plain content button without chrome (rows that expand).
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}

/// The one primary action: ink fill, canvas text, 36 pt. `blink` is the 90 ms off frame before the
/// sheet opens (the menu-item blink); `enabled` false reads as surface + ink-3.
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    var blink = false
    /// Forces the pressed look (the clip renderer drives the press from its timeline).
    var pressed = false
    func makeBody(configuration: Configuration) -> some View {
        let off = !enabled || blink
        let down = configuration.isPressed || pressed
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(off ? Theme.ink3 : Theme.canvas)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(off ? Theme.surface : (down ? Theme.ink2 : Theme.ink)))
            .contentShape(Rectangle())
    }
}

/// Monochrome switch (system switches use the blue accent).
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.ink2 : Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline))
                        .frame(width: 26, height: 16)
                    Circle().fill(Theme.canvas).frame(width: 12, height: 12).padding(2)
                        .overlay(Circle().strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline).padding(2))
                }
                configuration.label.font(Theme.small).foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(BareButtonStyle())
    }
}

/// "+1.84 GB" / "-100.0 MB" in SF Mono, right-aligned at a fixed width so columns line up. Gains
/// are the accent (memory coming back); losses ink-2.
struct SignedBytes: View {
    var bytes: Int64
    var width: CGFloat = 76
    var font: Font = Theme.mono
    var body: some View {
        Text(Format.bytes(bytes, signed: true))
            .font(font)
            .foregroundStyle(bytes > 0 ? Theme.accent : Theme.ink2)
            .frame(width: width, alignment: .trailing)
    }
}

/// A small text tag in a hairline capsule ("archived", "busy").
struct Tag: View {
    var text: String
    var color: Color = Theme.ink3
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline))
    }
}
