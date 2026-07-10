import SwiftUI

struct ShimmerText: View {
    let text: String
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.4) / 1.4

            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
                .overlay {
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.primary.opacity(0.18),
                                Color.primary.opacity(0.92),
                                Color.primary.opacity(0.18),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.72)
                        .offset(x: -width * 0.68 + width * 1.58 * phase)
                    }
                    .mask(Text(text).font(font))
                }
        }
    }
}

struct SwiftTubeSpinner: View {
    @Environment(\.displayScale) private var displayScale

    var size: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate / 1.18
            HStack(spacing: max(size * 0.13, 3)) {
                ForEach(0..<3, id: \.self) { index in
                    let lift = smoothWave(time - Double(index) * 0.17)
                    Circle()
                        .fill(Color.white)
                        .frame(width: size * 0.20, height: size * 0.20)
                        .offset(y: snappedOffset(-lift * size * 0.34))
                }
            }
            .frame(width: size, height: size)
        }
    }

    private func smoothWave(_ rawPhase: Double) -> Double {
        let phase = rawPhase - floor(rawPhase)
        return (1 - cos(phase * 2 * .pi)) / 2
    }

    private func snappedOffset(_ offset: Double) -> CGFloat {
        let scale = max(displayScale, 1)
        return CGFloat((offset * scale).rounded() / scale)
    }
}

struct LoadingStatusView: View {
    let text: String
    var spinnerSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 9) {
            SwiftTubeSpinner(size: spinnerSize)
            ShimmerText(text: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LoadingMoreIndicator: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            SwiftTubeSpinner(size: 24)
            ShimmerText(text: text, font: .callout.weight(.semibold))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

struct StaggeredFadeIn: ViewModifier {
    let id: String
    let index: Int
    let columns: Int
    var batchSize: Int = 30
    var rowDelay: Double = 0.095
    var columnDelay: Double = 0.012
    var duration: Double = 0.54

    @State private var visibleID: String?
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .task(id: id) {
                guard visibleID != id else {
                    isVisible = true
                    return
                }

                visibleID = id
                isVisible = false

                let localIndex = max(index, 0) % max(batchSize, 1)
                let columnCount = max(columns, 1)
                let row = localIndex / columnCount
                let column = localIndex % columnCount
                let delay = min(Double(row) * rowDelay + Double(column) * columnDelay, 0.82)

                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(.smooth(duration: duration)) {
                        isVisible = true
                    }
                }
            }
    }
}

extension View {
    func staggeredFadeIn(
        id: String,
        index: Int,
        columns: Int = 1,
        batchSize: Int = 30,
        rowDelay: Double = 0.095,
        columnDelay: Double = 0.012,
        duration: Double = 0.54
    ) -> some View {
        modifier(StaggeredFadeIn(
            id: id,
            index: index,
            columns: columns,
            batchSize: batchSize,
            rowDelay: rowDelay,
            columnDelay: columnDelay,
            duration: duration
        ))
    }
}
