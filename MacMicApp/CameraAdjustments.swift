import Observation

// Owns adjustment intent and confirmation for one active capture session.
// Invalidation rejects replies from a previous camera, mode, or recovery attempt.
@MainActor
@Observable
final class CameraAdjustments {
    private(set) var controls: [CameraControlID: CameraControl] = [:]
    private(set) var busyControls: Set<CameraControlID> = []
    private(set) var controlErrors: [CameraControlID: String] = [:]
    private(set) var requestedValues: [CameraControlID: CameraControlValue] = [:]
    @ObservationIgnored private var pendingValues: [CameraControlID: CameraControlValue] = [:]
    private(set) var isResettingAdjustments = false
    private(set) var resetMessage: String?
    @ObservationIgnored private var resetFailures: [String] = []
    @ObservationIgnored private var resetAutomaticValues: [String] = []
    @ObservationIgnored private let engine: any CaptureDriving
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var isActive = false
    private(set) var automaticExposureReading: AutomaticExposureReading?
    @ObservationIgnored private var exposureReadRevision = 0
    @ObservationIgnored private var exposureReadInFlight = false

    init(engine: any CaptureDriving) {
        self.engine = engine
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        for id in CameraControlID.allCases { loadControl(id) }
    }

    func invalidate() {
        revision += 1
        isActive = false
        clearAutomaticExposureReading()
        isResettingAdjustments = false
        resetMessage = nil
        resetFailures.removeAll()
        resetAutomaticValues.removeAll()
        controls.removeAll()
        busyControls.removeAll()
        controlErrors.removeAll()
        requestedValues.removeAll()
        pendingValues.removeAll()
    }

    var canObserveAutomaticExposure: Bool {
        guard isActive, !isResettingAdjustments,
              let mode = controls[.autoExposure], mode.confirmed,
              mode.automaticState(for: requestedValues[.autoExposure]) == true,
              let exposure = controls[.exposure], exposure.confirmed,
              case .numeric = exposure.kind else { return false }
        return true
    }

