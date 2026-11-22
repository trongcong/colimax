import Foundation
import Observation

/// Image actions and the lazily fetched image platforms (G11).
@MainActor
@Observable
final class ImagesModel {
    /// Image platform by image ID (fetched via inspect; cached until the Docker data is cleared).
    private(set) var platforms: [String: ImagePlatform] = [:]

    @ObservationIgnored unowned let context: any DockerContext

    init(context: any DockerContext) {
        self.context = context
    }

    private var operations: OperationCenter { context.operations }

    func reset() { platforms = [:] }

    /// Pulls an image as a long operation, keeping one log line per layer.
    func pull(_ reference: String) {
        let client = context.docker
        let operations = operations
        operations.launch {
            operations.begin(String(localized: "Pull \(reference)"))
            var layers: [String: String] = [:]
            do {
                for try await progress in client.pull(reference) {
                    if let error = progress.error { throw DockerError.socket(error) }
                    let line = [progress.id, progress.status, progress.progress].compactMap { $0 }.joined(separator: " ")
                    if let id = progress.id {
                        // Keep one line per layer so the log doesn't grow unbounded.
                        layers[id] = line
                        operations.operation?.lines = layers.keys.sorted().compactMap { layers[$0] }
                    } else {
                        operations.operation?.lines.append(line)
                    }
                }
                operations.finish(with: nil)
            } catch {
                operations.finish(with: error)
            }
        }
    }

    @discardableResult
    func remove(_ image: DockerImage, force: Bool) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform(image.id) { try await client.removeImage(image.id, force: force) }
    }

    func prune(all: Bool) {
        let client = context.docker
        operations.perform("prune:images") { [operations] in
            let report = try await client.pruneImages(all: all)
            operations.errorMessage = nil
            operations.flash(String(localized: "Freed \(Format.bytes(report.spaceReclaimed ?? 0)) from images"))
        }
    }

    /// Inspects the platform of images not yet cached (at most 6 concurrent requests).
    func loadPlatforms() async {
        guard context.isRunning, context.supportsDocker else { return }
        let client = context.docker
        let missing = context.images.map(\.id).filter { platforms[$0] == nil }
        guard !missing.isEmpty else { return }
        let results = await withTaskGroup(of: ImagePlatform?.self) { group -> [ImagePlatform] in
            var collected: [ImagePlatform] = []
            var iterator = missing.makeIterator()
            for _ in 0..<min(6, missing.count) {
                if let id = iterator.next() { group.addTask { try? await client.imagePlatform(id) } }
            }
            while let result = await group.next() {
                if let result { collected.append(result) }
                if let id = iterator.next() { group.addTask { try? await client.imagePlatform(id) } }
            }
            return collected
        }
        for platform in results { platforms[platform.id] = platform }
    }
}
