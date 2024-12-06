// RecorderStreamDelegate.swift
// Example showing how to add AEC on macOS using Voice Processing I/O unit,
// while iOS remains unchanged. This snippet assumes you have the RecordConfig
// and RecordStreamHandler defined similarly as before.

import AVFoundation
import Foundation
import AudioToolbox

// Audio Unit property to control bypass of voice processing.
// Setting 0 enables AEC, setting 1 disables it.
private let kAUVoiceIOProperty_BypassVoiceProcessing: AudioUnitPropertyID = 2100

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
    let audioEngine = AVAudioEngine()
    
    #if os(iOS)
    try initAVAudioSession(config: config)
    // iOS logic remains unchanged:
    // We assume that on iOS you already have echo cancellation working
    // through AVAudioSession and setVoiceProcessingEnabled calls elsewhere.
    #else
    // On macOS, we will set up the voice processing I/O to enable AEC.

    // If a specific device is requested:
    if let deviceId = config.device?.id,
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
    
    // Enable AEC using a Voice Processing I/O unit
    try setupVoiceProcessingForMac(audioEngine: audioEngine,
                                   echoCancel: true, // Enable AEC
                                   sampleRate: Double(config.sampleRate),
                                   numChannels: AVAudioChannelCount(config.numChannels))
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
    // iOS teardown if needed. On iOS you might revert voice processing if used.
    // ...
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
  
  private func updateAmplitude(_ samples: [Int16]) {
    var maxSample:Float = -160.0

    for sample in samples {
      let curSample = abs(Float(sample))
      if (curSample > maxSample) {
        maxSample = curSample
      }
    }
    
    amplitude = 20 * (log(maxSample / 32767.0) / log(10))
  }
  
  func dispose() {
    stop { path in }
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
    
    // Convert input buffer (resample, change number of channels, etc.)
    var error: NSError? = nil
    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
    if error != nil {
      return
    }
    
    if let channelData = convertedBuffer.int16ChannelData {
      let channelDataPointer = channelData.pointee
      let samples = stride(from: 0,
                           to: Int(convertedBuffer.frameLength),
                           by: buffer.stride).map{ channelDataPointer[$0] }

      updateAmplitude(samples)

      if let eventSink = recordEventHandler.eventSink {
        let bytes = Data(_: convertInt16toUInt8(samples))
        DispatchQueue.main.async {
          eventSink(FlutterStandardTypedData(bytes: bytes))
        }
      }
    }
  }
}

// MARK: - macOS AEC Setup
#if !os(iOS)
extension RecorderStreamDelegate {
  
  // Sets up an AVAudioEngine with a Voice Processing I/O unit to enable AEC.
  // AGC is not enabled in this configuration.
  private func setupVoiceProcessingForMac(audioEngine: AVAudioEngine,
                                          echoCancel: Bool,
                                          sampleRate: Double,
                                          numChannels: AVAudioChannelCount) throws {
    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_VoiceProcessingIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )

    let sem = DispatchSemaphore(value: 0)
    var vpioAU: AVAudioUnit?
    
    AVAudioUnit.instantiate(with: desc, options: []) { au, error in
      if let error = error {
        print("Failed to instantiate VPIO: \(error)")
      }
      vpioAU = au
      sem.signal()
    }
    _ = sem.wait(timeout: .distantFuture)

    guard let voiceProcessingAU = vpioAU else {
      throw RecorderError.error(
        message: "Failed to setup AEC",
        details: "Could not instantiate Voice Processing IO unit."
      )
    }

    audioEngine.attach(voiceProcessingAU)
    
    let inputNode = audioEngine.inputNode
    let mainMixer = audioEngine.mainMixerNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    
    audioEngine.connect(inputNode, to: voiceProcessingAU, format: inputFormat)
    
    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: sampleRate,
                                     channels: numChannels,
                                     interleaved: true) ?? inputFormat
    audioEngine.connect(voiceProcessingAU, to: mainMixer, format: outputFormat)

    let audioUnitInstance = voiceProcessingAU.audioUnit

    // Enable I/O on input scope for the VPIO unit.
    var enableIO: UInt32 = 1
    var status = AudioUnitSetProperty(
      audioUnitInstance,
      kAudioOutputUnitProperty_EnableIO,
      kAudioUnitScope_Input,
      1,
      &enableIO,
      UInt32(MemoryLayout.size(ofValue: enableIO))
    )
    if status != noErr {
      throw RecorderError.error(
        message: "Failed to setup AEC",
        details: "AudioUnitSetProperty(EnableIO) failed: \(status)"
      )
    }

    // Enable or disable voice processing (AEC).
    var bypass: UInt32 = echoCancel ? 0 : 1
    status = AudioUnitSetProperty(
      audioUnitInstance,
      kAUVoiceIOProperty_BypassVoiceProcessing,
      kAudioUnitScope_Global,
      0,
      &bypass,
      UInt32(MemoryLayout.size(ofValue: bypass))
    )
    if status != noErr {
      throw RecorderError.error(
        message: "Failed to setup AEC",
        details: "AudioUnitSetProperty(BypassVoiceProcessing) failed: \(status)"
      )
    }

    // Initialize the voice processing IO unit.
    status = AudioUnitInitialize(audioUnitInstance)
    if status != noErr {
      throw RecorderError.error(
        message: "Failed to setup AEC",
        details: "AudioUnitInitialize() failed: \(status)"
      )
    }
  }

  // Helper to retrieve AudioDeviceID from UID on macOS.
  private func getAudioDeviceIDFromUID(uid: String) -> AudioDeviceID? {
    var deviceID = kAudioObjectUnknown
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var cfstr = uid as CFString
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &size,
      &deviceID
    )
    if status == noErr {
      return deviceID
    }
    return nil
  }
}
#endif
