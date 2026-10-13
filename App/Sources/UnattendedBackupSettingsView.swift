import SwiftUI

struct UnattendedBackupSettingsView: View {
    @Binding var settings: BackupAdmissionSettings

    var body: some View {
        List {
            Section {
                Toggle("Only While Charging", isOn: $settings.onlyWhileCharging)
                Picker("Minimum Battery", selection: $settings.minimumBatteryPercent) {
                    Text("No Minimum").tag(0)
                    ForEach([10, 20, 30, 40, 50, 60, 70, 80, 90], id: \.self) { percent in
                        Text("\(percent)%").tag(percent)
                    }
                }
            } footer: {
                Text("The battery minimum applies while unplugged. After waiting, new work resumes five percentage points above the minimum, or when a charger is connected. Unavailable battery information waits when either rule requires it.")
            }

            Section {
                Toggle("Reduce Work When Warm", isOn: $settings.reduceWhenHot)
            } footer: {
                Text("Runs one upload at a time while warm. New preparation waits in serious heat and resumes after one minute of cooling. Work already started is allowed to finish.")
            }

            Section {
                Toggle("Protect Free Storage", isOn: $settings.protectFreeStorage)
                NavigationLink("Storage and Cleanup") { StorageUsageView() }
            } footer: {
                Text("Keeps 1 GiB of free-space headroom and reserves space for concurrent preparation. Because Photos does not provide a reliable size before export, unknown items reserve 2 GiB each. Large items can exceed this estimate. Upload copies owned by background transfers are retained.")
            }

            Section("How these controls work") {
                Text("All controls are optional and initially off. They apply to foreground, Shortcut, and background queue work. When conditions recover, eligible work continues without clearing your own Pause or Stop.")
                Text("These controls admit new preparation. An upload already moving under iOS can finish. iOS still decides when background execution is available.")
            }
        }
        .navigationTitle("Unattended Backup")
        .navigationBarTitleDisplayMode(.inline)
    }
}
