#if DEBUG
// Timestamp-only measurements; never retains a camera frame.
struct FrameTiming {
    private(set) var count = 0
    private(set) var invalidCount = 0
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var firstArrival: Double?
    private var lastArrival: Double?
    private var gaps: [Double] = []

    mutating func add(pts: Double, arrival: Double) {
        guard pts.isFinite, arrival.isFinite, lastPTS.map({ pts > $0 }) ?? true,
              lastArrival.map({ arrival > $0 }) ?? true else { invalidCount += 1; return }
        if let lastPTS { gaps.append(pts - lastPTS) }
        if firstPTS == nil { firstPTS = pts; firstArrival = arrival }
        lastPTS = pts
        lastArrival = arrival
        count += 1
    }

    var fps: Double? { rate(firstPTS, lastPTS) }
    var arrivalFPS: Double? { rate(firstArrival, lastArrival) }
    var maxGap: Double { gaps.max() ?? 0 }
    var p95Gap: Double {
        guard !gaps.isEmpty else { return 0 }
        return gaps.sorted()[max(0, Int((Double(gaps.count) * 0.95).rounded(.up)) - 1)]
    }
    private func rate(_ first: Double?, _ last: Double?) -> Double? {
        guard count >= 2, let first, let last, last > first else { return nil }
        return Double(count - 1) / (last - first)
    }
}
#endif
