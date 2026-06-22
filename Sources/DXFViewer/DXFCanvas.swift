import SwiftUI
import AppKit

@MainActor
final class ViewState: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    private var monitor: Any?

    // Zoom around the current visual center: scale offset by the same factor so the
    // world point at screen center stays put.
    func zoom(by raw: CGFloat) {
        let target = max(0.01, min(1000, scale * raw))
        let factor = target / scale
        scale = target
        offset = CGSize(width: offset.width * factor, height: offset.height * factor)
    }

    // Canvas doesn't interpolate @Published mutations under withAnimation — it
    // redraws on each set. So we tween manually on the main actor.
    private var animTask: Task<Void, Never>?
    func animate(to targetScale: CGFloat, targetOffset: CGSize, duration: Double = 0.4) {
        animTask?.cancel()
        let startScale = scale
        let startOffset = offset
        let steps = 36
        animTask = Task { @MainActor [weak self] in
            for k in 1...steps {
                if Task.isCancelled { return }
                let t = Double(k) / Double(steps)
                let eased = 1 - pow(1 - t, 3)
                self?.scale = startScale + (targetScale - startScale) * CGFloat(eased)
                self?.offset = CGSize(
                    width: startOffset.width + (targetOffset.width - startOffset.width) * CGFloat(eased),
                    height: startOffset.height + (targetOffset.height - startOffset.height) * CGFloat(eased))
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
            }
        }
    }

    func animateZoom(to absoluteScale: CGFloat) {
        let factor = absoluteScale / scale
        let target = CGSize(width: offset.width * factor, height: offset.height * factor)
        animate(to: absoluteScale, targetOffset: target)
    }

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .scrollWheel:
                if event.modifierFlags.contains(.shift) {
                    self.offset.width += event.scrollingDeltaX
                    self.offset.height += event.scrollingDeltaY
                } else {
                    self.zoom(by: 1 + event.scrollingDeltaY * 0.01)
                }
                return nil
            case .magnify:
                self.zoom(by: 1 + event.magnification)
                return nil
            default: return event
            }
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

private enum RenderMode: Hashable { case dim, normal, selected }

struct DXFCanvas: View {
    let document: DXFDocument?
    let renderModel: DXFRenderModel?
    var loadedFileName: String? = nil
    @Binding var selection: Set<DXFSelector>
    var onImport: () -> Void = {}
    @StateObject private var state = ViewState()
    @State private var lastDrag: CGSize = .zero
    @State private var hoveringScale = false
    @State private var showGrid = true

