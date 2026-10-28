#if DEBUG
import AVFoundation

final class BrightnessProbe {
    private var trial: BrightnessTrial?

    func begin(device: AVCaptureDevice, shouldContinue: () -> Bool) {
        do {
            let trial = BrightnessTrial(transport: try UVCControlConnection(device: device))
            self.trial = trial
            try trial.begin(shouldContinue: shouldContinue)
            emit("changed", reason: "temporary-test")
        } catch {
            emit("change-failed", reason: error.localizedDescription)
            restore(reason: "change-failed")
        }
    }

    func restore(reason: String) {
        guard let trial, trial.needsRestore, !trial.restoreAttempted else { return }
        do {
            try trial.restore()
            emit("restored", reason: reason)
        } catch { emit("restore-failed", reason: error.localizedDescription) }
    }

    private func emit(_ status: String, reason: String) {
        var record = ["event": "brightness-trial", "status": status, "reason": reason,
                      "needsRestore": String(trial?.needsRestore ?? false)]
        if let trial {
            record["original"] = trial.original.map(String.init)
            record["target"] = trial.target.map(String.init)
            record["minimum"] = trial.minimum.map(String.init)
            record["maximum"] = trial.maximum.map(String.init)
            record["step"] = trial.step.map(String.init)
        }
        HardwareProbe.emit(record)
    }
}
#endif
