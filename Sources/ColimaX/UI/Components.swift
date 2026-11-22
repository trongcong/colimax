import AppKit
import SwiftUI

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

extension DockerContainer {
    var stateColor: Color {
        switch state {
        case "running": .green
        case "paused": .yellow
        case "restarting", "created": .orange
        case "dead": .red
        default: .gray
        }
    }
}

extension ColimaProfile {
    var statusColor: Color {
        switch status.lowercased() {
        case "running": .green
        case "broken": .red
        default: .gray
        }
    }
}

struct Banner: View {
    enum Kind { case error, info }
    let kind: Kind
    let message: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(kind == .error ? .orange : .green)
            // Don't use fixedSize(vertical:): when SwiftUI measures the window's minimum height at a very
            // narrow width, word-by-word wrapping pushes that minimum past the window height, so all content
            // (sidebar + main screen) is centered and overflows under the titlebar. Cap the line count; the tooltip shows the full text.
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(1...4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(message)
                .accessibilityIdentifier(kind == .error ? "banner.error" : "banner.info")
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background((kind == .error ? Color.orange : Color.green).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Shows a placeholder instead of a Docker screen while profiles load, when there is no profile,
/// when the VM isn't running, or when the runtime isn't docker.
struct DockerGate<Content: View>: View {
    @Environment(AppStore.self) private var store
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !store.profilesLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.selectedProfile == nil {
            ContentUnavailableView("No Colima profile yet", systemImage: "shippingbox",
                                   description: Text("Create a profile in Runtime Settings."))
        } else if !store.isRunning {
            ContentUnavailableView {
                Label("VM \(store.selectedProfileName) is not running", systemImage: "moon.zzz")
            } actions: {
                Button("Start") { store.runtimeModel.startVM() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.operations.isOperationRunning)
            }
        } else if !store.supportsDocker {
            ContentUnavailableView("Runtime \(store.selectedProfile?.runtime ?? "") is not supported yet",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("This screen requires the docker runtime."))
        } else {
            content()
        }
    }
}

/// AppKit text view for logs / large JSON: faster than SwiftUI Text, with Cmd+F.
/// When new text only extends the old one (log streams), just the new suffix is appended
/// instead of replacing the whole string, avoiding a full document re-layout on every update.
struct CodeTextView: NSViewRepresentable {
    let text: String
    var autoScroll = false

    final class Coordinator {
        var shown = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Self.font
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel(String(localized: "Text content"))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        let shown = context.coordinator.shown
        guard text != shown else { return }
        if !shown.isEmpty, text.count > shown.count, text.hasPrefix(shown) {
            let suffix = String(text[text.index(text.startIndex, offsetBy: shown.count)...])
            storage.append(NSAttributedString(string: suffix, attributes: Self.attributes))
        } else {
            textView.string = text
            textView.font = Self.font
            textView.textColor = .textColor
        }
        context.coordinator.shown = text
        if autoScroll { textView.scrollToEndOfDocument(nil) }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }
}

/// Sheet showing inspect JSON.
struct InspectSheet: View {
    let title: String
    let load: () async throws -> String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") { Pasteboard.copy(text) }.disabled(text.isEmpty)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let error {
                Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if text.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeTextView(text: text)
            }
        }
        .frame(minWidth: 640, idealWidth: 700, maxWidth: .infinity, minHeight: 480, idealHeight: 540, maxHeight: .infinity)
        .task {
            do {
                text = try await load()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Log panel for long operations (colima start, compose, pull).
struct OperationPanel: View {
    @Environment(AppStore.self) private var store
    @State private var expanded = true

    var body: some View {
        if let operation = store.operations.operation {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    switch operation.status {
                    case .running: ProgressView().controlSize(.small)
                    case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Text(operation.title).font(.callout.weight(.medium))
                        .accessibilityIdentifier("operation.title")
                    if case .failed(let message) = operation.status {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                    } else if operation.status == .cancelled {
                        Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("operation.cancelled")
                    }
                    Spacer()
                    if operation.isRunning {
                        Button("Cancel", role: .cancel) { confirmCancel(operation) }
                            .buttonStyle(.borderless)
                            .help("Stop the running operation")
                            .accessibilityIdentifier("operation.cancel")
                    }
                    Button(expanded ? "Collapse" : "Expand") { expanded.toggle() }
                        .buttonStyle(.borderless)
                    if !operation.isRunning {
                        Button { store.operations.dismissOperation() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if expanded {
                    CodeTextView(text: operation.lines.joined(separator: "\n"), autoScroll: true)
                        .frame(minHeight: 60, idealHeight: 160, maxHeight: 160)
                }
            }
            .background(.bar)
        }
    }

    private func confirmCancel(_ operation: OperationState) {
        let ok = Confirm.ask(
            String(localized: "Cancel \(operation.title)?"),
            message: String(localized: "The running process will be stopped. Cancelling while a VM is starting, stopping or being deleted can leave it half-done; if so, run the operation again."),
            button: String(localized: "Cancel Operation"),
            destructive: false
        ).confirmed
        if ok { store.operations.cancelOperation() }
    }
}

struct MeterView: View {
    let title: String
    let value: Double?
    let detail: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(value.map { Format.percent($0 * 100) } ?? "—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, value ?? 0)))
                .tint((value ?? 0) > 0.85 ? .red : tint)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let systemImage {
                Label(title, systemImage: systemImage).font(.headline)
            } else {
                Text(title).font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

/// Runs NSSavePanel / NSOpenPanel modally (call from a button action).
@MainActor
enum FilePanels {
    static func save(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(title: String, multiple: Bool = false, directories: Bool = false) -> [URL] {
        #if COLIMAX_UI_TESTING
        // UI tests cannot drive NSOpenPanel reliably: they hand the file over in the environment.
        if AppServices.isUITestLaunch, let path = ProcessInfo.processInfo.environment["COLIMAX_UI_TEST_OPEN_FILE"] {
            return [URL(fileURLWithPath: path)]
        }
        #endif
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Replacement for `Stepper`: explicit − / + buttons (the macOS ↕ stepper looks like a dropdown).
struct PlusMinusStepper<Label: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Accessibility identifier prefix for the buttons (`<id>.decrease` / `<id>.increase`), for UI tests.
    var identifier: String?
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(spacing: 8) {
            label()
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus").frame(width: 14, height: 14)
                }
                .disabled(value <= range.lowerBound)
                .help("Decrease")
                .accessibilityLabel(Text("Decrease"))
                .accessibilityIdentifier(identifier.map { "\($0).decrease" } ?? "")
                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus").frame(width: 14, height: 14)
                }
                .disabled(value >= range.upperBound)
                .help("Increase")
                .accessibilityLabel(Text("Increase"))
                .accessibilityIdentifier(identifier.map { "\($0).increase" } ?? "")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

extension PlusMinusStepper {
    init(value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, identifier: String? = nil, @ViewBuilder label: @escaping () -> Label) {
        self.init(
            value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: Double(step),
            identifier: identifier,
            label: label
        )
    }
}

/// Status message for sheets (instead of ContentUnavailableView): inside a macOS sheet, its height
/// depends on its width (text wrapping) and feeds a layout loop that hangs the app.
/// The text width is fixed, so the height doesn't depend on the sheet size.
struct SheetMessage: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(width: 520)
                .lineLimit(8)
        }
        .padding(20)
    }
}

/// Stop / restart the selected VM from any button (toolbar, Dashboard, menu bar).
/// Asks first only when containers are running, because they will all be stopped.
@MainActor
enum VMControl {
    /// Shows the confirmation (title, message, button) and returns whether the user confirmed.
    typealias Confirmer = @MainActor (String, String, String) -> Bool

    static let alert: Confirmer = { title, message, button in
        Confirm.ask(title, message: message, button: button, destructive: false).confirmed
    }

    static func stop(_ store: AppStore, confirm: Confirmer = alert) {
        if shouldProceed(store, title: String(localized: "Stop \(store.selectedProfileName)?"), button: String(localized: "Stop"), confirm: confirm) {
            store.runtimeModel.stopVM()
        }
    }

    static func restart(_ store: AppStore, confirm: Confirmer = alert) {
        if shouldProceed(store, title: String(localized: "Restart \(store.selectedProfileName)?"), button: String(localized: "Restart"), confirm: confirm) {
            store.runtimeModel.restartVM()
        }
    }

    private static func shouldProceed(_ store: AppStore, title: String, button: String, confirm: Confirmer) -> Bool {
        let running = store.runningCount
        guard running > 0 else { return true }
        return confirm(
            title,
            String(localized: "Running containers (\(running)) will be stopped. Containers with a restart policy start again when the VM is back up."),
            button
        )
    }
}
