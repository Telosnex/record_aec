import AVFoundation
import Foundation
import AudioToolbox

class RecorderStreamDelegate: NSObject, AudioRecordingStreamDelegate {
    private var audioEngine: AVAudioEngine?
    private var amplitude: Float = -160.0
    private let bus = 0
    private var onPause: () -> ()
    private var onStop: () -> ()
    
    init(onPause: @escaping () -> (), onStop: @escaping () -> ()) {
        self.onPause = onPause
        self.onStop = onStop
    }
    
    func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
        #if os(iOS)
        let audioEngine = AVAudioEngine()
        try initAVAudioSession(config: config)
        try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain, audioEngine: audioEngine)
        #else
        // On macOS, use Voice Processing AU for echo cancellation if enabled
        let audioEngine = try config.echoCancel ? 
            setupVoiceProcessingAU(config: config) : 
            AVAudioEngine()
        
        // If not using echo cancellation, set the input device directly
        if !config.echoCancel, 
           let deviceId = config.device?.id,
           let inputDeviceId = getAudioDeviceIDFromUID(uid: deviceId) {
            do {
                try audioEngine.inputNode.auAudioUnit.setDeviceID(inputDeviceId)
            } catch {
                throw RecorderError.error(
                    message: "Failed to start recording",
                    details: "Setting input device: \(deviceId) \(error)"
                )
            }
        }
        #endif
        
        let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        
        let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(config.sampleRate),
            channels: AVAudioChannelCount(config.numChannels),
            interleaved: true
        )
        
        guard let dstFormat = dstFormat else {
            throw RecorderError.error(
                message: "Failed to start recording",
                details: "Format is not supported: \(config.sampleRate)Hz - \(config.numChannels) channels."
            )
        }
        
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw RecorderError.error(
                message: "Failed to start recording",
                details: "Format conversion is not possible."
            )
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        
        audioEngine.inputNode.installTap(onBus: bus, bufferSize: 2048, format: srcFormat) { (buffer, _) -> Void in
            self.stream(
                buffer: buffer,
                dstFormat: dstFormat,
                converter: converter,
                recordEventHandler: recordEventHandler
            )
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        self.audioEngine = audioEngine
    }
    
    func stop(completionHandler: @escaping (String?) -> ()) {
        #if os(iOS)
        if let audioEngine = audioEngine {
            do {
                try setVoiceProcessing(echoCancel: false, autoGain: false, audioEngine: audioEngine)
            } catch {}
        }
        #endif
        
        audioEngine?.inputNode.removeTap(onBus: bus)
        audioEngine?.stop()
        audioEngine = nil
        
        completionHandler(nil)
        onStop()
    }
    
    func pause() {
        audioEngine?.pause()
        onPause()
    }
    
    func resume() throws {
        try audioEngine?.start()
    }
    
    func cancel() throws {
        stop { path in }
    }
    
    func getAmplitude() -> Float {
        return amplitude
    }
    
    func dispose() {
        stop { path in }
    }
    
    private func updateAmplitude(_ samples: [Int16]) {
        var maxSample: Float = -160.0
        
        for sample in samples {
            let curSample = abs(Float(sample))
            if (curSample > maxSample) {
                maxSample = curSample
            }
        }
        
        amplitude = 20 * (log(maxSample / 32767.0) / log(10))
    }
    
    // Little endian
    private func convertInt16toUInt8(_ samples: [Int16]) -> [UInt8] {
        var bytes: [UInt8] = []
        
        for sample in samples {
            bytes.append(UInt8(sample & 0x00ff))
            bytes.append(UInt8(sample >> 8 & 0x00ff))
        }
        
        return bytes
    }
    
    private func stream(
        buffer: AVAudioPCMBuffer,
        dstFormat: AVAudioFormat,
        converter: AVAudioConverter,
        recordEventHandler: RecordStreamHandler
    ) -> Void {
        let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        // Determine frame capacity
        let capacity = (UInt32(dstFormat.sampleRate) * dstFormat.channelCount * buffer.frameLength) / (UInt32(buffer.format.sampleRate) * buffer.format.channelCount)
        
        // Destination buffer
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
            print("Unable to create output buffer")
            stop { path in }
            return
        }
        
        // Convert input buffer (resample, num channels)
        var error: NSError? = nil
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
        if error != nil {
            return
        }
        
        if let channelData = convertedBuffer.int16ChannelData {
            // Fill samples
            let channelDataPointer = channelData.pointee
            let samples = stride(from: 0,
                               to: Int(convertedBuffer.frameLength),
                               by: buffer.stride).map{ channelDataPointer[$0] }
            
            // Update current amplitude
            updateAmplitude(samples)
            
            // Send bytes
            if let eventSink = recordEventHandler.eventSink {
                let bytes = Data(_: convertInt16toUInt8(samples))
                
                DispatchQueue.main.async {
                    eventSink(FlutterStandardTypedData(bytes: bytes))
                }
            }
        }
    }
    
    #if os(iOS)
    // Set up AGC & echo cancel for iOS
    private func setVoiceProcessing(echoCancel: Bool, autoGain: Bool, audioEngine: AVAudioEngine) throws {
        if #available(iOS 13.0, *) {
            do {
                try audioEngine.inputNode.setVoiceProcessingEnabled(echoCancel)
                audioEngine.inputNode.isVoiceProcessingAGCEnabled = autoGain
            } catch {
                throw RecorderError.error(
                    message: "Failed to setup voice processing",
                    details: "Echo cancel error: \(error)"
                )
            }
        }
    }
    
    private func initAVAudioSession(config: RecordConfig) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
    }
    #else
    // macOS Voice Processing implementation
    private func setupVoiceProcessingAU(config: RecordConfig) throws -> AVAudioEngine {
        let audioEngine = AVAudioEngine()
        
        // Create component description for Voice Processing Audio Unit
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        // Find the Voice Processing AU component
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw RecorderError.error(
                message: "Failed to setup voice processing",
                details: "Could not find Voice Processing AU component"
            )
        }
        
        // Create an instance of the Voice Processing AU
        var audioUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let au = audioUnit else {
            throw RecorderError.error(
                message: "Failed to setup voice processing",
                details: "Could not create Voice Processing AU instance"
            )
        }
        
        // Set the input device
        if let deviceId = config.device?.id,
           let inputDeviceId = getAudioDeviceIDFromUID(uid: deviceId) {
            var deviceIDValue = inputDeviceId
            let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let setDeviceStatus = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                1, // Input element
                &deviceIDValue,
                propertySize
            )
            
            if setDeviceStatus != noErr {
                throw RecorderError.error(
                    message: "Failed to setup voice processing",
                    details: "Could not set input device"
                )
            }
        }
        
        // Set default output device for AEC reference
        if var defaultOutputDevice = try? getDefaultOutputDeviceID() {
            let setOutputStatus = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0, // Output element
                &defaultOutputDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            
            if setOutputStatus != noErr {
                throw RecorderError.error(
                    message: "Failed to setup voice processing",
                    details: "Could not set output device for AEC"
                )
            }
        }
        
        // Set up the desired audio format
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * UInt32(config.numChannels),
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * UInt32(config.numChannels),
            mChannelsPerFrame: UInt32(config.numChannels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        // Set format for input
        let setFormatStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1, // Input element
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        
        if setFormatStatus != noErr {
            throw RecorderError.error(
                message: "Failed to setup voice processing",
                details: "Could not set audio format"
            )
        }
        
        // Initialize the AU
        let initStatus = AudioUnitInitialize(au)
        if initStatus != noErr {
            throw RecorderError.error(
                message: "Failed to setup voice processing",
                details: "Could not initialize Voice Processing AU"
            )
        }
        
        // Create an AVAudioUnit wrapper for the AU
        var audioUnit: AVAudioUnit?
        AVAudioUnit.instantiate(with: desc, options: .loadOutOfProcess) { avAudioUnit, _ in
            audioUnit = avAudioUnit
        }
        
        guard let audioUnit = audioUnit else {
            throw RecorderError.error(
                message: "Failed to setup voice processing",
                details: "Could not create AVAudioUnit wrapper"
            )
        }
        
        // Attach it to the engine
        audioEngine.attach(audioUnit)
        
        // Connect the input node to the main mixer
        audioEngine.connect(audioUnit, to: audioEngine.mainMixerNode, format: nil)
        
        return audioEngine
    }
    
    private func getDefaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        if status != noErr {
            throw RecorderError.error(
                message: "Failed to get default output device",
                details: "Error getting default output device"
            )
        }
        
        return deviceID
    }
    #endif
}