import Foundation

@main
struct DeliveryFPSChecks {
    static func main() {
        let normal = FrameFreshness(expectedFPS: 30)
        precondition(normal.contains(arrival: 100, now: 100.999))
        precondition(!normal.contains(arrival: 100, now: 101))
        let slow = FrameFreshness(expectedFPS: 0.5)
        precondition(slow.contains(arrival: 100, now: 102), "Previous frame must survive until the next 0.5 FPS frame")
        precondition(slow.contains(arrival: 100, now: 105.999), "Allow three frame intervals of delivery jitter")
        precondition(!slow.contains(arrival: 100, now: 106), "A stalled slow stream must still expire")
        let verySlow = FrameFreshness(expectedFPS: 0.1)
        precondition(verySlow.contains(arrival: 100, now: 110))
        precondition(!verySlow.contains(arrival: 100, now: 130))
        let oneFPS = FrameFreshness(expectedFPS: 1)
        precondition(oneFPS.contains(arrival: 100, now: 101.1))
        precondition(!normal.contains(arrival: 100, now: 102), "Returning to 30 FPS must restore the short freshness limit")
        for fps in [Double.nan, .infinity, 0, -1, .leastNonzeroMagnitude] {
            let invalid = FrameFreshness(expectedFPS: fps)
            precondition(invalid.maximumAge == 1)
        }
        precondition(!slow.contains(arrival: .nan, now: 100))
        precondition(!slow.contains(arrival: 100, now: .infinity))
        precondition(!slow.contains(arrival: 100, now: 99))
        print("PASS: snapshot freshness at 30/1/0.5/0.1 FPS, stalled frames, mode-rate change and invalid timestamps/rates")
        var meter = DeliveryFPS(startedAt: 0)
        for n in 1...30 { meter.receive(at: Double(n) / 30) }
        precondition(abs(meter.sample(at: 1)! - 30) < 0.0001)
        for n in 1...30 { meter.receive(at: 1 + Double(n) / 30) }
        precondition(abs(meter.sample(at: 2)! - 30) < 0.0001)
        precondition(meter.sample(at: 3.1) == 0) // No stale nonzero rate during a stall.
        for n in 1...10 { meter.receive(at: 3.1 + Double(n) / 10) }
        precondition(abs(meter.sample(at: 4.1)! - 10) < 0.0001)
        meter = DeliveryFPS(startedAt: 10) // Mode changes reset both smoothing intervals.
        meter.receive(at: 9)
        meter.receive(at: .nan)
        for n in 1...10 { meter.receive(at: 10 + Double(n) / 10) }
        precondition(abs(meter.sample(at: 11)! - 10) < 0.0001)
        precondition(meter.sample(at: 11) == nil)
        precondition(meter.sample(at: .infinity) == nil)
        var empty = DeliveryFPS(startedAt: 0)
        precondition(empty.sample(at: 1) == 0)
        var jitter = DeliveryFPS(startedAt: 0)
        for n in 1...30 { jitter.receive(at: Double(n) / 30) }
        precondition(abs(jitter.sample(at: 1.02)! - 30 / 1.02) < 0.0001)
        for n in 1...30 { jitter.receive(at: 1.02 + Double(n) / 30) }
        precondition(abs(jitter.sample(at: 2.04)! - 60 / 2.04) < 0.0001)
        print("PASS: actual 30/10 FPS, elapsed time, smoothing, stalled stream, reset, invalid timestamps and recovery")
    }
}
