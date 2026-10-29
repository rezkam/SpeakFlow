import Foundation

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String

    public init(id: UInt32, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }

    public static func resolve(preferredUID: String?, devices: [Self], defaultID: UInt32) -> Self? {
        if let preferredUID, let preferred = devices.first(where: { $0.uid == preferredUID }) { return preferred }
        return devices.first { $0.id == defaultID }
    }
}
