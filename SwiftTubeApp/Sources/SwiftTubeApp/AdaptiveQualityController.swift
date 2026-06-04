import Foundation

struct AdaptiveRendition: Hashable, Identifiable, Sendable {
    let id: Int64
    let width: Int?
    let height: Int?
    let fps: Double?
    let bitrate: Int?
    let codec: String?
    let selected: Bool

    var title: String {
        if let height, height > 0 {
            let base = "\(height)p"
            if let fps, fps >= 50 {
                return "\(base)60"
            }
            return base
        }
        if let bitrate, bitrate > 0 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        }
        return "Auto"
    }

    var effectiveBitrate: Int {
        bitrate ?? 0
    }

    var effectiveHeight: Int {
        height ?? 0
    }
}

struct AdaptivePlaybackTelemetry: Hashable, Sendable {
    let renditions: [AdaptiveRendition]
    let selectedRenditionID: Int64?
    let rawInputRateBytesPerSecond: Int64?
    let cacheDuration: Double?
    let cacheEnd: Double?
    let bufferAheadSeconds: Double
    let isPausedForCache: Bool
    let cacheBufferingState: Double?
    let isUnderrun: Bool

    var selectedRendition: AdaptiveRendition? {
        guard let selectedRenditionID else { return nil }
        return renditions.first { $0.id == selectedRenditionID }
    }
}

struct AdaptiveQualityDecision: Equatable, Sendable {
    enum Reason: String, Sendable {
        case startup
        case emergencyDownshift
        case sustainedUpshift
    }

    let rendition: AdaptiveRendition
    let reason: Reason
}

struct AdaptiveQualityPolicy: Sendable {
    private var smoothedThroughputBitsPerSecond: Double?
    private var highBufferStableSince: TimeInterval?
    private var lastSwitchAt: TimeInterval?
    private var suppressUntil: TimeInterval = 0

    private let downshiftCooldownSeconds: TimeInterval = 8
    private let upshiftCooldownSeconds: TimeInterval = 25
    private let highBufferRequiredSeconds: TimeInterval = 20
    private let emergencyBufferThresholdSeconds: Double = 2
    private let upshiftBufferThresholdSeconds: Double = 18

    mutating func reset(now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        smoothedThroughputBitsPerSecond = nil
        highBufferStableSince = nil
        lastSwitchAt = nil
        suppressUntil = now
    }

    mutating func suppressDecisions(for seconds: TimeInterval, now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        suppressUntil = max(suppressUntil, now + max(seconds, 0))
        highBufferStableSince = nil
    }

    mutating func evaluate(
        telemetry: AdaptivePlaybackTelemetry,
        viewportHeight: Int?,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> AdaptiveQualityDecision? {
        updateThroughput(from: telemetry)

        guard now >= suppressUntil,
              let selected = telemetry.selectedRendition,
              telemetry.renditions.count > 1 else {
            return nil
        }

        let candidates = viewportLimitedRenditions(telemetry.renditions, viewportHeight: viewportHeight)
        guard let selectedIndex = candidates.firstIndex(where: { $0.id == selected.id }) else {
            return decision(to: candidates.last, reason: .startup, now: now)
        }

        let isStalling = telemetry.isPausedForCache
            || telemetry.isUnderrun
            || telemetry.bufferAheadSeconds <= emergencyBufferThresholdSeconds

        if isStalling {
            highBufferStableSince = nil
            guard canSwitch(now: now, cooldown: downshiftCooldownSeconds) else { return nil }
            let lowerCandidates = Array(candidates.prefix(selectedIndex))
            let target = sustainableRendition(in: lowerCandidates) ?? lowerCandidates.last
            return decision(to: target, reason: .emergencyDownshift, now: now)
        }

        guard telemetry.bufferAheadSeconds >= upshiftBufferThresholdSeconds else {
            highBufferStableSince = nil
            return nil
        }

        if highBufferStableSince == nil {
            highBufferStableSince = now
            return nil
        }

        guard now - (highBufferStableSince ?? now) >= highBufferRequiredSeconds,
              canSwitch(now: now, cooldown: upshiftCooldownSeconds),
              selectedIndex + 1 < candidates.count else {
            return nil
        }

        let next = candidates[selectedIndex + 1]
        guard canSustainUpshift(to: next) else { return nil }
        return decision(to: next, reason: .sustainedUpshift, now: now)
    }

    private mutating func updateThroughput(from telemetry: AdaptivePlaybackTelemetry) {
        guard let bytesPerSecond = telemetry.rawInputRateBytesPerSecond,
              bytesPerSecond > 0 else {
            return
        }

        let bitsPerSecond = Double(bytesPerSecond) * 8
        if let previous = smoothedThroughputBitsPerSecond {
            smoothedThroughputBitsPerSecond = (previous * 0.65) + (bitsPerSecond * 0.35)
        } else {
            smoothedThroughputBitsPerSecond = bitsPerSecond
        }
    }

    private func viewportLimitedRenditions(
        _ renditions: [AdaptiveRendition],
        viewportHeight: Int?
    ) -> [AdaptiveRendition] {
        let sorted = renditions
            .filter { $0.effectiveBitrate > 0 || $0.effectiveHeight > 0 }
            .sorted {
                ($0.effectiveHeight, $0.effectiveBitrate, $0.id) < ($1.effectiveHeight, $1.effectiveBitrate, $1.id)
            }
        guard let viewportHeight, viewportHeight > 0 else { return sorted }

        let cappedHeight = Int(Double(viewportHeight) * 1.15)
        let atOrBelow = sorted.filter { $0.effectiveHeight <= cappedHeight || $0.effectiveHeight == 0 }
        if atOrBelow.isEmpty,
           let firstAbove = sorted.first(where: { $0.effectiveHeight > cappedHeight }) {
            return [firstAbove]
        }
        return atOrBelow.isEmpty ? sorted : atOrBelow.uniquedByID()
    }

    private func sustainableRendition(in candidates: [AdaptiveRendition]) -> AdaptiveRendition? {
        guard candidates.isEmpty == false else { return nil }
        guard let throughput = smoothedThroughputBitsPerSecond, throughput > 0 else {
            return candidates.last
        }
        return candidates.last { candidate in
            Double(candidate.effectiveBitrate) <= throughput * 0.65
        } ?? candidates.first
    }

    private func canSustainUpshift(to rendition: AdaptiveRendition) -> Bool {
        guard let throughput = smoothedThroughputBitsPerSecond, throughput > 0 else {
            return false
        }
        return Double(rendition.effectiveBitrate) > 0
            && throughput >= Double(rendition.effectiveBitrate) * 1.35
    }

    private func canSwitch(now: TimeInterval, cooldown: TimeInterval) -> Bool {
        guard let lastSwitchAt else { return true }
        return now - lastSwitchAt >= cooldown
    }

    private mutating func decision(
        to rendition: AdaptiveRendition?,
        reason: AdaptiveQualityDecision.Reason,
        now: TimeInterval
    ) -> AdaptiveQualityDecision? {
        guard let rendition else { return nil }
        lastSwitchAt = now
        highBufferStableSince = nil
        return AdaptiveQualityDecision(rendition: rendition, reason: reason)
    }
}

private extension Array where Element == AdaptiveRendition {
    func uniquedByID() -> [AdaptiveRendition] {
        var seen = Set<Int64>()
        return filter { seen.insert($0.id).inserted }
    }
}
