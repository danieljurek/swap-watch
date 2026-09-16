import AppKit
import SwiftUI

struct NotificationSettingsView: View {
    @ObservedObject var permissions: NotificationPermissions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Notify about swap-write warnings", isOn: Binding(
                get: { permissions.isEnabled },
                set: { enabled in
                    permissions.setEnabled(enabled)
                    if enabled { Task { await permissions.requestIfNeeded() } }
                }
            ))
            Text("Notifications alert you when potential SSD-damaging conditions are detected.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if permissions.isEnabled {
                Text(permissions.statusMessage)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if permissions.access?.authorization == .notDetermined {
                        Button(permissions.requestError == nil ? "Allow Notifications" : "Retry Permission Request") {
                            Task { await permissions.requestIfNeeded() }
                        }
                        .disabled(permissions.isRequesting)
                    }
                    Button("Refresh Permission") { Task { await permissions.refresh() } }
                }
                .controlSize(.small)
            }
        }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
    }
}
