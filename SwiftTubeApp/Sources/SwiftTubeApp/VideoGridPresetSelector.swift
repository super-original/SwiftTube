import SwiftUI

struct VideoGridPresetSelector: View {
    @Binding var selection: BrowseVideoGridPreset

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(BrowseVideoGridPreset.allCases) { preset in
                    VideoGridPresetSegment(
                        title: preset.title,
                        isSelected: selection == preset,
                        action: { selection = preset }
                    )
                }
            }
            .padding(5)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video grid size")
    }
}

private struct VideoGridPresetSegment: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Capsule())
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.primary.opacity(0.07))
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
