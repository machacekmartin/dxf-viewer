import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum DXFSelector: Hashable {
    case layer(String)
    case kind(layer: String, kind: String)
    case entity(Int)
}

// ponytail: invisible AppKit shim — forwards mouseDown to NSWindow.performDrag so
// the top strip acts as a window-drag handle without intercepting any other event.
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

// Subtle hairline that catches light on glass buttons. Two-tone: bright top, soft bottom,
// gives a faint engraved-edge feel against the liquid glass.
enum GlassHairlineShape { case circle, capsule }

extension View {
    func glassHairline(shape: GlassHairlineShape) -> some View {
        self.overlay {
            switch shape {
            case .circle:
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .black.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.7)
                    .allowsHitTesting(false)
            case .capsule:
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .black.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
    }

    // Manual glass-icon-button styling. We can't use `.buttonStyle(.glass)` because the
    // Liquid Glass style wraps its content in an implicit GlassEffectContainer, which
    // sucks any nested .glassEffect (eg our tooltip bubble) into the button's own glass
    // surface — the tooltip ends up rendered as part of the button instead of floating
    // above it. The scale-capsule pattern (.plain + manual .glassEffect) avoids this.
    func glassIconButton() -> some View {
        self
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .glassEffect(in: Circle())
            .glassHairline(shape: .circle)
            .contentShape(Circle())
    }
}

// Import button toggles between circular icon-only (no file loaded) and a wider
// capsule that shows the file name. Same goal as glassIconButton — keep tooltip glass
// separate from the button's own glass — but it needs two different shapes.
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
            // Glass blur tinted with the app's own background color so it fades into the canvas
            // instead of reading as a white wash over the scene.
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

struct ContentView: View {
    @State private var document: DXFDocument? = nil
    @State private var loadedURL: URL? = nil
    @State private var showImporter = false
    @State private var error: String? = nil
    @State private var dropTargeted = false
    @State private var selection: Set<DXFSelector> = []
    @State private var panelOpen = false
    @State private var escMonitor: Any?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(red: 0.97, green: 0.98, blue: 1.00).ignoresSafeArea()
            DXFCanvas(
                document: document,
                loadedFileName: loadedURL?.lastPathComponent,
                selection: $selection,
                onImport: { showImporter = true })
            VStack(spacing: 0) {
                EdgeDragBar(edge: .top).frame(height: 38)
                Spacer()
            }
            .allowsHitTesting(true)
            HStack(spacing: 0) {
                Spacer()
                if panelOpen, let doc = document {
                    LayerPanel(
                        layers: doc.layers,
                        entities: doc.entities,
                        selection: $selection)
                    .transition(.move(edge: .trailing))
                }
            }
            panelToggle
                .padding(16)
            if let error {
                VStack { Spacer(); Text(error).foregroundStyle(.red).padding() }
            }
        }
        .animation(.smooth(duration: 0.22), value: panelOpen)
        .overlay {
            if dropTargeted {
                ZStack {
                    Rectangle()
                        .glassEffect(.clear, in: Rectangle())
                        .ignoresSafeArea()
                    Label("Drop .dxf here", systemImage: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(in: Capsule())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .allowsHitTesting(false)
            }
        }
        .animation(.smooth(duration: 0.18), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try load(url: url)
            } catch {
                self.error = "Parse failed: \(error.localizedDescription)"
            }
        }
        .onAppear { installEscMonitor() }
        .onDisappear {
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
    }

    @ViewBuilder private var panelToggle: some View {
        Button {
            if panelOpen {
                panelOpen = false
            } else if document != nil {
                panelOpen = true
            }
        } label: {
            Image(systemName: panelOpen ? "sidebar.right" : "sidebar.right")
                .font(.system(size: 15, weight: .medium))
                .symbolVariant(panelOpen ? .fill : .none)
        }
        .glassIconButton()
        .disabled(document == nil)
        .opacity(document == nil ? 0.4 : 1)
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 = Escape
            if event.keyCode == 53 {
                if !selection.isEmpty || panelOpen {
                    selection.removeAll()
                    panelOpen = false
                    return nil
                }
            }
            return event
        }
    }

    private func load(url: URL) throws {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let doc = try parseDXF(url: url)
        document = doc
        loadedURL = url
        selection.removeAll()
        error = nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else { return }
            Task { @MainActor in
                do { try load(url: url) }
                catch { self.error = "Parse failed: \(error.localizedDescription)" }
            }
        }
        return true
    }
}

