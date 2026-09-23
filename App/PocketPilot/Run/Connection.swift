import AgentCore
import DeviceLink
import Observation

/// One link to this iPhone, shared by every run so the screen-sharing picker appears once per launch.
@Observable
final class Connection {
    enum State: Equatable {
        case disconnected
        case connecting
        /// Connected; `seesScreen` is false when the user declined screen sharing and screenshots come from CoreDevice.
        case connected(seesScreen: Bool)
        case failed(DeviceError)
    }

    private(set) var state = State.disconnected
    private var phone: Phone?
    /// The connection in flight; callers arriving during it await the same result instead of reconnecting.
    private var connecting: Task<Phone, any Error>?

    /// The connected phone, connecting first if needed.
    func phone(pairing: PairingFile) async throws(DeviceError) -> Phone {
        if let phone { return phone }
        let connecting = connecting ?? Task { try await connect(pairing) }
        self.connecting = connecting
        defer { self.connecting = nil }
        do {
            return try await connecting.value
        } catch {
            throw error as? DeviceError ?? .service(String(describing: error))
        }
    }

    /// Drops the link so the next run reconnects, for example after LocalDevVPN restarts.
    func reset() {
        phone = nil
        state = .disconnected
    }

    private func connect(_ pairing: PairingFile) async throws(DeviceError) -> Phone {
        state = .connecting
        let display = try? await DisplayCapture.start()
        do {
            let phone = try await Phone.connect(pairing: pairing, display: display)
            self.phone = phone
            state = .connected(seesScreen: display != nil)
            return phone
        } catch {
            await display?.stop()
            state = .failed(error)
            throw error
        }
    }
}
