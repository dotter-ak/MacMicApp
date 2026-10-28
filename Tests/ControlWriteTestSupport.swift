// Backend tests drive the same bounded confirmation steps as the queue,
// without waiting for real time. Scheduling is covered by CameraControlQueueChecks.
extension CameraControlBackend {
    func write(_ id: CameraControlID, value: CameraControlValue,
               shouldContinue: @escaping () -> Bool = { true }) throws -> CameraControl {
        switch try beginWrite(id, value: value, shouldContinue: shouldContinue) {
        case .complete(let control): return control
        case .pending(let confirmation):
            for _ in 0..<8 {
                if let control = try confirmation.poll() { return control }
            }
            preconditionFailure("Confirmation must finish or throw within eight reads")
        }
    }
}