// MARK: - Layer Panel

func kindIcon(_ kind: String) -> String {
    switch kind {
    case "line": return "line.diagonal"
    case "point": return "smallcircle.filled.circle"
    case "circle": return "circle"
    case "arc": return "circle.dashed"
    case "polyline": return "scribble"
    case "text": return "textformat"
    case "ellipse": return "oval"
    default: return "questionmark"
    }
}

private func fmtCoord(_ v: CGFloat) -> String {
    if abs(v) >= 1000 { return String(format: "%.0f", Double(v)) }
    if abs(v) >= 10 { return String(format: "%.1f", Double(v)) }
    return String(format: "%.2f", Double(v))
}

func entityDescription(_ e: DXFEntity) -> String {
    switch e.kind {
    case .line(let a, let b):
        return "(\(fmtCoord(a.x)), \(fmtCoord(a.y))) → (\(fmtCoord(b.x)), \(fmtCoord(b.y)))"
    case .point(let p):
        return "(\(fmtCoord(p.x)), \(fmtCoord(p.y)))"
    case .circle(let c, let r):
        return "r \(fmtCoord(r)) at (\(fmtCoord(c.x)), \(fmtCoord(c.y)))"
    case .arc(_, let r, let sa, let ea):
        return "r \(fmtCoord(r)), \(fmtCoord(sa))° → \(fmtCoord(ea))°"
    case .polyline(let pts, let closed):
        return "\(pts.count) pts\(closed ? " · closed" : "")"
    case .text(_, let s, _, _, _, _, _, _):
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(empty)" : "“\(t)”"
    case .ellipse(let c, _, let ratio, _, _):
        return "ratio \(fmtCoord(ratio)) at (\(fmtCoord(c.x)), \(fmtCoord(c.y)))"
    case .spline(let cps, let deg, _, let closed):
        return "deg \(deg) · \(cps.count) ctrl pts\(closed ? " · closed" : "")"
    case .hatch(let pts):
        return "\(pts.count) boundary pts"
    case .dimension(let children):
        return "\(children.count) parts"
    case .leader(let pts, _):
        return "\(pts.count) pts"
    case .insert: return ""
    }
}

enum DXFFocus: Hashable {
    case layer(String)
    case kind(layer: String, kind: String)
    case entity(Int)

    var asSelector: DXFSelector {
        switch self {
        case .layer(let n): return .layer(n)
        case .kind(let l, let k): return .kind(layer: l, kind: k)
        case .entity(let i): return .entity(i)
        }
    }
}

struct LayerPanel: View {
    let layers: [DXFLayerInfo]
    let entities: [DXFEntity]
    @Binding var selection: Set<DXFSelector>
    @State private var search = ""
    @State private var expandedLayers: Set<String> = []
    @State private var expandedKinds: Set<String> = [] // key = "layer\u{1F}kind"
    @State private var focus: DXFFocus? = nil
    @State private var keyMonitor: Any?

    private func kindKey(_ layer: String, _ kind: String) -> String { "\(layer)\u{1F}\(kind)" }

