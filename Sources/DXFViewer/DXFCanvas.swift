import SwiftUI
import AppKit
import DXFViewerCore

@MainActor
final class ViewState: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    // Set by DXFCanvas .onContinuousHover. Gates the scroll-wheel monitor so the
    // LayerPanel's ScrollView gets its own scroll events instead of being eaten here.
    var hovered = false
    // Mirrored from DXFCanvas each layout so focus(on:) can compute fit/center
    // without the GeometryReader.
    var lastSize: CGSize = .zero
    var docBounds: CGRect = .zero
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    // Zoom around the current visual center: scale offset by the same factor so the
    // world point at screen center stays put.
    func zoom(by raw: CGFloat) {
        // Cap per-event step so a single big trackpad / momentum delta can't saturate
        // the [0.01, 1000] clamp in one frame and leave zoom looking dead.
        let step = max(0.5, min(2, raw))
        let target = max(0.01, min(1000, scale * step))
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

    // Zoom + pan so `target` (world rect) sits at the center of the *visible*
    // viewport (canvas minus rightInset for the layer panel) and fills ~65%
    // of it. Matches the body's `fit = min((size-40)/b.w, (size-40)/b.h)` for
    // the state.scale=1 baseline, then offsets the result so screen center
    // lands in the unobscured area instead of behind the panel.
    func focus(on target: CGRect, rightInset: CGFloat = 0) {
        let size = lastSize, b = docBounds
        guard size.width > 0, size.height > 0, b.width > 0, b.height > 0 else { return }
        let visibleW = max(size.width - rightInset, 1)
        let visibleH = size.height
        let fit = min((size.width - 40) / b.width, (size.height - 40) / b.height)
        guard fit > 0 else { return }
        let tw = max(target.width, 1), th = max(target.height, 1)
        let fillRatio: CGFloat = 0.65
        let sTarget = min(visibleW * fillRatio / tw, visibleH * fillRatio / th)
        // 20× cap keeps tiny single-entity picks from blasting to the global 1000× ceiling.
        let stateScale = max(0.01, min(20, sTarget / fit))
        let s = fit * stateScale
        // Visible-area center in canvas coords. cx = size.w/2 + offset.w, so
        // offset.w = (where we want target's center to land on screen) - size.w/2
        //           - (target.midX - b.midX) * s.
        let visCenterX = (size.width - rightInset) / 2
        let visCenterY = size.height / 2
        let off = CGSize(width: visCenterX - size.width / 2 - (target.midX - b.midX) * s,
                         height: visCenterY - size.height / 2 + (target.midY - b.midY) * s)
        animate(to: stateScale, targetOffset: off, duration: 0.45)
    }

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            // Pass through when cursor isn't over the canvas, so LayerPanel's ScrollView
            // (and anything else) receives its own scroll events.
            guard let self, self.hovered else { return event }
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
        observers.append(NotificationCenter.default.addObserver(forName: .dxfZoomIn, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.animateZoom(to: max(0.01, min(1000, (self?.scale ?? 1) * 1.25))) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .dxfZoomOut, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.animateZoom(to: max(0.01, min(1000, (self?.scale ?? 1) * 0.8))) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .dxfFit, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.animate(to: 1, targetOffset: .zero) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .dxfFocusBounds, object: nil, queue: .main) { [weak self] note in
            guard let rect = note.userInfo?["rect"] as? CGRect else { return }
            let rightInset = (note.userInfo?["rightInset"] as? CGFloat) ?? 0
            MainActor.assumeIsolated { self?.focus(on: rect, rightInset: rightInset) }
        })
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for o in observers { NotificationCenter.default.removeObserver(o) }
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
            .onContinuousHover { phase in
                if case .active = phase { state.hovered = true } else { state.hovered = false }
            }
            .onAppear { state.lastSize = geo.size; state.docBounds = bounds }
            .onChange(of: geo.size) { _, new in state.lastSize = new }
            .onChange(of: bounds) { _, new in state.docBounds = new }
            .overlay(alignment: .bottomLeading) {
                controlBar(geo: geo)
            }
            // Ruler in the opposite corner so the left button cluster stays tight.
            .overlay(alignment: .bottomTrailing) {
                ScaleLengthIndicator(s: scaleMM(in: geo.size))
                    .padding(16)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("DXF drawing canvas"))
            .accessibilityValue(Text(accessibilitySummary))
        }
    }

    private var accessibilitySummary: String {
        guard let doc = document else { return "No drawing loaded" }
        let layerCount = doc.layers.count
        return "\(doc.entities.count) entities across \(layerCount) layer\(layerCount == 1 ? "" : "s"). Zoom \(Int(state.scale * 100)) percent."
    }

    // MARK: - Entity drawing

    private func drawEntities(ctx: GraphicsContext, size: CGSize, s: CGFloat, cx: CGFloat, cy: CGFloat, bcx: CGFloat, bcy: CGFloat) {
        guard let rm = renderModel else { return }
        // World→screen transform. Y flips because world Y goes up, screen Y goes down.
        let transform = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: cx - bcx * s, ty: cy + bcy * s)
        let selectionActive = !selection.isEmpty
        // Selection-empty hot path: stroke ONE merged path per (color, weight) bucket.
        // Typical file: 1-3 weights × few colors → tens of draw calls, not thousands.
        if !selectionActive {
            for (bucket, cg) in rm.bulkStroke {
                let p = Path(cg).applying(transform)
                ctx.stroke(p, with: .color(aciColor(bucket.aci)), lineWidth: screenLineWidth(for: bucket.lineWeight))
            }
            for (bucket, cg) in rm.bulkWideStroke {
                let p = Path(cg).applying(transform)
                ctx.stroke(p, with: .color(aciColor(bucket.aci)),
                           style: StrokeStyle(lineWidth: wideStrokeScreenWidth(worldWidth: bucket.worldWidth, zoom: s),
                                              lineCap: .butt, lineJoin: .miter, miterLimit: 4))
            }
            for (aci, cg) in rm.bulkFill {
                let p = Path(cg).applying(transform)
                ctx.fill(p, with: .color(aciColor(aci)))
            }
            drawText(ctx: ctx, size: size, entries: rm.entries, mode: .normal, transform: transform, s: s)
            return
        }

        // Selection-active: per-entity bucketing into dim / selected, keyed by (aci, weight).
        var stroke: [RenderMode: [DXFRenderModel.StrokeBucket: CGMutablePath]] = [.dim: [:], .normal: [:], .selected: [:]]
        var fill: [RenderMode: [Int: CGMutablePath]] = [.dim: [:], .normal: [:], .selected: [:]]
        func strokeBucket(_ mode: RenderMode, _ key: DXFRenderModel.StrokeBucket) -> CGMutablePath {
            if let p = stroke[mode]?[key] { return p }
            let p = CGMutablePath()
            stroke[mode, default: [:]][key] = p
            return p
        }
        func fillBucket(_ mode: RenderMode, _ aci: Int) -> CGMutablePath {
            if let p = fill[mode]?[aci] { return p }
            let p = CGMutablePath()
            fill[mode, default: [:]][aci] = p
            return p
        }
        // Wide-stroke bucket also lives per-mode so selected concrete elements pop.
        var wideStroke: [RenderMode: [DXFRenderModel.WideStrokeBucket: CGMutablePath]] = [.dim: [:], .normal: [:], .selected: [:]]
        func wideStrokeBucket(_ mode: RenderMode, _ key: DXFRenderModel.WideStrokeBucket) -> CGMutablePath {
            if let p = wideStroke[mode]?[key] { return p }
            let p = CGMutablePath()
            wideStroke[mode, default: [:]][key] = p
            return p
        }
        for entry in rm.entries {
            let isSel = selection.contains(.entity(entry.index))
                || selection.contains(.kind(layer: entry.layer, kind: entry.kindName))
                || selection.contains(.layer(entry.layer))
            let mode: RenderMode = isSel ? .selected : .dim
            switch entry.geometry {
            case .stroke(let cg):
                strokeBucket(mode, .init(aci: entry.aci, lineWeight: entry.lineWeight)).addPath(cg)
            case .fill(let cg):
                fillBucket(mode, entry.aci).addPath(cg)
            case .wideStroke(let cg, let w):
                wideStrokeBucket(mode, .init(aci: entry.aci, worldWidth: w)).addPath(cg)
            case .text: break
            }
        }
        // Draw dim, then selected, so selected wins overdraw.
        for m in [RenderMode.dim, .selected] {
            let alpha: Double = (m == .dim) ? 0.14 : 1.0
            if let dict = stroke[m] {
                for (key, cg) in dict {
                    let p = Path(cg).applying(transform)
                    let baseW = screenLineWidth(for: key.lineWeight)
                    let w = (m == .selected) ? max(2.0, baseW * 1.5) : baseW
                    ctx.stroke(p, with: .color(aciColor(key.aci).opacity(alpha)), lineWidth: w)
                }
            }
            if let dict = fill[m] {
                for (aci, cg) in dict {
                    let p = Path(cg).applying(transform)
                    ctx.fill(p, with: .color(aciColor(aci).opacity(alpha)))
                }
            }
            if let dict = wideStroke[m] {
                for (key, cg) in dict {
                    let p = Path(cg).applying(transform)
                    let base = wideStrokeScreenWidth(worldWidth: key.worldWidth, zoom: s)
                    let w = (m == .selected) ? max(base + 2, base * 1.4) : base
                    ctx.stroke(p, with: .color(aciColor(key.aci).opacity(alpha)),
                               style: StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 4))
                }
            }
        }
        drawText(ctx: ctx, size: size, entries: rm.entries, mode: nil, transform: transform, s: s)
    }

    // DXF lineweight (hundredths of mm) → fixed screen-space stroke width.
    // AutoCAD's LWDISPLAY behavior: lineweight is a print measurement, not world-scaled;
    // zooming in doesn't fatten strokes. Clamp to ≥1px so hairline (0) stays visible.
    private func screenLineWidth(for weight: Int) -> CGFloat {
        let mm = CGFloat(weight) / 100
        return max(1.0, mm * pointsPerMM())
    }

    // LWPOLYLINE constant width (world units) → screen-space stroke width.
    // World-scaled when zoomed in (so the geometry stays proportional) but with a
    // pixel floor so thick structural elements stay visibly thicker than 1-px thin
    // lines at zoom-to-fit. minPx > 1.0 = a strict floor: concrete elements always
    // read as heavier than dimension lines.
    private func wideStrokeScreenWidth(worldWidth: CGFloat, zoom: CGFloat) -> CGFloat {
        let minPx: CGFloat = 2.5
        return max(minPx, worldWidth * zoom)
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
            .accessibilityLabel(loadedFileName.map { "Currently viewing \($0). Open another DXF" } ?? "Open DXF file")
            Button {
                state.animate(to: 1, targetOffset: .zero, duration: 0.45)
            } label: {
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .medium))
            }
            .glassIconButton()
            .accessibilityLabel("Fit drawing to window")
            Button { showGrid.toggle() } label: {
                Image(systemName: showGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .font(.system(size: 15, weight: .medium))
            }
            .glassIconButton()
            .accessibilityLabel(showGrid ? "Hide grid" : "Show grid")
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
