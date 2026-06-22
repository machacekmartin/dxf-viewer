import SwiftUI
import AppKit

enum DXFSelector: Hashable {
    case layer(String)
    case kind(layer: String, kind: String)
    case entity(Int)
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
            header
            searchField
            list
            footer
        }
        .frame(width: 296)
        .frame(maxHeight: .infinity)
        .background(
            Rectangle()
                .glassEffect(.clear, in: Rectangle())
                .overlay(Color(red: 0.97, green: 0.98, blue: 1.00).opacity(0.78))
        )
        .overlay(alignment: .leading) {
            // Hairline edge matching the glass button hairlines.
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

    private var header: some View {
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
                .background(Capsule().fill(Color.black.opacity(0.05)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 64) // clears the floating toggle + drag bar
        .padding(.bottom, 12)
    }

    private var searchField: some View {
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
    }

    private var list: some View {
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
                        // Composite id — "line" repeats across layers, so id: \.name
                        // collides at LazyVStack level and dup rows render empty.
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
    }

    @ViewBuilder private var footer: some View {
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
            case 126: moveFocus(-1); return nil
            case 125: moveFocus(1); return nil
            case 124: expandFocused(); return nil
            case 123: collapseFocused(); return nil
            case 36, 76, 49: selectFocused(); return nil
            default: return event
            }
        }
    }

    private func moveFocus(_ delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        if let f = focus, let i = rows.firstIndex(of: f) {
            focus = rows[min(max(0, i + delta), rows.count - 1)]
        } else {
            focus = delta > 0 ? rows.first : rows.last
        }
    }

    private func expandFocused() {
        guard let f = focus else { return }
        switch f {
        case .layer(let n):
            if !expandedLayers.contains(n) {
                _ = withAnimation(.smooth(duration: 0.18)) { expandedLayers.insert(n) }
            } else {
                moveFocus(1)
            }
        case .kind(let l, let k):
            let key = kindKey(l, k)
            if !expandedKinds.contains(key) {
                _ = withAnimation(.smooth(duration: 0.18)) { expandedKinds.insert(key) }
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
                _ = withAnimation(.smooth(duration: 0.18)) { expandedLayers.remove(n) }
            }
        case .kind(let l, let k):
            let key = kindKey(l, k)
            if expandedKinds.contains(key) {
                _ = withAnimation(.smooth(duration: 0.18)) { expandedKinds.remove(key) }
            } else {
                focus = .layer(l)
            }
        case .entity(let i):
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
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
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