    private var filtered: [DXFLayerInfo] {
        guard !search.isEmpty else { return layers }
        let q = search
        return layers.compactMap { l -> DXFLayerInfo? in
            let layerMatches = l.name.localizedCaseInsensitiveContains(q)
            let kindMatches = l.kinds.contains { $0.name.localizedCaseInsensitiveContains(q) }
            let entityMatches = l.kinds.contains { kind in
                kind.indices.contains { i in
                    entityDescription(entities[i]).localizedCaseInsensitiveContains(q)
                }
            }
            return (layerMatches || kindMatches || entityMatches) ? l : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layers")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.16, blue: 0.22))
                Spacer()
                Text("\(layers.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.42, green: 0.45, blue: 0.52))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.black.opacity(0.05)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 64) // clears the floating toggle + drag bar
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.40, green: 0.43, blue: 0.50))
                TextField("Search layers, kinds, entities…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.14, green: 0.16, blue: 0.22))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.7)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.7))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered, id: \.name) { l in
                        LayerRow(
                            info: l,
                            isSelected: selection.contains(.layer(l.name)),
                            isFocused: focus == .layer(l.name),
                            isExpanded: expandedLayers.contains(l.name),
                            onTap: { focus = .layer(l.name); toggle(.layer(l.name)) },
                            onDisclose: { toggleExpand(layer: l.name) }
                        )
                        if expandedLayers.contains(l.name) {
                            // ponytail: composite id — "line" repeats across layers, so id: \.name
                            // collides at LazyVStack level and the dup row renders empty.
                            // Nested ScrollViews break scroll-wheel propagation on macOS
                            // (the inner one swallows the event even when at its bounds),
                            // so kinds + entities now flow inline in the outer ScrollView.
                            let kindItems = l.kinds.map { (id: kindKey(l.name, $0.name), kind: $0) }
                            ForEach(kindItems, id: \.id) { item in
                                let k = item.kind
                                KindRow(
                                    layerName: l.name,
                                    kind: k,
                                    isSelected: selection.contains(.kind(layer: l.name, kind: k.name)),
                                    isFocused: focus == .kind(layer: l.name, kind: k.name),
                                    isExpanded: expandedKinds.contains(kindKey(l.name, k.name)),
                                    onTap: { focus = .kind(layer: l.name, kind: k.name); toggle(.kind(layer: l.name, kind: k.name)) },
                                    onDisclose: { toggleExpand(kindOn: l.name, kind: k.name) }
                                )
                                if expandedKinds.contains(kindKey(l.name, k.name)) {
                                    ForEach(k.indices, id: \.self) { i in
                                        EntityRow(
                                            index: i,
                                            entity: entities[i],
                                            isSelected: selection.contains(.entity(i)),
                                            isFocused: focus == .entity(i),
                                            onTap: { focus = .entity(i); toggle(.entity(i)) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text("No matches for “\(search)”")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
            .scrollIndicators(.hidden)

            if !selection.isEmpty {
                Divider().overlay(Color.black.opacity(0.08))
                HStack {
                    Text("\(selection.count) selected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.40, green: 0.43, blue: 0.50))
                    Spacer()
                    Button("Clear") { selection.removeAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 296)
        .frame(maxHeight: .infinity)
        .background(
            Rectangle()
                .glassEffect(.clear, in: Rectangle())
                .overlay(Color(red: 0.97, green: 0.98, blue: 1.00).opacity(0.78))
        )
        .overlay(alignment: .leading) {
            // Glassy hairline edge — same vocabulary as the button hairlines.
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .black.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom))
                .frame(width: 0.7)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    // MARK: - Keyboard navigation

    private var visibleRows: [DXFFocus] {
        var rows: [DXFFocus] = []
        for l in filtered {
            rows.append(.layer(l.name))
            guard expandedLayers.contains(l.name) else { continue }
            for k in l.kinds {
                rows.append(.kind(layer: l.name, kind: k.name))
                guard expandedKinds.contains(kindKey(l.name, k.name)) else { continue }
                for i in k.indices { rows.append(.entity(i)) }
            }
        }
        return rows
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't steal arrow keys while user is typing into the search field.
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSText { return event }
            switch event.keyCode {
            case 126: moveFocus(-1); return nil // up
            case 125: moveFocus(1); return nil  // down
            case 124: expandFocused(); return nil // right
            case 123: collapseFocused(); return nil // left
            case 36, 76, 49: selectFocused(); return nil // return / numpad enter / space
            default: return event
            }
        }
    }

    private func moveFocus(_ delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        if let f = focus, let i = rows.firstIndex(of: f) {
            let next = min(max(0, i + delta), rows.count - 1)
            focus = rows[next]
        } else {
            focus = delta > 0 ? rows.first : rows.last
        }
    }

    private func expandFocused() {
        guard let f = focus else { return }
        switch f {
        case .layer(let n):
            if !expandedLayers.contains(n) {
                withAnimation(.smooth(duration: 0.18)) { expandedLayers.insert(n) }
            } else {
                moveFocus(1) // already expanded → step into first child
            }
        case .kind(let l, let k):
            let key = kindKey(l, k)
            if !expandedKinds.contains(key) {
                withAnimation(.smooth(duration: 0.18)) { expandedKinds.insert(key) }
            } else {
                moveFocus(1)
            }
        case .entity: break
        }
    }

    private func collapseFocused() {
        guard let f = focus else { return }
        switch f {
        case .layer(let n):
            if expandedLayers.contains(n) {
                withAnimation(.smooth(duration: 0.18)) { expandedLayers.remove(n) }
            }
        case .kind(let l, let k):
            let key = kindKey(l, k)
            if expandedKinds.contains(key) {
                withAnimation(.smooth(duration: 0.18)) { expandedKinds.remove(key) }
            } else {
                focus = .layer(l) // step up to parent layer
            }
        case .entity(let i):
            // Walk up to the parent kind row.
            if let parent = parentKind(of: i) {
                focus = .kind(layer: parent.layer, kind: parent.kind)
            }
        }
    }

    private func parentKind(of entityIndex: Int) -> (layer: String, kind: String)? {
        for l in layers {
            for k in l.kinds where k.indices.contains(entityIndex) {
                return (l.name, k.name)
            }
        }
        return nil
    }

    private func selectFocused() {
        guard let f = focus else { return }
        toggle(f.asSelector)
    }

    private func toggle(_ sel: DXFSelector) {
        let additive = NSEvent.modifierFlags.contains(.command)
        if additive {
            if selection.contains(sel) { selection.remove(sel) } else { selection.insert(sel) }
        } else {
            selection = (selection == [sel]) ? [] : [sel]
        }
    }

    private func toggleExpand(layer: String) {
        withAnimation(.smooth(duration: 0.2)) {
            if expandedLayers.contains(layer) { expandedLayers.remove(layer) }
            else { expandedLayers.insert(layer) }
        }
    }

    private func toggleExpand(kindOn layer: String, kind: String) {
        let key = kindKey(layer, kind)
        withAnimation(.smooth(duration: 0.2)) {
            if expandedKinds.contains(key) { expandedKinds.remove(key) }
            else { expandedKinds.insert(key) }
        }
    }
}

// MARK: - Row components

private struct DisclosureCaret: View {
    let isExpanded: Bool
    let onTap: () -> Void
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(red: 0.30, green: 0.33, blue: 0.40))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.smooth(duration: 0.15), value: isExpanded)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
    }
}

private struct RowShell<Content: View>: View {
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void
    let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(borderFill, lineWidth: borderWidth))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isFocused { return Color.accentColor.opacity(0.08) }
        if hovering { return Color.black.opacity(0.05) }
        return .clear
    }
    private var borderFill: Color {
        if isSelected { return Color.accentColor.opacity(0.35) }
        if isFocused { return Color.accentColor.opacity(0.22) }
        return .clear
    }
    private var borderWidth: CGFloat { (isSelected || isFocused) ? 1 : 0 }
}

struct LayerRow: View {
    let info: DXFLayerInfo
    let isSelected: Bool
    let isFocused: Bool
    let isExpanded: Bool
    let onTap: () -> Void
    let onDisclose: () -> Void

    var body: some View {
        RowShell(isSelected: isSelected, isFocused: isFocused, action: onTap) {
            HStack(spacing: 8) {
                DisclosureCaret(isExpanded: isExpanded, onTap: onDisclose)
                Circle()
                    .fill(aciColor(info.aci))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                Text(info.name.isEmpty ? "(default)" : info.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color(red: 0.14, green: 0.16, blue: 0.22))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(info.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.45, green: 0.48, blue: 0.55))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

struct KindRow: View {
    let layerName: String
    let kind: DXFLayerInfo.Kind
    let isSelected: Bool
    let isFocused: Bool
    let isExpanded: Bool
    let onTap: () -> Void
    let onDisclose: () -> Void

    var body: some View {
        RowShell(isSelected: isSelected, isFocused: isFocused, action: onTap) {
            HStack(spacing: 8) {
                DisclosureCaret(isExpanded: isExpanded, onTap: onDisclose)
                Image(systemName: kindIcon(kind.name))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.32, green: 0.35, blue: 0.42))
                    .frame(width: 14)
                Text(kind.name)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.33))
                Spacer(minLength: 6)
                Text("\(kind.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.50, green: 0.53, blue: 0.60))
                    .monospacedDigit()
            }
            .padding(.leading, 26)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
        }
    }
}

struct EntityRow: View {
    let index: Int
    let entity: DXFEntity
    let isSelected: Bool
    let isFocused: Bool
    let onTap: () -> Void

    var body: some View {
        RowShell(isSelected: isSelected, isFocused: isFocused, action: onTap) {
            HStack(spacing: 8) {
                Text("#\(index)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 0.58, blue: 0.65))
                    .frame(minWidth: 34, alignment: .leading)
                Text(entityDescription(entity))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(red: 0.30, green: 0.33, blue: 0.40))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 50)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
        }
    }
}

// SwiftUI "points" are logical units; their physical size depends on the actual display.
// For a TRUE 1:N scale (architect-correct), we need logical points per physical mm of the
// screen the window is on. CGDisplayScreenSize gives the screen's physical width in mm and
// NSScreen.frame.width gives its logical width in points — the ratio is what we need.
// Multi-monitor: NSApp.keyWindow?.screen lets us pick the screen the user is actually on
// rather than always returning the primary display. "Scaled" display modes (the Mac default
// "looks like 1680×1050" etc) make CGDisplayPixelsWide diverge from the logical point space,
// so frame.width is the correct numerator here, not pixelsWide / backingScale.
@MainActor
func pointsPerMM(screen: NSScreen? = nil) -> CGFloat {
    let s = screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
    guard let s else { return 72.0 / 25.4 }
    let displayID = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    let mmWide = CGFloat(CGDisplayScreenSize(displayID).width)
    guard mmWide > 0 else { return 72.0 / 25.4 }
    return s.frame.width / mmWide
}

// Split-out pieces: the interactive 1:N label (used inside the menu capsule), and the
// non-interactive length indicator (ticks + "500 mm") that sits next to the capsule as
// pure informational chrome.
private func scaleBarLength(s: CGFloat, target: CGFloat = 100) -> CGFloat {
    let safe = max(s, 1e-9)
    let p10 = pow(10.0, floor(log10(target / safe)))
    var mult: CGFloat = 10
    for m in [1.0, 2.0, 5.0] as [CGFloat] {
        if m * p10 * safe >= target * 0.6 { mult = m; break }
    }
    return mult * p10
}

private func formatScaleRatio(_ r: CGFloat) -> String {
    let precision = r >= 100 ? 1 : 2
    var s = String(format: "%.\(precision)f", Double(r))
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return "1:\(s)"
}

// Pick the most readable unit for a length expressed in millimetres. The bar lengths come
// from the 1/2/5×10ⁿ bucket so values are always "clean" — no fractions needed at ≥1 mm.
// %g trims trailing zeros for sub-mm tails like 0.5/0.2.
private func formatScaleLength(_ mm: CGFloat) -> String {
    if mm >= 1000 { return String(format: "%g m", Double(mm / 1000)) }
    if mm >= 10   { return String(format: "%g cm", Double(mm / 10)) }
    if mm >= 1    { return String(format: "%g mm", Double(mm)) }
    return String(format: "%g mm", Double(mm))
}

struct ScaleRatioLabel: View {
    // Points-per-world-millimetre (caller scales by mmPerUnit). The 1:N ratio is
    // pointsPerMM / sMM — both numerator and denominator are points-per-mm so the ratio
    // is unitless real-world-mm per screen-mm.
    let s: CGFloat
    // Width reserved for the longest plausible label ("1:9999.9" in 11pt SF Mono).
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

// Explanatory tooltip for the scale capsule. Mirrors ScaleRatioLabel + ScaleLengthIndicator
// and spells out what they mean in plain English, with the current bar length as a concrete example.
struct ScaleTooltip: View {
    let s: CGFloat // points per world millimetre (see ScaleRatioLabel)
    var body: some View {
        let safe = max(s, 1e-9)
        let ratio = pointsPerMM() / safe
        let d = scaleBarLength(s: safe)
        let onScreen = d / max(ratio, 1e-9) // physical mm on screen for that world length
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

    // Strip the "1:" prefix that formatScaleRatio prepends — the sentence reads
    // "100× smaller", not "1:100× smaller".
    private func ratioMultiplier(_ r: CGFloat) -> String {
        let full = formatScaleRatio(r)
        return full.hasPrefix("1:") ? String(full.dropFirst(2)) : full
    }
}

// Figma-style floating icon button: 32×32 hit area, hover/press highlight, monochrome icon.
struct FloatyIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color(red: 0.20, green: 0.22, blue: 0.27))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.black.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// AutoCAD Color Index → SwiftUI Color, tuned for a light background.
// 7 is "white/black" — black on light bg. Everything else uses muted variants of the standard ACI palette.
func aciColor(_ aci: Int) -> Color {
    switch aci {
    case 1: return Color(red: 0.85, green: 0.10, blue: 0.10) // red
    case 2: return Color(red: 0.70, green: 0.60, blue: 0.05) // yellow→ochre (yellow invisible on light)
    case 3: return Color(red: 0.00, green: 0.58, blue: 0.00) // green
    case 4: return Color(red: 0.00, green: 0.55, blue: 0.65) // cyan
    case 5: return Color(red: 0.10, green: 0.10, blue: 0.85) // blue
    case 6: return Color(red: 0.70, green: 0.00, blue: 0.70) // magenta
    case 8: return Color(red: 0.45, green: 0.45, blue: 0.50) // dark gray
    case 9: return Color(red: 0.60, green: 0.60, blue: 0.66) // light gray
    default: return Color(red: 0.12, green: 0.13, blue: 0.16) // 7 / unknown → near-black
    }
}

// ponytail: reference-typed state so the NSEvent monitor closure mutates live values,
// not a stale copy of a View struct.
@MainActor
final class ViewState: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    var monitor: Any?

    // Zoom around the current visual center: scale offset by the same factor so the
    // world point at screen center stays put. Clamped scale; offset clamped accordingly.
    func zoom(by raw: CGFloat) {
        let target = max(0.01, min(1000, scale * raw))
        let factor = target / scale
        scale = target
        offset = CGSize(width: offset.width * factor, height: offset.height * factor)
    }

    // ponytail: Canvas doesn't interpolate @Published mutations under withAnimation —
    // it redraws on each set. So we tween manually on the main actor.
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
                let eased = 1 - pow(1 - t, 3) // ease-out cubic
                self?.scale = startScale + (targetScale - startScale) * CGFloat(eased)
                self?.offset = CGSize(
                    width: startOffset.width + (targetOffset.width - startOffset.width) * CGFloat(eased),
                    height: startOffset.height + (targetOffset.height - startOffset.height) * CGFloat(eased))
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
            }
        }
    }

    func animateZoom(to absoluteScale: CGFloat) {
        // Keep visual center fixed (same math as zoom(by:))
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
                    let raw = 1 + event.scrollingDeltaY * 0.01
                    self.zoom(by: raw)
                }
                return nil
            case .magnify:
                self.zoom(by: 1 + event.magnification)
                return nil
            default:
                return event
            }
        }
    }
}

