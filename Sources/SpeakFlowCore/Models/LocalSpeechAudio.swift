import Foundation

public enum LocalSpeechAudioError: Error, LocalizedError {
    case invalidAudio
    public var errorDescription: String? { "Local speech requires mono 16 kHz PCM16 audio from the recording pipeline." }
}

/// Decodes the recording pipeline's canonical WAV and raw streaming PCM.
/// File transcription and format guessing are outside this interface.
public enum LocalSpeechAudio {
    public static func batchSamples(_ data: Data) throws -> [Float] {
        guard data.count > 44, data.count <= Config.maxAudioSizeBytes, (data.count - 44).isMultiple(of: 2) else {
            throw LocalSpeechAudioError.invalidAudio
        }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func u16(_ offset: Int) -> UInt16 { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
            guard u32(0) == 0x46464952, u32(4) == data.count - 8, u32(8) == 0x45564157,
                  u32(12) == 0x20746D66, u32(16) == 16, u16(20) == 1, u16(22) == 1,
                  u32(24) == 16000, u32(28) == 32000, u16(32) == 2, u16(34) == 16,
                  u32(36) == 0x61746164, u32(40) == data.count - 44 else { throw LocalSpeechAudioError.invalidAudio }
            return samples(raw, offset: 44)
        }
    }

    public static func streamingSamples(_ data: Data) throws -> [Float] {
        // Match the existing live audio queue's packet bound before expanding samples.
        guard data.count <= 1_000_000, data.count.isMultiple(of: 2) else { throw LocalSpeechAudioError.invalidAudio }
        return data.withUnsafeBytes { samples($0, offset: 0) }
    }

    private static func samples(_ raw: UnsafeRawBufferPointer, offset: Int) -> [Float] {
        stride(from: offset, to: raw.count, by: 2).map {
            Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32768
        }
    }
}
