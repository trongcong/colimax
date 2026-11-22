import SwiftUI

/// Streams (follows) container logs through the Docker API. The UI is updated in ~200 ms batches
/// rather than re-rendering for every new line.
struct LogsPane: View {
    let container: DockerContainer
    let client: any DockerEngine

    @State private var text = ""
    @State private var filter = ""
    @State private var tail = 500
    @State private var follow = true
    @State private var timestamps = false
    @State private var error: String?
    @State private var streaming = false

    private static let maxCharacters = 2_000_000

    private var displayed: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filter lines", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Picker("Tail", selection: $tail) {
                    ForEach([100, 500, 2000, 10000], id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Toggle("Follow", isOn: $follow)
                Toggle("Timestamps", isOn: $timestamps)
                Spacer()
                if streaming {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                        .help("Streaming")
                }
                Button { Pasteboard.copy(displayed) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy")
                Button { export() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save the displayed log to a file")
                    .disabled(displayed.isEmpty)
                Button { text = "" } label: { Image(systemName: "trash") }
                    .help("Clear")
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            if let error {
                Text(error).foregroundStyle(.red).padding()
            }
            CodeTextView(text: displayed, autoScroll: follow)
        }
        .task(id: "\(container.id)-\(tail)-\(follow)-\(timestamps)-\(container.state)") {
            await stream()
        }
    }

    private func stream() async {
        text = ""
        error = nil
        do {
            let tty = try await client.isTTY(container.id)
            var demuxer = LogDemuxer(tty: tty)
            var pending = ""
            var lastFlush = Date()
            streaming = follow && container.isRunning
            defer { streaming = false }

            for try await chunk in client.logStream(container.id, tail: tail, follow: follow && container.isRunning, timestamps: timestamps) {
                pending += demuxer.feed(chunk)
                if Date().timeIntervalSince(lastFlush) > 0.2 {
                    append(pending)
                    pending = ""
                    lastFlush = .now
                }
            }
            append(pending)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func export() {
        guard let url = FilePanels.save(name: LogExport.fileName(container: container.name, at: Date())) else { return }
        do {
            try LogExport.write(displayed, to: url)
        } catch {
            self.error = String(localized: "Could not save the log: \(error.localizedDescription)")
        }
    }

    private func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        if text.utf8.count > Self.maxCharacters {
            text = String(text.suffix(Self.maxCharacters / 2))
        }
    }
}

/// Saves container logs to a file (G7). Separate from the view so file permissions can be tested.
enum LogExport {
    static func fileName(container: String, at date: Date) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return "\(container)-\(stamp).log"
    }

    /// Logs may contain secrets: written atomically with mode 0600, even when replacing an existing file with wider permissions.
    static func write(_ text: String, to url: URL) throws {
        try AtomicFile.write(Data(text.utf8), to: url, permissions: 0o600)
    }
}