private enum RenderMode: Hashable { case dim, normal, selected }

struct DXFCanvas: View {
    let document: DXFDocument?
    var loadedFileName: String? = nil
    @Binding var selection: Set<DXFSelector>
    var onImport: () -> Void = {}
    @StateObject private var state = ViewState()
    @State private var lastDrag: CGSize = .zero
    @State private var hoveringScale = false
    @State private var showGrid = true

    // ponytail: empty scene → 1×1m centered on origin so grid + scale bar still work.
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
                let bcx = b.midX, bcy = b.midY

                func tx(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: cx + (p.x - bcx) * s, y: cy - (p.y - bcy) * s)
                }

                if showGrid {
                    drawGrid(ctx: ctx, size: size, s: s, cx: cx, cy: cy, bcx: bcx, bcy: bcy)
                }

                // Bucket per (mode, aci) so we batch strokes within each visual treatment.
                let selectionActive = !selection.isEmpty
                var stroke: [RenderMode: [Int: Path]] = [.dim: [:], .normal: [:], .selected: [:]]
                var fill: [RenderMode: [Int: Path]] = [.dim: [:], .normal: [:], .selected: [:]]

                let entities = document?.entities ?? []
                // Flatten DIMENSION wrappers so the existing switch can keep rendering one
                // entity at a time. Children inherit the wrapper's aci / layer / index so
                // selection of the dimension highlights all its parts in unison.
                var renderQueue: [(entity: DXFEntity, parentIndex: Int)] = []
                for i in entities.indices {
                    let e = entities[i]
                    if case .dimension(let children) = e.kind {
                        for c in children {
                            renderQueue.append((DXFEntity(kind: c.kind, aci: e.aci, layer: e.layer), i))
                        }
                    } else {
                        renderQueue.append((e, i))
                    }
                }
                for item in renderQueue {
                    let e = item.entity
                    let i = item.parentIndex
                    let isSel = selection.contains(.entity(i))
                        || selection.contains(.kind(layer: e.layer, kind: e.kind.typeName))
                        || selection.contains(.layer(e.layer))
                    let mode: RenderMode = selectionActive
                        ? (isSel ? .selected : .dim)
                        : .normal
                    switch e.kind {
                    case .line(let a, let b):
                        var p = stroke[mode]![e.aci] ?? Path()
                        p.move(to: tx(a)); p.addLine(to: tx(b))
                        stroke[mode]![e.aci] = p
                    case .point(let p):
                        let pt = tx(p)
                        var path = fill[mode]![e.aci] ?? Path()
                        path.addEllipse(in: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3))
                        fill[mode]![e.aci] = path
                    case .circle(let c, let r):
                        let p = tx(c)
                        var path = stroke[mode]![e.aci] ?? Path()
                        path.addEllipse(in: CGRect(x: p.x - r * s, y: p.y - r * s, width: r * 2 * s, height: r * 2 * s))
                        stroke[mode]![e.aci] = path
                    case .arc(let c, let r, let start, let end):
                        let p = tx(c)
                        var path = stroke[mode]![e.aci] ?? Path()
                        // Without an explicit move, addArc connects from the previous subpath's
                        // endpoint with a straight line — looks like stray triangles / leader lines.
                        let startRad = -Double(start) * .pi / 180
                        let startPt = CGPoint(
                            x: p.x + r * s * CGFloat(cos(startRad)),
                            y: p.y + r * s * CGFloat(sin(startRad)))
                        path.move(to: startPt)
                        path.addArc(
                            center: p, radius: r * s,
                            startAngle: .degrees(-Double(start)),
                            endAngle: .degrees(-Double(end)),
                            clockwise: true)
                        stroke[mode]![e.aci] = path
                    case .polyline(let pts, let closed):
                        guard let first = pts.first else { break }
                        var path = stroke[mode]![e.aci] ?? Path()
                        path.move(to: tx(first))
                        for p in pts.dropFirst() { path.addLine(to: tx(p)) }
                        if closed { path.addLine(to: tx(first)) }
                        stroke[mode]![e.aci] = path
                    case .ellipse(let c, let mv, let ratio, let sa, let ea):
                        let minorVec = CGPoint(x: -mv.y * ratio, y: mv.x * ratio)
                        let steps = 64
                        var sweep = ea - sa
                        if sweep <= 0 { sweep += 2 * .pi }
                        var path = stroke[mode]![e.aci] ?? Path()
                        var first = true
                        for k in 0...steps {
                            let t = sa + sweep * CGFloat(k) / CGFloat(steps)
                            let p = CGPoint(
                                x: c.x + mv.x * cos(t) + minorVec.x * sin(t),
                                y: c.y + mv.y * cos(t) + minorVec.y * sin(t))
                            let sp = tx(p)
                            if first { path.move(to: sp); first = false } else { path.addLine(to: sp) }
                        }
                        stroke[mode]![e.aci] = path
                    case .text(let p, let str, let h, let rot, let hAlign, let vAlign, let wrapW, let lineSp):
                        if mode == .dim { break }
                        let pt = tx(p)
                        // DXF height = cap height; SwiftUI font(size:) = em / point size.
                        let visualFontSize = min(200, h * s / 0.72)
                        if visualFontSize < 4 { break }
                        _ = lineSp
                        // Render at a fixed base size and scale via transform so the font hinter
                        // only ever sees one point size — eliminates the per-frame glyph wobble
                        // that shows up during zoom.
                        let baseFontSize: CGFloat = 100
                        let k = visualFontSize / baseFontSize
                        let txt = Text(str)
                            .font(.system(size: baseFontSize, design: .default))
                            .foregroundColor(aciColor(e.aci))
                        let resolved = ctx.resolve(txt)
                        let baseMeasureW: CGFloat = wrapW > 0 ? (wrapW * s / k) : 10000
                        let baseSz = resolved.measure(in: CGSize(width: baseMeasureW, height: 10000))
                        let ax: CGFloat = {
                            switch hAlign {
                            case 1: return baseSz.width / 2
                            case 2: return baseSz.width
                            default: return 0
                            }
                        }()
                        let ay: CGFloat = {
                            switch vAlign {
                            case 3: return 0
                            case 2: return baseSz.height / 2
                            default: return baseSz.height
                            }
                        }()
                        ctx.drawLayer { layer in
                            layer.translateBy(x: pt.x, y: pt.y)
                            if abs(rot) > 1e-9 { layer.rotate(by: .degrees(-Double(rot))) }
                            layer.scaleBy(x: k, y: k)
                            layer.draw(resolved, in: CGRect(
                                x: -ax,
                                y: -ay,
                                width: baseSz.width,
                                height: baseSz.height))
                        }
                    case .spline(let cps, let deg, let knots, let closed):
                        // Tessellate the B-spline once per draw; route through the same
                        // stroke bucket as polylines so it picks up dim/normal/selected
                        // batching for free.
                        let curve = tessellateSpline(controlPoints: cps, knots: knots, degree: deg)
                        guard let first = curve.first else { break }
                        var path = stroke[mode]![e.aci] ?? Path()
                        path.move(to: tx(first))
                        for p in curve.dropFirst() { path.addLine(to: tx(p)) }
                        if closed { path.addLine(to: tx(first)) }
                        stroke[mode]![e.aci] = path
                    case .hatch(let pts):
                        // Outline-only render (no fill pattern). Boundary is the polygon
                        // of group-10/20 vertices the parser collected, closed back to start.
                        guard let first = pts.first else { break }
                        var path = stroke[mode]![e.aci] ?? Path()
                        path.move(to: tx(first))
                        for p in pts.dropFirst() { path.addLine(to: tx(p)) }
                        path.addLine(to: tx(first))
                        stroke[mode]![e.aci] = path
                    case .dimension: break // flattened above; nothing to draw here
                    case .leader(let pts, let arrow):
                        // Path: stroke through pts. Arrow: small filled triangle at pts[0]
                        // oriented along the first segment. Same geometry the parser used
                        // to compute before we promoted LEADER to its own entity.
                        guard let first = pts.first else { break }
                        var lp = stroke[mode]![e.aci] ?? Path()
                        lp.move(to: tx(first))
                        for p in pts.dropFirst() { lp.addLine(to: tx(p)) }
                        stroke[mode]![e.aci] = lp
                        if pts.count >= 2 {
                            let a = pts[0], b = pts[1]
                            let dx = b.x - a.x, dy = b.y - a.y
                            let len = hypot(dx, dy)
                            if len > 1e-6 {
                                let ux = dx / len, uy = dy / len
                                let nx = -uy, ny = ux
                                let backCenter = CGPoint(x: a.x + ux * arrow, y: a.y + uy * arrow)
                                let w = arrow * 0.4
                                let p1 = CGPoint(x: backCenter.x + nx * w, y: backCenter.y + ny * w)
                                let p2 = CGPoint(x: backCenter.x - nx * w, y: backCenter.y - ny * w)
                                var fp = fill[mode]![e.aci] ?? Path()
                                fp.move(to: tx(a)); fp.addLine(to: tx(p1)); fp.addLine(to: tx(p2)); fp.closeSubpath()
                                fill[mode]![e.aci] = fp
                            }
                        }
                    case .insert: break
                    }
                }

                // Draw order: dim → normal → selected so selected wins overdraw.
                for m in [RenderMode.dim, .normal, .selected] {
                    let alpha: Double = (m == .dim) ? 0.14 : 1.0
                    let width: CGFloat = (m == .selected) ? 2.0 : 1.0
                    for (aci, path) in stroke[m]! {
                        ctx.stroke(path, with: .color(aciColor(aci).opacity(alpha)), lineWidth: width)
                    }
                    for (aci, path) in fill[m]! {
                        ctx.fill(path, with: .color(aciColor(aci).opacity(alpha)))
                    }
                }
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
                let pad: CGFloat = 40
                let b = bounds
                let fit = min((geo.size.width - pad) / b.width, (geo.size.height - pad) / b.height)
                let s = fit * state.scale
                // Convert points-per-world-unit → points-per-millimetre using the unit
                // multiplier from $INSUNITS so the scale capsule reads correctly for files
                // drawn in metres / inches / feet, not only millimetres.
                let mmPerUnit = document?.mmPerUnit ?? 1
                let sMM = s / mmPerUnit
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
            // Ruler + length label lives in the opposite corner so the left-hand button
            // cluster can stay tight to the scale capsule without dragging a wide ruler
            // along with it on small windows.
            .overlay(alignment: .bottomTrailing) {
                let pad: CGFloat = 40
                let b = bounds
                let fit = min((geo.size.width - pad) / b.width, (geo.size.height - pad) / b.height)
                let s = fit * state.scale
                let mmPerUnit = document?.mmPerUnit ?? 1
                let sMM = s / mmPerUnit
                ScaleLengthIndicator(s: sMM)
                    .padding(16)
            }
        }
    }

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

        // Cool gray-blue grid to match the cool background.
        let minorColor = Color(red: 0.88, green: 0.90, blue: 0.93)
        let majorColor = Color(red: 0.78, green: 0.81, blue: 0.86)
        let axisColor = Color(red: 0.62, green: 0.66, blue: 0.73)

        var minorPath = Path()
        var majorPath = Path()
        var axisPath = Path()

        let startX = floor(minWX / minor) * minor
        var x = startX
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

        let startY = floor(minWY / minor) * minor
        var y = startY
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
