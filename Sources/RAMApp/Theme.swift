import AppKit
import RAMKit
import SwiftUI

/// DESIGN.md v2 section 3: a dark-first instrument. A system material under a charcoal (or warm paper) tint,
/// ink at three levels, and one state language: temperature. Frost when far from the wall, amber on the way,
/// ember at the wall. Frost is also the colour of memory coming back. No green, no system blue.
enum Theme {
    static let width: CGFloat = 360
    /// The "All" list scrolls past this height; everything else is content-sized.
    static let listMaxHeight: CGFloat = 300
    static let hairline: CGFloat = 1
    static let gutter: CGFloat = 16
    static let radiusControl: CGFloat = 10
    static let radiusTile: CGFloat = 14
    static let radiusPanel: CGFloat = 20
    static let radiusSheet: CGFloat = 14

    /// One appearance's tokens, fixed (the share card and the clip always use `dark`).
    struct Palette: Sendable {
        var canvas: Color
        var surface: Color
        var stroke: Color
        var ink: Color
        var ink2: Color
        var ink3: Color
        var frost: Color
        var amber: Color
        var ember: Color
        var hairline: Color { stroke }
        var accent: Color { frost }
        var danger: Color { ember }
    }

    static let dark = Palette(canvas: fixed("#141416"), surface: Color.white.opacity(0.06), stroke: Color.white.opacity(0.09),
                              ink: fixed("#F5F5F3"), ink2: fixed("#B4B4AF"), ink3: fixed("#979792"),
                              frost: fixed("#9ED8FF"), amber: fixed("#F2B45A"), ember: fixed("#FF6B47"))
    static let light = Palette(canvas: fixed("#F4F3EF"), surface: Color.black.opacity(0.04), stroke: Color.black.opacity(0.08),
                               ink: fixed("#141414"), ink2: fixed("#45453F"), ink3: fixed("#5E5E58"),
                               frost: fixed("#1D5F8C"), amber: fixed("#8A5000"), ember: fixed("#9C2B08"))

    // Dynamic tokens: resolve against the hosting view's appearance.
    /// The tint over the panel's material: mostly opaque, so text contrast never depends on the wallpaper.
    static let tint = dynamicAlpha(light: ("#F4F3EF", 0.80), dark: ("#121214", 0.74))
    /// Opaque version of the tint (Reduce Transparency, offscreen renders).
    static let canvas = dynamic("#F4F3EF", "#141416")
    static let surface = dynamicAlpha(light: ("#000000", 0.045), dark: ("#FFFFFF", 0.065))
    static let surfaceStrong = dynamicAlpha(light: ("#000000", 0.08), dark: ("#FFFFFF", 0.11))
    static let hairlineColor = dynamicAlpha(light: ("#000000", 0.08), dark: ("#FFFFFF", 0.09))
    static let ink = dynamic("#141414", "#F5F5F3")
    static let ink2 = dynamic("#45453F", "#B4B4AF")
    static let ink3 = dynamic("#5E5E58", "#979792")
    static let frost = dynamic("#1D5F8C", "#9ED8FF")
    static let amber = dynamic("#8A5000", "#F2B45A")
    static let ember = dynamic("#9C2B08", "#FF6B47")
    static let accent = frost
    static let danger = ember
    /// The primary capsule: ink on the panel (white on dark, near-black on light), text in the canvas colour.
    static let capsule = dynamic("#141414", "#F5F5F3")
    static let capsuleText = dynamic("#F4F3EF", "#141416")

    static let canvasNSColor = dynamicNSColor("#F4F3EF", "#141416")
    static let hairlineNSColor = dynamicAlphaNSColor(light: ("#000000", 0.08), dark: ("#FFFFFF", 0.09))

    // Type: SF Pro, SF Pro Light for the one numeral, SF Mono for counting numbers only.
    static let hero = Font.system(size: 60, weight: .light).monospacedDigit()
    static let heroUnit = Font.system(size: 26, weight: .light)
    static let payoff = Font.system(size: 52, weight: .light).monospacedDigit()
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodyNumber = Font.system(size: 13).monospacedDigit()
    static let label = Font.system(size: 11, weight: .medium)
    static let small = Font.system(size: 11)
    static let smallNumber = Font.system(size: 11).monospacedDigit()
    static let tileValue = Font.system(size: 15, weight: .semibold).monospacedDigit()
    /// Counting numbers (download, receipt lines).
    static let mono = Font.system(size: 12, design: .monospaced).monospacedDigit()
    static let monoBody = Font.system(size: 12, design: .monospaced).monospacedDigit()
    /// The live amount: the same light face as the payoff it becomes, with tabular digits so it never jitters.
    static let counter = Font.system(size: 44, weight: .light).monospacedDigit()
    static let counterUnit = Font.system(size: 20, weight: .light)

    // Motion: one frame to open; 120-200 ms eased for state changes; nothing at rest; Reduce Motion = cross-fades.
    static let spring = Animation.easeOut(duration: 0.18)
    static let enter = Animation.easeOut(duration: 0.18)
    static let exit = Animation.easeIn(duration: 0.12)
    static let crossFade = Animation.linear(duration: 0.15)
    static let blinkMs = 90

    /// The wall is ember from 85% or when the panel can appear any second.
    static func atWall(_ wall: WallStatus?) -> Bool {
        guard let wall else { return false }
        return wall.imminent || wall.percent >= 85
    }

