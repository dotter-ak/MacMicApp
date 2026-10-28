// Bounded, arrival-based frame counter. No image data or timestamp arrays.
// Two reporting intervals smooth scheduling jitter; a stalled stream reads zero.
struct DeliveryFPS {
    private var windowStart: Double
    private var count = 0
    private var lastArrival: Double?
    private var previousCount = 0
    private var previousDuration = 0.0

    init(startedAt: Double) { windowStart = startedAt }

    mutating func receive(at now: Double) {
        guard now.isFinite, now >= windowStart,
              lastArrival.map({ now >= $0 }) ?? true else { return }
        count += 1
        lastArrival = now
    }

    mutating func sample(at now: Double) -> Double? {
        guard now.isFinite, now > windowStart else { return nil }
        let duration = now - windowStart
        let stalled = lastArrival.map { now - $0 >= 1 } ?? true
        let result = stalled ? 0 : Double(count + previousCount) / (duration + previousDuration)
        previousCount = stalled ? 0 : count
        previousDuration = stalled ? 0 : duration
        count = 0
        windowStart = now
        return result
    }
}

// A slow mode may legitimately deliver frames more than one second apart.
// Use the selected rate, never measured FPS (which falls to zero on a stall).
struct FrameFreshness {
    let maximumAge: Double

    init(expectedFPS: Double) {
        let allowance = 3 / expectedFPS
        maximumAge = expectedFPS.isFinite && expectedFPS > 0 && allowance.isFinite
            ? max(1, allowance) : 1
    }

    func contains(arrival: Double, now: Double) -> Bool {
        let age = now - arrival
        return arrival.isFinite && now.isFinite && age >= 0 && age < maximumAge
    }
}