    // Empty scene → 1×1m centered on origin so grid + scale bar still work.
    private var bounds: CGRect {
        document?.bounds ?? CGRect(x: -500, y: -500, width: 1000, height: 1000)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let b = bounds
                let pad: CGFloat = 40
                let fit = min((size.width - pad) / b.width, (size.height - pad) / b.height)
                let s = fit * state.scale
                let cx = size.width / 2 + state.offset.width
                let cy = size.height / 2 + state.offset.height

                if showGrid {
                    drawGrid(ctx: ctx, size: size, s: s, cx: cx, cy: cy, bcx: b.midX, bcy: b.midY)
                }

                drawEntities(ctx: ctx, size: size, s: s, cx: cx, cy: cy, bcx: b.midX, bcy: b.midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let dx = v.translation.width - lastDrag.width
                        let dy = v.translation.height - lastDrag.height
                        state.offset.width += dx
                        state.offset.height += dy
                        lastDrag = v.translation
                    }
                    .onEnded { _ in lastDrag = .zero }
            )
            .overlay(alignment: .bottomLeading) {
                controlBar(geo: geo)
            }
            // Ruler in the opposite corner so the left button cluster stays tight.
            .overlay(alignment: .bottomTrailing) {
                ScaleLengthIndicator(s: scaleMM(in: geo.size))
                    .padding(16)
            }
        }
    }

    // MARK: - Entity drawing

    private func drawEntities(ctx: GraphicsContext, size: CGSize, s: CGFloat, cx: CGFloat, cy: CGFloat, bcx: CGFloat, bcy: CGFloat) {
        guard let rm = renderModel else { return }
        // World→screen transform. Y flips because world Y goes up, screen Y goes down.
        let transform = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: cx - bcx * s, ty: cy + bcy * s)
        let selectionActive = !selection.isEmpty
        // Selection-empty hot path: stroke ONE merged path per aci. Massive files pay
        // O(colors), not O(entities), per frame for the geometry pass.
        if !selectionActive {
            for (aci, cg) in rm.bulkStroke {
                let p = Path(cg).applying(transform)
                ctx.stroke(p, with: .color(aciColor(aci)), lineWidth: 1)
            }
            for (aci, cg) in rm.bulkFill {
                let p = Path(cg).applying(transform)
                ctx.fill(p, with: .color(aciColor(aci)))
            }
            drawText(ctx: ctx, size: size, entries: rm.entries, mode: .normal, transform: transform, s: s)
            return
        }

        // Selection-active: per-entity bucketing into dim / normal / selected.
        var stroke: [RenderMode: [Int: CGMutablePath]] = [.dim: [:], .normal: [:], .selected: [:]]
        var fill: [RenderMode: [Int: CGMutablePath]] = [.dim: [:], .normal: [:], .selected: [:]]
        func bucket(_ d: inout [RenderMode: [Int: CGMutablePath]], mode: RenderMode, aci: Int) -> CGMutablePath {
            if let p = d[mode]?[aci] { return p }
            let p = CGMutablePath()
            d[mode, default: [:]][aci] = p
            return p
        }
        for entry in rm.entries {
            let isSel = selection.contains(.entity(entry.index))
                || selection.contains(.kind(layer: entry.layer, kind: entry.kindName))
                || selection.contains(.layer(entry.layer))
            let mode: RenderMode = isSel ? .selected : .dim
            switch entry.geometry {
            case .stroke(let cg): bucket(&stroke, mode: mode, aci: entry.aci).addPath(cg)
            case .fill(let cg): bucket(&fill, mode: mode, aci: entry.aci).addPath(cg)
            case .text: break
            }
        }
        // Draw dim, then selected, so selected wins overdraw.
        for m in [RenderMode.dim, .selected] {
            let alpha: Double = (m == .dim) ? 0.14 : 1.0
            let width: CGFloat = (m == .selected) ? 2.0 : 1.0
            if let dict = stroke[m] {
                for (aci, cg) in dict {
                    let p = Path(cg).applying(transform)
                    ctx.stroke(p, with: .color(aciColor(aci).opacity(alpha)), lineWidth: width)
                }
            }
            if let dict = fill[m] {
                for (aci, cg) in dict {
                    let p = Path(cg).applying(transform)
                    ctx.fill(p, with: .color(aciColor(aci).opacity(alpha)))
                }
            }
        }
        drawText(ctx: ctx, size: size, entries: rm.entries, mode: nil, transform: transform, s: s)
    }

    // Text gets per-entity transform + measurement; can't be batched. Selection state
    // is `nil` outside selection mode (everything renders normal), otherwise we hide
    // dim text (matches the old behaviour) and draw only selected text.
    private func drawText(ctx: GraphicsContext, size: CGSize, entries: [DXFRenderModel.Entry], mode: RenderMode?, transform: CGAffineTransform, s: CGFloat) {
        // Viewport cull: at deep zoom, files with thousands of TEXT entities (statik etc)
        // pay resolve+measure+drawLayer per text per frame even though most are off-screen.
        // Reject anything whose insertion point is outside the inflated view rect. Pad
        // generously (a few times the text height) to cover rotated / multi-line / off-anchor
        // labels — undercut here causes pop-in along the edges.
        let viewRect = CGRect(origin: .zero, size: size)
        for entry in entries {
            guard case .text(let spec) = entry.geometry else { continue }
            if mode == nil, !selection.isEmpty {
                let isSel = selection.contains(.entity(entry.index))
                    || selection.contains(.kind(layer: entry.layer, kind: entry.kindName))
                    || selection.contains(.layer(entry.layer))
                if !isSel { continue } // matches "dim" branch from old code (text was skipped)
            }
            // DXF height = cap height; SwiftUI font(size:) = em / point size.
            let visualFontSize = min(200, spec.height * s / 0.72)
            if visualFontSize < 4 { continue }
            let screenPos = spec.pos.applying(transform)
            // Pad by the larger of glyph height and an estimated half-width; MTEXT with
            // explicit wrap width gets that as the pad instead.
            let glyphPx = visualFontSize * 2
            let widthPx = spec.wrapWidth > 0 ? (spec.wrapWidth * s) : (CGFloat(spec.str.count) * visualFontSize * 0.7)
            let pad = max(glyphPx, widthPx)
            if !viewRect.insetBy(dx: -pad, dy: -pad).contains(screenPos) { continue }
            // Render at a fixed base font size and scale via transform so the font hinter
            // only ever sees one point size — eliminates per-frame glyph wobble while zooming.
            let baseFontSize: CGFloat = 100
            let k = visualFontSize / baseFontSize
            let resolved = ctx.resolve(
                Text(spec.str)
                    .font(.system(size: baseFontSize, design: .default))
                    .foregroundColor(aciColor(entry.aci)))
            let baseMeasureW: CGFloat = spec.wrapWidth > 0 ? (spec.wrapWidth * s / k) : 10000
            let baseSz = resolved.measure(in: CGSize(width: baseMeasureW, height: 10000))
            let ax: CGFloat = {
                switch spec.hAlign {
                case 1: return baseSz.width / 2
                case 2: return baseSz.width
                default: return 0
                }
            }()
            let ay: CGFloat = {
                switch spec.vAlign {
                case 3: return 0
                case 2: return baseSz.height / 2
                default: return baseSz.height
                }
            }()
            ctx.drawLayer { layer in
                layer.translateBy(x: screenPos.x, y: screenPos.y)
                if abs(spec.rotDeg) > 1e-9 { layer.rotate(by: .degrees(-Double(spec.rotDeg))) }
                layer.scaleBy(x: k, y: k)
                layer.draw(resolved, in: CGRect(x: -ax, y: -ay, width: baseSz.width, height: baseSz.height))
            }
        }
    }

    // MARK: - Control bar

    private func scaleMM(in size: CGSize) -> CGFloat {
        let pad: CGFloat = 40
        let b = bounds
        let fit = min((size.width - pad) / b.width, (size.height - pad) / b.height)
        let s = fit * state.scale
        let mmPerUnit = document?.mmPerUnit ?? 1
        return s / mmPerUnit
    }

    @ViewBuilder private func controlBar(geo: GeometryProxy) -> some View {
        let pad: CGFloat = 40
        let b = bounds
        let fit = min((geo.size.width - pad) / b.width, (geo.size.height - pad) / b.height)
        let mmPerUnit = document?.mmPerUnit ?? 1
        let sMM = scaleMM(in: geo.size)
        HStack(spacing: 10) {
            Button(action: onImport) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .medium))
                    if let name = loadedFileName {
                        Text(name.count > 20 ? String(name.prefix(20)) + "…" : name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                }
            }
            .modifier(GlassImportButtonStyling(loaded: loadedFileName != nil))
            Button {
                state.animate(to: 1, targetOffset: .zero, duration: 0.45)
            } label: {
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .medium))
            }
            .glassIconButton()
            Button { showGrid.toggle() } label: {
                Image(systemName: showGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .font(.system(size: 15, weight: .medium))
            }
            .glassIconButton()
            Menu {
                ForEach([10, 25, 50, 100, 200, 500, 1000] as [Int], id: \.self) { ratio in
                    Button("1:\(ratio)") {
                        // Solve pointsPerMM / sMM_target = ratio for sMM_target, then
                        // convert back to world-unit space via mmPerUnit so the
                        // animation drives the same `s = fit * state.scale` formula.
                        let targetSMM = pointsPerMM() / CGFloat(ratio)
                        let targetS = targetSMM * mmPerUnit
                        state.animateZoom(to: targetS / max(fit, 1e-9))
                    }
                }
            } label: {
                ScaleRatioLabel(s: sMM)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 11)
                    .contentShape(Capsule())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .glassEffect(in: Capsule())
            .glassHairline(shape: .capsule)
            .onHover { hoveringScale = $0 }
            .overlay(alignment: .top) {
                ScaleTooltip(s: sMM)
                    .opacity(hoveringScale ? 1 : 0)
                    .scaleEffect(hoveringScale ? 1 : 0.94, anchor: .bottom)
                    .offset(y: -12)
                    .allowsHitTesting(false)
                    .animation(.smooth(duration: 0.18), value: hoveringScale)
                    .alignmentGuide(.top) { d in d[.bottom] }
            }
        }
        .padding(16)
    }

    // MARK: - Grid

    private func drawGrid(ctx: GraphicsContext, size: CGSize, s: CGFloat, cx: CGFloat, cy: CGFloat, bcx: CGFloat, bcy: CGFloat) {
        guard s > 0, s.isFinite else { return }
        let targetMinorPx: CGFloat = 12
        let raw = targetMinorPx / s
        let pow10 = pow(10.0, floor(log10(raw)))
        let mult: CGFloat = {
            for m in [1.0, 2.0, 5.0] as [CGFloat] {
                if m * pow10 * s >= targetMinorPx { return m }
            }
            return 10.0
        }()
        let minor = mult * pow10
        let major = minor * 10

        let minWX = (0 - cx) / s + bcx
        let maxWX = (size.width - cx) / s + bcx
        let maxWY = -(0 - cy) / s + bcy
        let minWY = -(size.height - cy) / s + bcy

        let minorColor = Color(red: 0.88, green: 0.90, blue: 0.93)
        let majorColor = Color(red: 0.78, green: 0.81, blue: 0.86)
        let axisColor = Color(red: 0.62, green: 0.66, blue: 0.73)

        var minorPath = Path()
        var majorPath = Path()
        var axisPath = Path()

        var x = floor(minWX / minor) * minor
        while x <= maxWX {
            let sx = cx + (x - bcx) * s
            let isMajor = abs(x.remainder(dividingBy: major)) < minor * 0.01
            let isAxis = abs(x) < minor * 0.5
            var p = Path()
            p.move(to: CGPoint(x: sx, y: 0))
            p.addLine(to: CGPoint(x: sx, y: size.height))
            if isAxis { axisPath.addPath(p) }
            else if isMajor { majorPath.addPath(p) }
            else { minorPath.addPath(p) }
            x += minor
        }

        var y = floor(minWY / minor) * minor
        while y <= maxWY {
            let sy = cy - (y - bcy) * s
            let isMajor = abs(y.remainder(dividingBy: major)) < minor * 0.01
            let isAxis = abs(y) < minor * 0.5
            var p = Path()
            p.move(to: CGPoint(x: 0, y: sy))
            p.addLine(to: CGPoint(x: size.width, y: sy))
            if isAxis { axisPath.addPath(p) }
            else if isMajor { majorPath.addPath(p) }
            else { minorPath.addPath(p) }
            y += minor
        }

        ctx.stroke(minorPath, with: .color(minorColor), lineWidth: 0.5)
        ctx.stroke(majorPath, with: .color(majorColor.opacity(0.55)), lineWidth: 0.8)
        ctx.stroke(axisPath, with: .color(axisColor.opacity(0.55)), lineWidth: 1.2)
    }
}