    // Owned by the visible value view's task, not by the capture session.
    // Cancellation on collapse/background/manual mode stops polling immediately.
    func observeAutomaticExposure(interval: Duration = .seconds(1)) async {
        clearAutomaticExposureReading()
        let readRevision = exposureReadRevision
        defer {
            if exposureReadRevision == readRevision { clearAutomaticExposureReading() }
        }
        while !Task.isCancelled, canObserveAutomaticExposure, exposureReadRevision == readRevision {
            if busyControls.isEmpty {
                if !exposureReadInFlight {
                    exposureReadInFlight = true
                    engine.readAutomaticExposure { [weak self] reading in
                        Task { @MainActor in
                            guard let self, self.exposureReadRevision == readRevision else { return }
                            self.exposureReadInFlight = false
                            guard self.canObserveAutomaticExposure, self.busyControls.isEmpty,
                                  let reading, reading.value.isFinite, reading.value > 0,
                                  let control = self.controls[.exposure], reading.unit == control.unit,
                                  case .numeric(let range) = control.kind, reading.value <= range.maximum else {
                                self.automaticExposureReading = nil
                                return
                            }
                            // Yizhan may report slightly below writable MIN.
                            self.automaticExposureReading = reading
                        }
                    }
                } else {
                    automaticExposureReading = nil // Do not present a stalled read as current.
                }
            } else {
                automaticExposureReading = nil
            }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    private func clearAutomaticExposureReading() {
        exposureReadRevision += 1
        exposureReadInFlight = false
        automaticExposureReading = nil
    }

    func loadControl(_ id: CameraControlID) {
        guard !isResettingAdjustments, isActive, !busyControls.contains(id) else { return }
        executeControl(id, value: nil)
    }

    func setControl(_ id: CameraControlID, value: CameraControlValue) {
        guard !isResettingAdjustments, isActive, let control = controls[id] else { return }
        do { try control.validate(value, controls: controls) }
        catch {
            controlErrors[id] = error.localizedDescription
            if !busyControls.contains(id) { requestedValues[id] = nil; pendingValues[id] = nil }
            return
        }
        if !busyControls.contains(id), control.value == value,
           value != control.initial || control.isAtInitialValue {
            requestedValues[id] = nil
            controlErrors[id] = nil
            return
        }
        requestedValues[id] = value
        if busyControls.contains(id) {
            pendingValues[id] = value // One latest intent, never an unbounded queue.
        } else {
            executeControl(id, value: value)
        }
    }

    var canResetAdjustments: Bool {
        isActive && !isResettingAdjustments && busyControls.isEmpty
            && controls.values.contains { $0.access == .writable }
    }

    func resetAdjustments() {
        guard canResetAdjustments else { return }
        isResettingAdjustments = true
        resetMessage = nil
        resetFailures.removeAll()
        resetAutomaticValues.removeAll()
        pendingValues.removeAll()
        requestedValues.removeAll()

        // Capture this session's baseline once; later reads must not change the plan.
        let targets = controls.filter {
            if case .unavailable = $0.value.access { return false }
            return true
        }.mapValues(\.initial)
        var first: [CameraControlID] = []
        var last: [CameraControlID] = []
        if let mode = targets[.autoExposure] {
            if mode == .option(.exposure(.manual)) || mode == .option(.exposure(.shutterPriority)) { first.append(.autoExposure) }
            else { last.append(.autoExposure) }
        }
        if let auto = targets[.autoWhiteBalance] {
            if auto == .toggle(false) { first.append(.autoWhiteBalance) }
            else { last.append(.autoWhiteBalance) }
        }
        let values = CameraControlID.allCases.filter { id in
            guard targets[id] != nil, id != .autoExposure, id != .autoWhiteBalance else { return false }
            // A snapshot of an automatically managed value is not a manual baseline.
            if id == .whiteBalance, targets[.autoWhiteBalance] == .toggle(true) {
                resetAutomaticValues.append(id.title); return false
            }
            if id == .exposure, let mode = targets[.autoExposure],
               mode != .option(.exposure(.manual)), mode != .option(.exposure(.shutterPriority)) {
                resetAutomaticValues.append(id.title); return false
            }
            return true
        }
        // Missing initial reads cannot be silently reported as a successful reset.
        for id in CameraControlID.allCases where controls[id] == nil && controlErrors[id] != nil {
            resetFailures.append(id.title)
        }
        runResetStep(first + values + last, index: 0, targets: targets, request: revision)
    }

    private func runResetStep(_ steps: [CameraControlID], index: Int,
                              targets: [CameraControlID: CameraControlValue], request: Int) {
        guard revision == request, isActive, isResettingAdjustments else { return }
        guard index < steps.count else {
            isResettingAdjustments = false
            resetMessage = resetFailures.isEmpty ? "Initial adjustments restored."
                : "Reset incomplete: " + resetFailures.joined(separator: ", ") + "."
            if !resetAutomaticValues.isEmpty {
                resetMessage! += " Automatic values are managed by the camera: " + resetAutomaticValues.joined(separator: ", ") + "."
            }
            // Auto may have changed values; display a fresh snapshot without comparing
            // automatically managed values with the old numeric baseline.
            for id in [CameraControlID.exposure, .gain, .whiteBalance] { loadControl(id) }
            return
        }
        let id = steps[index]
        guard let target = targets[id] else { return }
        let advance = { [weak self] in
            self?.runResetStep(steps, index: index + 1, targets: targets, request: request)
        }
        performResetCommand(id, value: nil, request: request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.resetFailures.append(id.title)
                advance()
            case .success(let current):
                if current.value == target && current.isAtInitialValue { advance(); return }
                guard current.access == .writable, current.kind.accepts(target) else {
                    self.controlErrors[id] = "The initial value cannot be restored in the current camera state."
                    self.resetFailures.append(id.title)
                    advance(); return
                }
                self.performResetCommand(id, value: target, request: request) { [weak self] result in
                    if case .failure = result { self?.resetFailures.append(id.title) }
                    advance()
                }
            }
        }
    }

    private func performResetCommand(_ id: CameraControlID, value: CameraControlValue?, request: Int,
                                     completion: @escaping @MainActor (Result<CameraControl, CameraControlError>) -> Void) {
        guard revision == request, isActive, isResettingAdjustments else { return }
        busyControls.insert(id)
        controlErrors[id] = nil
        engine.control(id, value: value) { [weak self] result in
            Task { @MainActor in
                guard let self, self.revision == request, self.isActive, self.isResettingAdjustments else { return }
                self.busyControls.remove(id)
                if case .success(let setting) = result {
                    guard setting.id == id else {
                        let error = CameraControlError.invalid("The camera returned a different control.")
                        self.controlFailed(id, message: error.localizedDescription)
                        completion(.failure(error)); return
                    }
                    self.controls[id] = setting
                } else if case .failure(let error) = result {
                    self.controlFailed(id, message: error.localizedDescription)
                }
                completion(result)
            }
        }
    }

    private func executeControl(_ id: CameraControlID, value: CameraControlValue?) {
        busyControls.insert(id)
        controlErrors[id] = nil
        let request = revision
        engine.control(id, value: value) { [weak self] result in
            Task { @MainActor in
                guard let self, self.revision == request, self.isActive else { return }
                self.busyControls.remove(id)
                switch result {
                case .success(let setting):
                    guard setting.id == id else {
                        self.controlFailed(id, message: "The camera returned a different control.")
                        return
                    }
                    self.controls[id] = setting
                    if let next = self.pendingValues.removeValue(forKey: id), next != setting.value {
                        self.setControl(id, value: next)
                    } else {
                        self.requestedValues[id] = nil
                        if id == .autoExposure, value != nil || self.controls[.exposure]?.confirmed == false {
                            self.loadControl(.exposure)
                            self.loadControl(.gain)
                        }
                        if id == .autoWhiteBalance, value != nil || self.controls[.whiteBalance]?.confirmed == false {
                            self.loadControl(.whiteBalance)
                        }
                    }
                case .failure(let error): self.controlFailed(id, message: error.localizedDescription)
                }
            }
        }
    }

    private func controlFailed(_ id: CameraControlID, message: String) {
        controls[id]?.confirmed = false
        requestedValues[id] = nil
        pendingValues[id] = nil
        controlErrors[id] = message
        let dependent: CameraControlID? = id == .autoExposure ? .exposure : (id == .autoWhiteBalance ? .whiteBalance : nil)
        if let dependent {
            controls[dependent]?.confirmed = false
            pendingValues[dependent] = nil
            requestedValues[dependent] = nil
        }
    }

}
