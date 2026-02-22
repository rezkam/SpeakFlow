import Accelerate
import Foundation

/// Utility for encoding mono Float32 PCM samples as 16-bit PCM WAV.
public enum WavEncoder {
    public static func encode(samples: [Float], sampleRate: Double) -> Data {
        guard !samples.isEmpty else { return Data() }

        let sampleCount = samples.count
        let n = vDSP_Length(sampleCount)
        let dataBytes = sampleCount * MemoryLayout<Int16>.stride
        let totalBytes = 44 + dataBytes

        var scratch = [Float](unsafeUninitializedCapacity: sampleCount) { buf, count in
            samples.withUnsafeBufferPointer { src in
                buf.baseAddress!.initialize(from: src.baseAddress!, count: sampleCount)
            }
            count = sampleCount
        }

        var low: Float = -1.0
        var high: Float = 1.0
        vDSP_vclip(scratch, 1, &low, &high, &scratch, 1, n)

        var scale: Float = 32767.0
        vDSP_vsmul(scratch, 1, &scale, &scratch, 1, n)

        var wav = Data(count: totalBytes)
        wav.withUnsafeMutableBytes { raw in
            let b = raw.baseAddress!

            b.storeBytes(of: 0x46464952 as UInt32, as: UInt32.self)                      // "RIFF"
            (b + 4).storeBytes(of: UInt32(36 + dataBytes).littleEndian, as: UInt32.self) // size
            (b + 8).storeBytes(of: 0x45564157 as UInt32, as: UInt32.self)                 // "WAVE"

            (b + 12).storeBytes(of: 0x20746D66 as UInt32, as: UInt32.self) // "fmt "
            (b + 16).storeBytes(of: UInt32(16).littleEndian, as: UInt32.self)
            (b + 20).storeBytes(of: UInt16(1).littleEndian, as: UInt16.self) // PCM
            (b + 22).storeBytes(of: UInt16(1).littleEndian, as: UInt16.self) // mono

            let sr = UInt32(sampleRate)
            (b + 24).storeBytes(of: sr.littleEndian, as: UInt32.self)
            (b + 28).storeBytes(of: (sr * 2).littleEndian, as: UInt32.self)
            (b + 32).storeBytes(of: UInt16(2).littleEndian, as: UInt16.self)
            (b + 34).storeBytes(of: UInt16(16).littleEndian, as: UInt16.self)

            (b + 36).storeBytes(of: 0x61746164 as UInt32, as: UInt32.self) // "data"
            (b + 40).storeBytes(of: UInt32(dataBytes).littleEndian, as: UInt32.self)

            let dst = (b + 44).bindMemory(to: Int16.self, capacity: sampleCount)
            vDSP_vfix16(scratch, 1, dst, 1, n)
        }

        return wav
    }
}
