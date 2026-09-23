extension Pilot {
    /// A pilot that asks `backup` whenever this one fails, for example when the
    /// on-device model is unavailable or the screen overflows its context.
    ///
    /// ```swift
    /// let pilot = SystemPilot().fallback(to: OpenAIPilot(apiKey: key))
    /// ```
    public func fallback(to backup: some Pilot) -> some Pilot {
        FallbackPilot(primary: self, backup: backup)
    }
}

struct FallbackPilot<Primary: Pilot, Backup: Pilot>: Pilot {
    let primary: Primary
    let backup: Backup

    func decide(_ step: Step) async throws -> Decision {
        do {
            return try await primary.decide(step)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await backup.decide(step)
        }
    }
}
