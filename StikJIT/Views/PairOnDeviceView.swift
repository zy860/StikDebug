import SwiftUI

struct PairOnDeviceView: View {
    @StateObject private var service = PairOnDeviceService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text("On iOS 27, open Settings > Privacy & Security > Developer Mode > Pair on this iPhone on the target device, then enter the PIN shown here.".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status".localized) {
                HStack {
                    Label(statusTitle, systemImage: statusIcon)
                    Spacer()
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                }

                if let pin = service.pin {
                    VStack(spacing: 8) {
                        Text("Pairing PIN".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(pin)
                            .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                            .tracking(5)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if let port = service.debugPort {
                    LabeledContent("Host Port".localized, value: String(port))
                        .font(.caption)
                }

                if case .failed(let message) = service.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if case .succeeded = service.phase {
                    Label("Pairing file saved. You can now use the existing device features.".localized, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Button {
                    if service.isBusy {
                        service.stop()
                    } else {
                        service.start()
                    }
                } label: {
                    Label(
                        service.isBusy ? "Stop Pairing".localized : "Start Pairing".localized,
                        systemImage: service.isBusy ? "stop.circle" : "play.circle"
                    )
                }
                .disabled(service.phase == .succeeded)
            }

            Section {
                Text("This only creates the pairing file. It does not connect or disconnect the embedded VPN.".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("On-Device Pairing".localized)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            service.stop()
        }
    }

    private var statusTitle: String {
        switch service.phase {
        case .idle:
            return service.isBusy ? "Stopping previous pairing".localized : "Ready".localized
        case .advertising:
            return "Waiting for target device".localized
        case .deviceConnected:
            return "Device connected".localized
        case .awaitingPIN:
            return "Enter the PIN on the target device".localized
        case .succeeded:
            return "Pairing file ready".localized
        case .failed:
            return "Pairing failed".localized
        }
    }

    private var statusIcon: String {
        switch service.phase {
        case .succeeded:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .deviceConnected, .awaitingPIN:
            return "iphone.gen3"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }

    private var statusColor: Color {
        switch service.phase {
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .deviceConnected, .awaitingPIN:
            return .blue
        default:
            return .orange
        }
    }
}
