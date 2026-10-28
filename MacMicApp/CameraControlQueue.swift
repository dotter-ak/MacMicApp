import Foundation

// Confined to the supplied capture queue. USB calls remain synchronous and
// serialized; only the device's settling time is scheduled instead of slept.
final class CameraControlQueue: @unchecked Sendable {
    private struct Command {
        let token = UUID()
        let isCurrent: () -> Bool
        let begin: () throws -> CameraControlWrite
        let report: (Result<CameraControl, CameraControlError>) -> Void
    }
    private struct Active {
        let command: Command
        let confirmation: CameraControlConfirmation
    }

    private let queue: DispatchQueue
    private var pending: [Command] = []
    private var active: Active?
    private var isDraining = false

    init(queue: DispatchQueue) { self.queue = queue }

    var isIdle: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return active == nil && pending.isEmpty && !isDraining
    }

    func enqueue(isCurrent: @escaping () -> Bool,
                 begin: @escaping () throws -> CameraControlWrite,
                 report: @escaping (Result<CameraControl, CameraControlError>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.append(Command(isCurrent: isCurrent, begin: begin, report: report))
        drain()
    }

    func cancelAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        active = nil
        pending.removeAll()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while active == nil, !pending.isEmpty {
            let command = pending.removeFirst()
            guard command.isCurrent() else { continue }
            do {
                switch try command.begin() {
                case .complete(let control):
                    if command.isCurrent() { command.report(.success(control)) }
                case .pending(let confirmation):
                    guard command.isCurrent() else { continue }
                    active = Active(command: command, confirmation: confirmation)
                    schedule(command.token)
                }
            } catch {
                if command.isCurrent() { command.report(.failure(.invalid(error.localizedDescription))) }
            }
        }
    }

    private func schedule(_ token: UUID) {
        queue.asyncAfter(deadline: .now() + CameraControlConfirmation.interval) { [self] in
            // A timer from an old session must not touch a newer command.
            guard let current = active, current.command.token == token else { return }
            guard current.command.isCurrent() else {
                active = nil
                drain()
                return
            }
            do {
                if let control = try current.confirmation.poll() {
                    active = nil
                    if current.command.isCurrent() { current.command.report(.success(control)) }
                    drain()
                } else {
                    schedule(token)
                }
            } catch {
                active = nil
                if current.command.isCurrent() {
                    current.command.report(.failure(.invalid(error.localizedDescription)))
                }
                drain()
            }
        }
    }
}
