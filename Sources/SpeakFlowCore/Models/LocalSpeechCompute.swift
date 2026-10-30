import CoreML
import Foundation

public enum LocalSpeechComputeError: Error, LocalizedError {
    case unsupportedOverride

    public var errorDescription: String? {
        "A compute override conflicts with Neural Engine acceleration. Remove it before loading this model."
    }
}

/// Request the supported accelerated path explicitly, including under CI.
/// CoreML can still schedule supporting operations on CPU; this is not proof of device placement.
public enum LocalSpeechCompute {
    public static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MLModelConfiguration {
        let overrides = ["FLUIDAUDIO_ENCODER_CU", "FLUIDAUDIO_DECODER_CU", "FLUIDAUDIO_DECODERJOINT_CU",
                         "FLUIDAUDIO_JOINT_CU", "FLUIDAUDIO_JOINT_BATCHED_CU"]
        for key in overrides {
            if let value = environment[key], value.uppercased() != "CPU_AND_NE" {
                throw LocalSpeechComputeError.unsupportedOverride
            }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }
}
