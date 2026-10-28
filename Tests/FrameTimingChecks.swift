import Foundation

@main
struct FrameTimingChecks {
    static func main() {
        var timing = FrameTiming()
        precondition(timing.fps == nil && timing.p95Gap == 0)
        timing.add(pts: 10, arrival: 20)
        precondition(timing.fps == nil)
        for i in 1...300 { timing.add(pts: 10 + Double(i) / 30, arrival: 20 + Double(i) / 30) }
        precondition(timing.count == 301)
        precondition(abs(timing.fps! - 30) < 0.0001)
        precondition(abs(timing.arrivalFPS! - 30) < 0.0001)
        precondition(abs(timing.p95Gap - 1.0 / 30) < 0.0001)
        timing.add(pts: 20.1, arrival: 30.1)
        precondition(abs(timing.maxGap - 0.1) < 0.0001)
        timing.add(pts: 20.1, arrival: 30.2)
        timing.add(pts: 19, arrival: 31)
        timing.add(pts: .nan, arrival: 32)
        timing.add(pts: 21, arrival: .infinity)
        precondition(timing.invalidCount == 4 && timing.count == 302)
        print("PASS: frame timing, endpoints, gap percentile, invalid and nonmonotonic timestamps")
    }
}
