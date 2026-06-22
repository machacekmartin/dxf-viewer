import SwiftUI
import AppKit

// SwiftUI points are logical units — physical size depends on the display.
// Real 1:N scale needs logical points per physical mm of the screen the window is on.
// CGDisplayScreenSize gives physical width in mm; NSScreen.frame.width gives the
// logical width in points — the ratio is what we need. Multi-monitor: pick the
// screen the user is on, not always the primary. Scaled display modes make
// CGDisplayPixelsWide diverge from logical-point space; frame.width is the right
// numerator.
@MainActor
func pointsPerMM(screen: NSScreen? = nil) -> CGFloat {
    let s = screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
    guard let s else { return 72.0 / 25.4 }
    let displayID = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    let mmWide = CGFloat(CGDisplayScreenSize(displayID).width)
    guard mmWide > 0 else { return 72.0 / 25.4 }
    return s.frame.width / mmWide
}

// 1/2/5×10ⁿ scale bar length. Targets ~100 pt on screen.
func scaleBarLength(s: CGFloat, target: CGFloat = 100) -> CGFloat {
    let safe = max(s, 1e-9)
    let p10 = pow(10.0, floor(log10(target / safe)))
    var mult: CGFloat = 10
    for m in [1.0, 2.0, 5.0] as [CGFloat] {
        if m * p10 * safe >= target * 0.6 { mult = m; break }
    }
    return mult * p10
}

func formatScaleRatio(_ r: CGFloat) -> String {
    let precision = r >= 100 ? 1 : 2
    var s = String(format: "%.\(precision)f", Double(r))
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return "1:\(s)"
}

func formatScaleLength(_ mm: CGFloat) -> String {
    if mm >= 1000 { return String(format: "%g m", Double(mm / 1000)) }
    if mm >= 10   { return String(format: "%g cm", Double(mm / 10)) }
    return String(format: "%g mm", Double(mm))
}

struct ScaleRatioLabel: View {
    // Points-per-world-millimetre (caller scales by mmPerUnit). The 1:N ratio is
    // pointsPerMM / sMM — both numerator and denominator are points-per-mm so the
    // ratio is unitless real-world-mm per screen-mm.
    let s: CGFloat
    static let reservedWidth: CGFloat = 72

    var body: some View {
        let ratio = pointsPerMM() / max(s, 1e-9)
        Text(formatScaleRatio(ratio))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.22), value: ratio)
            .frame(width: Self.reservedWidth, alignment: .center)
    }
}

struct ScaleLengthIndicator: View {
    let s: CGFloat
    var body: some View {
        let safe = max(s, 1e-9)
        let d = scaleBarLength(s: safe)
        let w = min(160, max(30, d * safe))
        let stroke = Color(red: 0.18, green: 0.20, blue: 0.25)
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<5) { i in
                        Rectangle()
                            .fill(stroke)
                            .frame(width: 1, height: (i == 0 || i == 4) ? 8 : 5)
                        if i < 4 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: w, height: 8, alignment: .bottom)
                Rectangle()
                    .fill(stroke)
                    .frame(width: w, height: 2)
            }
            .animation(.smooth(duration: 0.22), value: w)
            Text(formatScaleLength(d))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.25))
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.22), value: d)
        }
    }
}

struct ScaleTooltip: View {
    let s: CGFloat
    var body: some View {
        let safe = max(s, 1e-9)
        let ratio = pointsPerMM() / safe
        let d = scaleBarLength(s: safe)
        let onScreen = d / max(ratio, 1e-9)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Scale \(formatScaleRatio(ratio))")
                .font(.system(size: 12, weight: .semibold))
            Text("Drawing on screen is \(ratioMultiplier(ratio))× smaller than reality")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("\(formatScaleLength(d)) in reality ≈ \(formatScaleLength(onScreen)) on screen")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }

    // Strip the "1:" prefix — the sentence reads "100× smaller", not "1:100× smaller".
    private func ratioMultiplier(_ r: CGFloat) -> String {
        let full = formatScaleRatio(r)
        return full.hasPrefix("1:") ? String(full.dropFirst(2)) : full
    }
}
