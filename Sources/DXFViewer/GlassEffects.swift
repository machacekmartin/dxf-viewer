import SwiftUI
import AppKit

// AppKit shim — forwards mouseDown to NSWindow.performDrag so the top strip acts as a
// window-drag handle without intercepting any other event.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }
}

enum GlassHairlineShape { case circle, capsule }

extension View {
    // Subtle two-tone hairline that catches light on glass buttons.
    func glassHairline(shape: GlassHairlineShape) -> some View {
        self.overlay {
            switch shape {
            case .circle:
                Circle()
                    .strokeBorder(hairlineGradient, lineWidth: 0.7)
                    .allowsHitTesting(false)
            case .capsule:
                Capsule()
                    .strokeBorder(hairlineGradient, lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
    }

    // Manual glass-icon styling. `.buttonStyle(.glass)` wraps content in an implicit
    // GlassEffectContainer, which sucks any nested .glassEffect (eg a tooltip bubble)
    // into the button's own glass surface. The scale-capsule pattern avoids that.
    func glassIconButton() -> some View {
        self
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .glassEffect(in: Circle())
            .glassHairline(shape: .circle)
            .contentShape(Circle())
    }
}

private let hairlineGradient = LinearGradient(
    colors: [.white.opacity(0.55), .black.opacity(0.10)],
    startPoint: .top, endPoint: .bottom)

// Toggles between circular icon-only (no file loaded) and a wider capsule that shows
// the file name. Same glass-tooltip separation as glassIconButton, but two shapes.
struct GlassImportButtonStyling: ViewModifier {
    let loaded: Bool
    func body(content: Content) -> some View {
        if loaded {
            content
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(in: Capsule())
                .glassHairline(shape: .capsule)
                .contentShape(Capsule())
        } else {
            content.glassIconButton()
        }
    }
}

struct EdgeDragBar: View {
    let edge: Edge

    var body: some View {
        ZStack {
            WindowDragHandle()
            // Glass blur tinted with the canvas background so it fades into the scene
            // instead of reading as a white wash.
            Rectangle()
                .glassEffect(.clear, in: Rectangle())
                .overlay(Color(red: 0.97, green: 0.98, blue: 1.00).opacity(0.55))
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black.opacity(0.55), location: 0.5),
                            .init(color: .clear, location: 1.0),
                        ]),
                        startPoint: gradientStart,
                        endPoint: gradientEnd))
                .allowsHitTesting(false)
        }
    }

    private var gradientStart: UnitPoint {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
    private var gradientEnd: UnitPoint {
        switch edge {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }
}

// AutoCAD Color Index → SwiftUI Color, tuned for a light background.
// 7 is "white/black" — black on light bg. Other entries are muted ACI palette.
func aciColor(_ aci: Int) -> Color {
    switch aci {
    case 1: return Color(red: 0.85, green: 0.10, blue: 0.10)
    case 2: return Color(red: 0.70, green: 0.60, blue: 0.05)
    case 3: return Color(red: 0.00, green: 0.58, blue: 0.00)
    case 4: return Color(red: 0.00, green: 0.55, blue: 0.65)
    case 5: return Color(red: 0.10, green: 0.10, blue: 0.85)
    case 6: return Color(red: 0.70, green: 0.00, blue: 0.70)
    case 8: return Color(red: 0.45, green: 0.45, blue: 0.50)
    case 9: return Color(red: 0.60, green: 0.60, blue: 0.66)
    default: return Color(red: 0.12, green: 0.13, blue: 0.16)
    }
}
