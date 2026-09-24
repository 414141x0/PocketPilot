import AgentCore
import DeviceLink
import Foundation
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

    /// Debug builds launched with POCKETPILOT_NO_CAPTURE skip the screen-sharing picker,
    /// so a run can start without anyone at the phone.
    private static var sharesScreen: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["POCKETPILOT_NO_CAPTURE"] == nil
        #else
        true
        #endif
    }

    /// Drops the link so the next run reconnects, for example after LocalDevVPN restarts.
    func reset() {
        connecting?.cancel()
        connecting = nil
        phone = nil
        state = .disconnected
    }

    private func connect(_ pairing: PairingFile) async throws(DeviceError) -> Phone {
        state = .connecting
        let display = Self.sharesScreen ? try? await DisplayCapture.start() : nil
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
