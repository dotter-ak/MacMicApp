import AVFoundation

// One native video-data output shared by the live counter and optional Debug
// diagnostics and PNG snapshots. Keeps only the latest completed pixel buffer.
final class FrameRateMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()
    let sampleQueue = DispatchQueue(label: "local.MacMicApp.frames", qos: .userInitiated)
    private var meter = DeliveryFPS(startedAt: 0)
    private var timer: DispatchSourceTimer?
    private var enabled = false
    private var generation = 0
    private var latest: FrameSnapshot?
    private var latestAt = 0.0
    private var freshness = FrameFreshness(expectedFPS: 30)
    private var frameAvailable = false
    private var reportAvailability: (@Sendable (Bool) -> Void)?
    #if DEBUG
    private var probe: HardwareProbe?
    func setProbe(_ probe: HardwareProbe?) { sampleQueue.sync { self.probe = probe } }
    #endif

    override init() {
        super.init()
        output.videoSettings = [:]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func start(generation: Int, expectedFPS: Double, reportAvailability: @escaping @Sendable (Bool) -> Void, report: @escaping @Sendable (Double) -> Void) {
        sampleQueue.sync {
            timer?.cancel()
            self.generation = generation
            freshness = FrameFreshness(expectedFPS: expectedFPS)
            latestAt = 0
            self.reportAvailability = reportAvailability
            latest = nil
            frameAvailable = false
            reportAvailability(false)
            meter = DeliveryFPS(startedAt: ProcessInfo.processInfo.systemUptime)
            enabled = true
            let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, self.enabled,
                      let fps = self.meter.sample(at: ProcessInfo.processInfo.systemUptime) else { return }
                if !self.freshness.contains(arrival: self.latestAt, now: ProcessInfo.processInfo.systemUptime) {
                    self.latest = nil
                    self.setFrameAvailable(false)
                }
                report(fps)
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        sampleQueue.sync {
            enabled = false
            latest = nil
            setFrameAvailable(false)
            reportAvailability = nil
            timer?.cancel()
            timer = nil
        }
    }

    func snapshot(generation: Int) throws -> FrameSnapshot {
        try sampleQueue.sync {
            guard enabled, self.generation == generation,
                  freshness.contains(arrival: latestAt, now: ProcessInfo.processInfo.systemUptime), let latest else {
                throw FrameSaveError.noFrame
            }
            return latest
        }
    }

    private func setFrameAvailable(_ available: Bool) {
        guard frameAvailable != available else { return }
        frameAvailable = available
        reportAvailability?(available)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        meter.receive(at: now)
        if CMSampleBufferDataIsReady(sampleBuffer), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            latest = FrameSnapshot(pixelBuffer: buffer)
            latestAt = now
            setFrameAvailable(true)
        }
        #if DEBUG
        probe?.captureOutput(output, didOutput: sampleBuffer, from: connection)
        #endif
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        #if DEBUG
        if enabled { probe?.captureOutput(output, didDrop: sampleBuffer, from: connection) }
        #endif
    }
}
