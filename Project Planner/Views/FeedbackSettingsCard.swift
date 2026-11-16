import SwiftUI

/// Settings → My notifications → "Sounds & haptics" (feedback guide §5, owner decision 1, 16 Nov). Two switches kept
/// on this phone only (`UserDefaults` `pp.feedback.sounds` / `pp.feedback.haptics`, default on) — never Firestore, never
/// synced — and "Play a sample". They change at once; they are not part of the screen's Save.
struct FeedbackSettingsCard: View {
    @AppStorage(FeedbackCenter.soundsKey) private var soundsOn = true
    @AppStorage(FeedbackCenter.hapticsKey) private var hapticsOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHubChrome.sectionTitle("Sounds & haptics")
                .padding(.top, 20)
            SettingsHubChrome.card {
                toggleRow("Sounds", isOn: $soundsOn, identifier: "settingsFeedback.sounds")
                SettingsHubChrome.divider()
                toggleRow("Haptics", isOn: $hapticsOn, identifier: "settingsFeedback.haptics")
                SettingsHubChrome.divider()
                Button {
                    FeedbackCenter.shared.playSample()
                } label: {
                    HStack {
                        Text("Play a sample")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PPColor.brand)
                        Spacer()
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(PPColor.brand)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!soundsOn && !hapticsOn)
                .accessibilityIdentifier("settingsFeedback.playSample")
            }
            SettingsHubChrome.footer("Applies to this iPhone only.")
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, identifier: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(PPColor.brand)
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 11)
    }
}
