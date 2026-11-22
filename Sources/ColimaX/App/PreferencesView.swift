import SwiftUI

struct PreferencesView: View {
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var colimaVersion = "…"

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Picker("Mode", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show icon in the Dock", isOn: $settings.showDockIcon)
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                if settings.needsRestartForLanguage {
                    HStack {
                        Text("Restart ColimaX to apply the new language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if AppSettings.canRelaunch {
                            Button("Restart Now") { AppSettings.relaunch() }
                        }
                    }
                }
            }

            Section("Startup") {
                Toggle("Open ColimaX at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        settings.launchAtLogin = value
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Start the VM automatically when the app opens", isOn: $settings.autoStartVM)
            }

            Section("Notifications") {
                Toggle("When the VM finishes starting / stopping", isOn: $settings.notifyVMChanges)
                Toggle("When a container stops unexpectedly (exit ≠ 0)", isOn: $settings.notifyContainerExit)
                Toggle("When a scheduled backup fails", isOn: $settings.notifyBackupFailure)
                if !Notifier.isSupported {
                    Text("Notifications only work when running the packaged .app (scripts/build-app.sh).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Monitoring & Alerts") {
                Toggle("Background monitoring (sample every minute, keep 3 days)", isOn: $settings.backgroundMonitoring)
                Toggle("Notify when a threshold is exceeded", isOn: $settings.notifyResourceAlerts)
                    .disabled(!settings.backgroundMonitoring)
                PlusMinusStepper(value: $settings.alertThresholds.cpuPercent, range: 10...100, step: 5) {
                    Text("Container CPU ≥ \(Int(settings.alertThresholds.cpuPercent))% of VM")
                }
                PlusMinusStepper(value: $settings.alertThresholds.memoryPercent, range: 10...100, step: 5) {
                    Text("Container memory ≥ \(Int(settings.alertThresholds.memoryPercent))% of limit")
                }
                PlusMinusStepper(value: $settings.alertThresholds.diskPercent, range: 10...100, step: 5) {
                    Text("VM disk ≥ \(Int(settings.alertThresholds.diskPercent))%")
                }
                PlusMinusStepper(value: $settings.alertThresholds.sustainSamples, in: 1...30) {
                    Text("For at least \(settings.alertThresholds.sustainSamples) min")
                }
            }

            Section("About") {
                LabeledContent("Colima", value: colimaVersion)
                LabeledContent("colima", value: Shell.which("colima") ?? String(localized: "not found"))
                LabeledContent("docker CLI", value: Shell.which("docker") ?? String(localized: "not found (needed for Compose & Terminal)"))
                LabeledContent("COLIMA_HOME", value: ColimaService.colimaHome.path)
            }
        }
        .formStyle(.grouped)
        .task {
            if let result = try? await Shell.run("colima", ["version"]) {
                colimaVersion = result.stdout.lines.first?.replacingOccurrences(of: "colima version ", with: "") ?? "—"
            }
        }
    }
}
