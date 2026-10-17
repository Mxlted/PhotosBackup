import SwiftUI

struct UnattendedBackupSettingsView: View {
    @Binding var settings: BackupAdmissionSettings

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    FeatureIcon(symbol: "leaf", size: 46)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A little care for your iPhone")
                            .font(.headline)
                        Text("Let new backups wait when your battery, temperature or storage needs a break.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                Toggle("Only while charging", isOn: $settings.onlyWhileCharging)
                Picker("Minimum battery", selection: $settings.minimumBatteryPercent) {
                    Text("No minimum").tag(0)
                    ForEach([10, 20, 30, 40, 50, 60, 70, 80, 90], id: \.self) { percent in
                        Text("\(percent)%").tag(percent)
                    }
                }
            } header: {
                Text("Power")
            } footer: {
                Text("The battery minimum applies while unplugged. Connect a charger to continue sooner.")
            }

            Section {
                Toggle("Slow down when warm", isOn: $settings.reduceWhenHot)
            } header: {
                Text("Temperature")
            } footer: {
                Text("Uses one upload at a time while warm, and waits to prepare more photos if the iPhone gets too hot.")
            }

            Section {
                Toggle("Keep free space available", isOn: $settings.protectFreeStorage)
                NavigationLink("View storage & clean up") { StorageUsageView() }
            } header: {
                Text("Storage")
            } footer: {
                Text("Checks available space before preparing photos and videos for upload.")
            }

            Section {
                DisclosureGroup("When backups continue") {
                    Text("These optional controls apply while the app is open, during Shortcuts, and in the background. They never undo your own Pause or Stop. An upload already in progress can finish.")
                    Text("After a low-battery pause, new work waits until the battery is five percentage points above your minimum, or a charger is connected. If battery information is unavailable, work waits when a battery rule needs it.")
                    Text("After serious heat, new preparation resumes following one minute of cooling. iOS still decides when background work is available.")
                }
                DisclosureGroup("How free space is protected") {
                    Text("Keeps 1 GiB of free space and reserves room for photos being prepared together. When a photo or video’s size is unknown, 2 GiB is reserved for it. Large files can need more than this estimate.")
                    Text("Temporary copies still needed by background uploads are kept until those uploads finish.")
                }
            }
            .font(.subheadline)
        }
        .backupListBackground()
        .navigationTitle("Battery & device care")
        .navigationBarTitleDisplayMode(.inline)
    }
}
