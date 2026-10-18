import SwiftUI
import SoriCore

enum SoriTheme {
    static let paper = Color(hex: 0xFCFCFA)
    static let sidebar = Color(hex: 0xF3F3F0)
    static let surface = Color(hex: 0xFCFCFA)
    static let ink = Color(hex: 0x292B27)
    static let secondary = Color(hex: 0x686B62)
    static let faint = Color(hex: 0xBCBDB3)
    static let accent = Color(hex: 0x292B27)
    static let accentSoft = Color(hex: 0xE8E9E5)
    static let recording = Color(hex: 0xC94C36)
    static let line = Color(hex: 0xE7E6DF)
    static let green = Color(hex: 0x637A61)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? SoriTheme.accent : SoriTheme.secondary)
            .padding(8)
            .background(active ? SoriTheme.accentSoft : (configuration.isPressed ? SoriTheme.line : .clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(SoriTheme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct WaveformView: View {
    var samples: [Float]
    var progress: Double = 0
    var live = false
    var body: some View {
        Canvas { context, size in
            let values = samples.isEmpty ? Array(repeating: Float(0.04), count: 90) : samples
            let stride = size.width / Double(values.count)
            for (index, value) in values.enumerated() {
                let amplitude = value.isFinite ? min(1, max(0, Double(value))) : 0
                let height = max(2, amplitude * max(0, size.height - 4))
                let rect = CGRect(x: Double(index) * stride, y: (size.height - height) / 2, width: max(1, stride * 0.5), height: height)
                let color = live ? SoriTheme.recording : (Double(index) / Double(values.count) < progress ? SoriTheme.accent : SoriTheme.faint.opacity(0.6))
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        Canvas { context, bounds in
            let path = Path(BrandSymbol.fitted(in: CGRect(origin: .zero, size: bounds)))
            context.fill(path, with: .color(SoriTheme.ink), style: FillStyle(eoFill: true))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct SectionEyebrow: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(SoriTheme.secondary) }
}