    /// The temperature of a wall reading: frost to 55%, then toward amber, then ember from 85%.
    static func temperature(_ percent: Double, imminent: Bool = false) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return temperatureNSColor(percent, imminent: imminent, dark: darkMode)
        })
    }

    static func temperature(_ wall: WallStatus?) -> Color {
        temperature(wall?.percent ?? 0, imminent: wall?.imminent ?? false)
    }

    static func temperatureNSColor(_ percent: Double, imminent: Bool, dark: Bool) -> NSColor {
        let frost = rgb(dark ? "#9ED8FF" : "#1D5F8C")
        let amber = rgb(dark ? "#F2B45A" : "#8A5000")
        let ember = rgb(dark ? "#FF6B47" : "#9C2B08")
        let p = imminent ? 100 : max(0, min(100, percent.isFinite ? percent : 0))
        let c: (CGFloat, CGFloat, CGFloat)
        switch p {
        case ..<55: c = frost
        case ..<85: c = mix(frost, amber, CGFloat((p - 55) / 30))
        default: c = mix(amber, ember, CGFloat(min(1, (p - 85) / 10)))
        }
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    static func mix(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let t = max(0, min(1, t))
        return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    static func fixed(_ hex: String) -> Color {
        let (r, g, b) = rgb(hex)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func nsColor(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        let (r, g, b) = rgb(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    static func dynamic(_ light: String, _ dark: String) -> Color { Color(nsColor: dynamicNSColor(light, dark)) }

    static func dynamicNSColor(_ light: String, _ dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        }
    }

    static func dynamicAlpha(light: (String, CGFloat), dark: (String, CGFloat)) -> Color {
        Color(nsColor: dynamicAlphaNSColor(light: light, dark: dark))
    }

    static func dynamicAlphaNSColor(light: (String, CGFloat), dark: (String, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? nsColor(dark.0, alpha: dark.1) : nsColor(light.0, alpha: light.1)
        }
    }

    static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }
}

/// A 1 pt divider in the stroke token (used sparingly: sections are separated by space, not lines).
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairlineColor).frame(height: Theme.hairline)
    }
}

/// A rounded bar: surface track, fill in a colour of its own. No animation at rest.
struct Bar: View {
    var fraction: Double
    var height: CGFloat = 4
    var fill: Color = Theme.ink
    var track: Color = Theme.surface

    var body: some View {
        GeometryReader { geo in
            let f = min(1, max(0, fraction.isFinite ? fraction : 0))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: f > 0 ? max(height, geo.size.width * f) : 0)
            }
        }
        .frame(height: height)
    }
}

/// The section label: small, medium, ink-2, slightly tracked ("WHERE IT IS").
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(0.6).foregroundStyle(Theme.ink2)
    }
}

/// The one primary action: a full-width capsule in ink (white on dark), 44 pt, with a leading symbol.
/// `blink` is the 90 ms off frame before the sheet opens; `pressed` lets the clip drive the press.
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    var blink = false
    var pressed = false
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed || pressed
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.capsuleText)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Capsule().fill(Theme.capsule))
            .opacity(!enabled ? 0.35 : (blink ? 0.55 : (down ? 0.82 : 1)))
            .scaleEffect(down ? 0.985 : 1)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.09), value: down)
    }
}

/// Secondary capsule (Resume, Share, Done): surface fill, ink text, 30 pt.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small.weight(.semibold))
            .foregroundStyle(prominent ? Theme.capsuleText : Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(prominent ? Theme.capsule : (configuration.isPressed ? Theme.surfaceStrong : Theme.surface)))
            .opacity(configuration.isPressed && prominent ? 0.82 : 1)
            .contentShape(Capsule())
    }
}

/// A secondary capsule tinted with its colour (Resume in the paused-apps banner), so it never competes with
/// the one ink capsule on the panel. The label stays ink: coloured text on its own tint is too faint.
struct TintButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.26 : 0.18)))
            .contentShape(Capsule())
    }
}

/// Text-only button in ink-2 ("All 16").
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small.weight(.medium))
            .foregroundStyle(configuration.isPressed ? Theme.ink : Theme.ink2)
            .contentShape(Rectangle())
    }
}

/// Plain content button without chrome (rows that expand, tiles draw their own surface).
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The switch: a capsule that fills with frost when on (no system blue).
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.frost : Theme.surfaceStrong)
                        .frame(width: 30, height: 18)
                    Circle().fill(configuration.isOn ? Theme.capsuleText : Theme.ink2).frame(width: 14, height: 14).padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                configuration.label.font(Theme.small.weight(.medium)).foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(BareButtonStyle())
    }
}

/// "+1.84 GB" / "-100.0 MB" in SF Mono, right-aligned at a fixed width so columns line up. Gains in frost
/// (memory coming back), losses in ink-2.
struct SignedBytes: View {
    var bytes: Int64
    var width: CGFloat = 80
    var font: Font = Theme.bodyNumber
    var body: some View {
        Text(Format.bytes(bytes, signed: true))
            .font(font)
            .foregroundStyle(bytes > 0 ? Theme.frost : Theme.ink2)
            .frame(width: width, alignment: .trailing)
    }
}

/// A small text tag in a surface capsule ("archived").
struct Tag: View {
    var text: String
    var color: Color = Theme.ink2
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.surface))
    }
}

/// A status pill: tinted text on a faint fill of the same colour ("not climbing", "any second").
struct Pill: View {
    var text: String
    var color: Color = Theme.ink2
    var body: some View {
        Text(text).font(Theme.small.weight(.medium)).foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
