import AVFoundation
import Foundation
import os.log

class RecorderStreamDelegate: NSObject, AudioRecordingStreamDelegate {
  private var audioEngine: AVAudioEngine?
  private var processingGraph: AUGraph?
  private var amplitude: Float = -160.0
  private let bus = 0
  private var onPause: () -> ()
  private var onStop: () -> ()
  
  init(onPause: @escaping () -> (), onStop: @escaping () -> ()) {
    self.onPause = onPause
    self.onStop = onStop
  }

  private func setupEchoCancellation() throws {
    // Create and open the processing graph
    if let error = NewAUGraph(&self.processingGraph).error {
      throw RecorderError.error(
        message: "Failed to create processing graph",
        details: error.localizedDescription
      )
    }

    if let error = AUGraphOpen(self.processingGraph!).error {
      throw RecorderError.error(
        message: "Failed to open processing graph",
        details: error.localizedDescription
      )
    }

    // Configure the VoiceProcessingIO audio unit
    var description = AudioComponentDescription()
    description.componentType = kAudioUnitType_Output
    description.componentSubType = kAudioUnitSubType_VoiceProcessingIO
    description.componentManufacturer = kAudioUnitManufacturer_Apple

    var remoteIONode: AUNode = AUNode()
    
    if let error = AUGraphAddNode(self.processingGraph!, &description, &remoteIONode).error {
      throw RecorderError.error(
        message: "Failed to add remote IO node",
        details: error.localizedDescription
      )
    }

    if let error = AUGraphInitialize(self.processingGraph!).error {
      throw RecorderError.error(
        message: "Failed to initialize processing graph",
        details: error.localizedDescription
      )
    }
  }

  func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
    let audioEngine = AVAudioEngine()
    
    #if os(macOS)
    // Set up echo cancellation for macOS
    try setupEchoCancellation()
    
    // Set input device and enable voice processing
    if let deviceId = config.device?.id,
       let inputDeviceId = getAudioDeviceIDFromUID(uid: deviceId) {
      do {
        try audioEngine.inputNode.auAudioUnit.setDeviceID(inputDeviceId)
        
        if config.echoCancel {
          // Enable voice processing on both input and output nodes
          try audioEngine.inputNode.setVoiceProcessingEnabled(true)
          audioEngine.inputNode.isVoiceProcessingBypassed = false
          try audioEngine.outputNode.setVoiceProcessingEnabled(true)
          print("Voice processing enabled for input and output nodes")
        }
      } catch {
        throw RecorderError.error(
          message: "Failed to start recording",
          details: "Setting input device: \(deviceId) \(error)"
        )
      }
    }
    #else
    // iOS setup code remains unchanged
    try initAVAudioSession(config: config)
    try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain, audioEngine: audioEngine)
    #endif
    
    let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
    os_log(.info, log: log, "Source format - Sample Rate: %{public}f, Channels: %{public}d", 
           srcFormat.sampleRate, 
           srcFormat.channelCount)
    
    // Try to match source sample rate if possible
    let actualSampleRate = config.sampleRate > 0 ? Double(config.sampleRate) : srcFormat.sampleRate
    
    let dstFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: actualSampleRate,
      channels: AVAudioChannelCount(config.numChannels),
      interleaved: true
    )

    guard let dstFormat = dstFormat else {
      let errorMsg = String(format: "Failed to create format with sample rate: %.1f Hz, channels: %d",
                          actualSampleRate, config.numChannels)
      os_log(.error, log: log, "%{public}@", errorMsg)
      throw RecorderError.error(
        message: "Failed to start recording",
        details: errorMsg
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

    #if os(macOS)
    if let graph = processingGraph {
      AUGraphClose(graph)
      DispatchQueue.main.async {
        AUGraphUninitialize(graph)
        self.processingGraph = nil
      }
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
  
  // Set up AGC & echo cancel
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
}


extension OSStatus {
    var error: NSError? {
        guard self != noErr else { return nil }
        
        let message = self.asString() ?? "Unrecognized OSStatus"
        
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(self),
            userInfo: [
                NSLocalizedDescriptionKey: message
            ])
    }
    
    private func asString() -> String? {
        let n = UInt32(bitPattern: self.littleEndian)
        guard let n1 = UnicodeScalar((n >> 24) & 255), n1.isASCII else { return nil }
        guard let n2 = UnicodeScalar((n >> 16) & 255), n2.isASCII else { return nil }
        guard let n3 = UnicodeScalar((n >> 8) & 255), n3.isASCII else { return nil }
        guard let n4 = UnicodeScalar(n & 255), n4.isASCII else { return nil }
        return String(n1) + String(n2) + String(n3) + String(n4)
    }
}