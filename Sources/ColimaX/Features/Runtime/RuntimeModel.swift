import Foundation

/// How a runtime configuration change has to be applied, and which confirmation it needs.
enum RuntimeChange: Equatable {
    /// Nothing changed.
    case none
    /// The VM is stopped: the new configuration is used on the next start, no confirmation.
    case apply
    /// The VM is running: it is stopped and started again (asks first).
    case restart
    /// arch / runtime / VM type changed: the VM is deleted and recreated (asks first, data optional).
    case recreate
    /// Smaller disk: Colima cannot shrink in place, so the VM and all data are deleted (typed confirmation).
    case shrinkDisk

    static func plan(from original: RuntimeConfig, to draft: RuntimeConfig, isRunning: Bool) -> RuntimeChange {
        if draft == original { return .none }
        if draft.diskGiB < original.diskGiB { return .shrinkDisk }
        if draft.requiresRecreate(from: original) { return .recreate }
        return isRunning ? .restart : .apply
    }

    /// The VM is deleted and created again.
    var recreatesVM: Bool { self == .recreate || self == .shrinkDisk }
}

/// VM and profile actions: start / stop / restart, apply configuration, create / delete profiles.
/// Every action is a long operation (streamed log, cancellable) and is ignored while another one runs.
@MainActor
final class RuntimeModel {
    unowned let context: any ProfileContext

    init(context: any ProfileContext) {
        self.context = context
    }

    private var operations: OperationCenter { context.operations }
    private var colima: any ColimaControlling { context.colima }

    func startVM() {
        let name = context.selectedProfileName
        vmOperation(String(localized: "Start \(name)"), colima.start(name, config: nil), done: String(localized: "Profile \(name) is running"))
    }

    func stopVM() {
        let name = context.selectedProfileName
        vmOperation(String(localized: "Stop \(name)"), colima.stop(name), done: String(localized: "Profile \(name) stopped"))
    }

    func restartVM() {
        let name = context.selectedProfileName
        vmOperation(String(localized: "Restart \(name)"), colima.restart(name), done: String(localized: "Profile \(name) restarted"))
    }

    private func vmOperation(_ title: String, _ stream: AsyncThrowingStream<String, Error>, done: String) {
        operations.launch { [self] in
            let ok = await operations.runOperation(title, stream)
            await context.refreshProfiles()
            if ok, context.notifyVMChanges { context.notify(title: "Colima", body: done) }
        }
    }

    /// Applies a runtime configuration. With `recreate` (arch/runtime/vmType changed, or a smaller disk)
    /// the VM is deleted and recreated; otherwise a running VM is stopped and started again with the new
    /// configuration.
    func applyRuntimeConfig(_ config: RuntimeConfig, recreate: Bool, deleteData: Bool) {
        let name = context.selectedProfileName
        let wasRunning = context.isRunning
        operations.launch { [self] in
            if recreate {
                guard await operations.runOperation(String(localized: "Delete VM \(name)"), colima.delete(name, deleteData: deleteData)) else {
                    await context.refreshProfiles(); return
                }
            } else if wasRunning {
                guard await operations.runOperation(String(localized: "Stop \(name)"), colima.stop(name)) else {
                    await context.refreshProfiles(); return
                }
            }
            guard !Task.isCancelled else { await context.refreshProfiles(); return }
            let ok = await operations.runOperation(String(localized: "Start \(name) with the new configuration"), colima.start(name, config: config))
            await context.refreshProfiles()
            if ok, context.notifyVMChanges { context.notify(title: "Colima", body: String(localized: "Applied configuration to \(name)")) }
        }
    }

    func createProfile(_ name: String, config: RuntimeConfig) {
        guard ColimaService.isValidProfileName(name) else { return }
        operations.launch { [self] in
            let ok = await operations.runOperation(String(localized: "Create profile \(name)"), colima.start(name, config: config))
            await context.refreshProfiles()
            if ok { context.select(name) }
        }
    }

    func deleteProfile(_ name: String, deleteData: Bool) {
        operations.launch { [self] in
            await operations.runOperation(String(localized: "Delete profile \(name)"), colima.delete(name, deleteData: deleteData))
            await context.refreshProfiles()
        }
    }
}
