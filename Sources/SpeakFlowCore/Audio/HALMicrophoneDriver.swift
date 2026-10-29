import AVFoundation
import AudioToolbox
import CoreAudio
import os

typealias MicrophoneBufferConsumer = @Sendable (AVAudioPCMBuffer) -> Void

@MainActor
protocol MicrophoneCaptureDriving: AnyObject {
    func start(deviceID: UInt32, makeConsumer: (AVAudioFormat) throws -> MicrophoneBufferConsumer) throws
    var hasDeliveredFrames: Bool { get }
    func configurationChanged() throws -> Bool
    func stop()
}

/// Callback state is confined to the serial input callback; only its error crosses threads.
private final class HALCaptureContext: @unchecked Sendable {
    let unit: AudioUnit
    let buffer: AVAudioPCMBuffer
    let consume: MicrophoneBufferConsumer
    let error = OSAllocatedUnfairLock(initialState: OSStatus(noErr))
    let delivered = OSAllocatedUnfairLock(initialState: false)

    init(unit: AudioUnit, buffer: AVAudioPCMBuffer, consume: @escaping MicrophoneBufferConsumer) {
        self.unit = unit
        self.buffer = buffer
        self.consume = consume
    }

    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>,
                frames: UInt32) -> OSStatus {
        guard frames <= buffer.frameCapacity else {
            error.withLock { $0 = kAudio_ParamError }
            return kAudio_ParamError
        }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        error.withLock { $0 = status }
        if status == noErr {
            consume(buffer)
            delivered.withLock { $0 = true }
        }
        return status
    }
}

/// Construct the C callback outside actor isolation; Core Audio invokes it on its I/O thread.
private func makeHALCallback(_ context: HALCaptureContext) -> AURenderCallbackStruct {
    AURenderCallbackStruct(inputProc: { reference, flags, time, _, frames, _ in
        Unmanaged<HALCaptureContext>.fromOpaque(reference).takeUnretainedValue()
            .render(flags: flags, time: time, frames: frames)
    }, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
}

/// Remote devices can still be activating immediately after a previous client stops.
func startMicrophoneIO(_ start: () -> OSStatus, pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
    for attempt in 0..<3 {
        let status = start()
        if status == noErr { return }
        guard status == kAudioHardwareNotRunningError, attempt < 2 else { throw MicrophoneError.hardware(status) }
        pause(0.1 * Double(attempt + 1))
    }
}

/// An input-only HAL unit binds one device without changing system input or output defaults.
@MainActor
final class HALMicrophoneDriver: MicrophoneCaptureDriving {
    private var unit: AudioUnit?
    private var context: HALCaptureContext?
    private var nativeFormat: AudioStreamBasicDescription?

    func start(deviceID: UInt32, makeConsumer: (AVAudioFormat) throws -> MicrophoneBufferConsumer) throws {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync {
                try MainActor.assumeIsolated { try self.start(deviceID: deviceID, makeConsumer: makeConsumer) }
            }
        }
        stop()
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MicrophoneError.unavailable }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created))
        guard let created else { throw MicrophoneError.unavailable }
        unit = created
        do {
            var enabled: UInt32 = 1
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4))
            enabled = 0
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, 4))
            var selected = deviceID
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &selected, 4))
            let hardwareFormat = try streamFormat(created, scope: kAudioUnitScope_Input)
            let existingClient = try streamFormat(created, scope: kAudioUnitScope_Output)
            let rate = hardwareFormat.mSampleRate > 0 ? hardwareFormat.mSampleRate : existingClient.mSampleRate
            let hardwareChannels = hardwareFormat.mChannelsPerFrame
            let clientChannels = existingClient.mChannelsPerFrame
            let channels = hardwareChannels > 0 && clientChannels > 0
                ? min(hardwareChannels, clientChannels) : max(hardwareChannels, clientChannels)
            guard rate > 0, channels > 0,
                  let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
                  let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 16384) else {
                throw MicrophoneError.invalidFormat
            }
            // HAL converts sample representation, but its client rate must match the hardware clock.
            var clientFormat = pcmFormat.streamDescription.pointee
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &clientFormat, UInt32(MemoryLayout.size(ofValue: clientFormat))))
            let context = HALCaptureContext(unit: created, buffer: buffer, consume: try makeConsumer(pcmFormat))
            self.context = context
            var callback = makeHALCallback(context)
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))))
            try check(AudioUnitInitialize(created))
            try startMicrophoneIO { AudioOutputUnitStart(created) }
            nativeFormat = try streamFormat(created, scope: kAudioUnitScope_Input)
            var actual: UInt32 = 0
            var size: UInt32 = 4
            try check(AudioUnitGetProperty(created, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &actual, &size))
            guard actual == deviceID else { throw MicrophoneError.unavailable }
        } catch {
            stop()
            throw error
        }
    }

    var hasDeliveredFrames: Bool { context?.delivered.withLock { $0 } ?? false }

    func configurationChanged() throws -> Bool {
        guard let unit, let nativeFormat, let context else { throw MicrophoneError.unavailable }
        try check(context.error.withLock { $0 })
        let current = try streamFormat(unit, scope: kAudioUnitScope_Input)
        return current.mSampleRate != nativeFormat.mSampleRate || current.mChannelsPerFrame != nativeFormat.mChannelsPerFrame
            || current.mFormatFlags != nativeFormat.mFormatFlags || current.mBytesPerFrame != nativeFormat.mBytesPerFrame
    }

    func stop() {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { MainActor.assumeIsolated { self.stop() } }
        }
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        // The callback context outlives stopping, uninitialization, and disposal of the unit.
        context = nil
        nativeFormat = nil
    }

    isolated deinit { stop() }

    private func streamFormat(_ unit: AudioUnit, scope: AudioUnitScope) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 1, &format, &size))
        return format
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw MicrophoneError.hardware(status) }
    }
}
