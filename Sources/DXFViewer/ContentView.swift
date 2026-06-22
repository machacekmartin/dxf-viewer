import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: OpenCoordinator
    @State private var document: DXFDocument? = nil
    @State private var renderModel: DXFRenderModel? = nil
    @State private var loadedURL: URL? = nil
    @State private var showImporter = false
    @State private var error: String? = nil
    @State private var showErrorAlert = false
    @State private var dropTargeted = false
    @State private var isLoading = false
    @State private var selection: Set<DXFSelector> = []
    @State private var panelOpen = false
    @State private var escMonitor: Any?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(red: 0.97, green: 0.98, blue: 1.00).ignoresSafeArea()
            DXFCanvas(
                document: document,
                renderModel: renderModel,
                loadedFileName: loadedURL?.lastPathComponent,
                selection: $selection,
                onImport: { showImporter = true })
            VStack(spacing: 0) {
                EdgeDragBar(edge: .top).frame(height: 38)
                Spacer()
            }
            HStack(spacing: 0) {
                Spacer()
                if panelOpen, let doc = document {
                    LayerPanel(layers: doc.layers, entities: doc.entities, selection: $selection)
                        .transition(.move(edge: .trailing))
                }
            }
            panelToggle.padding(16)
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .animation(.smooth(duration: 0.22), value: panelOpen)
        .overlay { dropOverlay }
        .animation(.smooth(duration: 0.18), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first { coordinator.open(url) }
        }
        .onAppear {
            installEscMonitor()
            // Pick up a URL queued before the window appeared (Finder-open at launch).
            if let url = coordinator.pendingOpen {
                coordinator.pendingOpen = nil
                Task { await load(url: url) }
            }
        }
        .onDisappear {
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
        .onChange(of: coordinator.pendingOpen) { _, url in
            guard let url else { return }
            coordinator.pendingOpen = nil
            Task { await load(url: url) }
        }
        .alert("Couldn't open file", isPresented: $showErrorAlert, presenting: error) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder private var dropOverlay: some View {
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
        .accessibilityLabel(panelOpen ? "Hide layer panel" : "Show layer panel")
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 = Escape
            if event.keyCode == 53, !selection.isEmpty || panelOpen {
                selection.removeAll()
                panelOpen = false
                return nil
            }
            return event
        }
    }

    // Parse + render-model build run on a detached task so the main actor stays
    // responsive for huge files. UI mutations hop back via the @MainActor await.
    private func load(url: URL) async {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        isLoading = true
        error = nil
        do {
            let (doc, model) = try await Task.detached(priority: .userInitiated) {
                let d = try parseDXF(url: url)
                let m = DXFRenderModel.build(from: d)
                return (d, m)
            }.value
            document = doc
            renderModel = model
            loadedURL = url
            selection.removeAll()
        } catch {
            self.error = "Parse failed: \(error.localizedDescription)"
            self.showErrorAlert = true
        }
        isLoading = false
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else { return }
            Task { @MainActor in coordinator.open(url) }
        }
        return true
    }
}
