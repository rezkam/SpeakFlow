/// A capture session snapshots the preference. Manual changes affect the next session.
struct MicrophoneRoute {
    let preferredUID: String?
    private var activeUID: String?
    private var hasResolved = false

    init(preferredUID: String?) { self.preferredUID = preferredUID }

    mutating func resolve(_ snapshot: MicrophoneSnapshot) -> MicrophoneDevice? {
        let requested = preferredUID == nil ? nil : (hasResolved ? activeUID : preferredUID)
        let device = MicrophoneDevice.resolve(
            preferredUID: requested, devices: snapshot.devices, defaultID: snapshot.defaultID
        )
        activeUID = device?.uid
        hasResolved = true
        return device
    }
}
