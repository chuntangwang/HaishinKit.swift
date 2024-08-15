import AVFoundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

/// An object that mixies audio and video for streaming.
public final actor MediaMixer {
    static let defaultFrameRate: Float64 = 30

    /// The MediaMixer error domain codes.
    public enum Error: Swift.Error {
        /// The mixer failed to failed to attach device.
        case failedToAttach(_ error: any Swift.Error)
        /// The mixer missing a device of track.
        case deviceNotFound
    }

    /// The offscreen rendering object.
    @ScreenActor
    public private(set) lazy var screen = Screen()

    #if os(iOS) || os(tvOS)
    /// The AVCaptureMultiCamSession enabled.
    @available(tvOS 17.0, *)
    public var isMultiCamSessionEnabled: Bool {
        session.isMultiCamSessionEnabled
    }
    #endif

    #if os(iOS) || os(macOS) || os(tvOS)
    /// The device torch indicating wheter the turn on(TRUE) or not(FALSE).
    public var isTorchEnabled: Bool {
        videoIO.torch
    }

    /// The feature to mix multiple audio tracks. For example, it is possible to mix .appAudio and .micAudio from ReplayKit.
    public var isMultiTrackAudioMixingEnabled: Bool {
        audioIO.isMultiTrackAudioMixingEnabled
    }

    /// The sessionPreset for the AVCaptureSession.
    @available(tvOS 17.0, *)
    public var sessionPreset: AVCaptureSession.Preset {
        session.sessionPreset
    }
    #endif

    /// The audio monitoring enabled or not.
    public var isMonitoringEnabled: Bool {
        audioIO.isMonitoringEnabled
    }

    /// The audio mixer settings.
    public var audioMixerSettings: AudioMixerSettings {
        audioIO.mixerSettings
    }

    /// The video mixer settings.
    public var videoMixerSettings: VideoMixerSettings {
        videoIO.mixerSettings
    }

    /// The audio input formats.
    public var audioInputFormats: [UInt8: AVAudioFormat] {
        audioIO.inputFormats
    }

    /// The video input formats.
    public var videoInputFormats: [UInt8: CMFormatDescription] {
        videoIO.inputFormats
    }

    /// The frame rate of a device capture.
    public var frameRate: Float64 {
        videoIO.frameRate
    }

    #if os(iOS) || os(macOS)
    /// Specifies the video orientation for stream.
    public var videoOrientation: AVCaptureVideoOrientation {
        videoIO.videoOrientation
    }
    #endif

    public private(set) var isRunning = false

    private var outputs: [any MediaMixerOutput] = []
    private lazy var audioIO = AudioCaptureUnit(session)
    private lazy var videoIO = VideoCaptureUnit(session)
    private lazy var session = CaptureSession()
    private var cancellables: Set<AnyCancellable> = []

    /// Creates a new instance.
    public init() {
        Task {
            await startRunning()
        }
    }

    /// Attaches a video device.
    @available(tvOS 17.0, *)
    public func attachVideo(_ device: AVCaptureDevice?, track: UInt8 = 0, configuration: VideoDeviceConfigurationBlock? = nil) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try videoIO.attachCamera(track, device: device, configuration: configuration)
                continuation.resume()
            } catch {
                continuation.resume(throwing: Error.failedToAttach(error))
            }
        }
    }

    /// Configurations for a video device.
    @available(tvOS 17.0, *)
    public func configuration(video track: UInt8, configuration: VideoDeviceConfigurationBlock) throws {
        guard let unit = videoIO.devices[track] else {
            throw Error.deviceNotFound
        }
        try configuration(unit)
    }

    #if os(iOS) || os(macOS) || os(tvOS)
    /// Attaches an audio device.
    ///
    /// You can perform multi-microphone capture by specifying as follows on macOS. Unfortunately, it seems that only one microphone is available on iOS.
    /// ```
    /// mixer.setMultiTrackAudioMixingEnabled(true)
    /// var audios = AVCaptureDevice.devices(for: .audio)
    /// if let device = audios.removeFirst() {
    ///    mixer.attachAudio(device, track: 0)
    /// }
    /// if let device = audios.removeFirst() {
    ///    mixer.attachAudio(device, track: 1)
    /// }
    /// ```
    @available(tvOS 17.0, *)
    public func attachAudio(_ device: AVCaptureDevice?, track: UInt8 = 0, configuration: AudioDeviceConfigurationBlock? = nil) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try audioIO.attachAudio(track, device: device, configuration: configuration)
                continuation.resume()
            } catch {
                continuation.resume(throwing: Error.failedToAttach(error))
            }
        }
    }

    /// Configurations for an audio device.
    @available(tvOS 17.0, *)
    public func configuration(audio track: UInt8, configuration: AudioDeviceConfigurationBlock) throws {
        guard let unit = audioIO.devices[track] else {
            throw Error.deviceNotFound
        }
        try configuration(unit)
    }

    /// Specifies the device torch indicating wheter the turn on(TRUE) or not(FALSE).
    public func setTorchEnabled(_ torchEnabled: Bool) {
        videoIO.torch = torchEnabled
    }

    /// Specifies the sessionPreset for the AVCaptureSession.
    @available(tvOS 17.0, *)
    public func setSessionPreset(_ sessionPreset: AVCaptureSession.Preset) {
        session.sessionPreset = sessionPreset
    }
    #endif

    #if os(iOS) || os(macOS)
    /// Specifies the video orientation for stream.
    public func setVideoOrientation(_ videoOrientation: AVCaptureVideoOrientation) {
        videoIO.videoOrientation = videoOrientation
    }
    #endif

    /// Appends a CMSampleBuffer.
    /// - Parameters:
    ///   - sampleBuffer:The sample buffer to append.
    ///   - track: Track number used for mixing
    public func append(_ sampleBuffer: CMSampleBuffer, track: UInt8 = 0) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .audio?:
            audioIO.append(track, buffer: sampleBuffer)
        case .video?:
            videoIO.append(track, buffer: sampleBuffer)
        default:
            break
        }
    }

    /// Specifies the video mixier settings.
    public func setVideoMixerSettings(_ settings: VideoMixerSettings) {
        videoIO.mixerSettings = settings
        Task { @ScreenActor in
            screen.videoTrackScreenObject.track = settings.mainTrack
        }
    }

    /// Specifies the frame rate of a device capture.
    public func setFrameRate(_ frameRate: Float64) {
        videoIO.frameRate = frameRate
    }

    /// Specifies the audio mixer settings.
    public func setAudioMixerSettings(_ settings: AudioMixerSettings) {
        audioIO.mixerSettings = settings
    }

    /// Specifies the audio monitoring enabled or not.
    public func setMonitoringEnabled(_ monitoringEnabled: Bool) {
        audioIO.isMonitoringEnabled = monitoringEnabled
    }

    #if os(iOS) || os(tvOS)
    /// Specifies the AVCaptureMultiCamSession enabled.
    /// Warning: If there is a possibility of using multiple cameras, please set it to true initially.
    public func setMultiCamSessionEnabled(_ multiCamSessionEnabled: Bool) {
        session.isMultiCamSessionEnabled = multiCamSessionEnabled
    }
    #endif

    /// Specifies the feature to mix multiple audio tracks. For example, it is possible to mix .appAudio and .micAudio from ReplayKit.
    /// Warning: If there is a possibility of this feature, please set it to true initially.
    public func setMultiTrackAudioMixingEnabled(_ multiTrackAudioMixingEnabled: Bool) {
        audioIO.isMultiTrackAudioMixingEnabled = multiTrackAudioMixingEnabled
    }

    /// Appends an AVAudioBuffer.
    /// - Parameters:
    ///   - audioBuffer:The audio buffer to append.
    ///   - when: The audio time to append.
    ///   - track: Track number used for mixing.
    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime, track: UInt8 = 0) {
        audioIO.append(track, buffer: audioBuffer, when: when)
    }

    /// Configurations for the AVCaptureSession.
    @available(tvOS 17.0, *)
    public func configuration(_ lambda: @Sendable (_ session: AVCaptureSession) throws -> Void) rethrows {
        try session.configuration(lambda)
    }

    /// Adds an output observer.
    public func addOutput(_ output: some MediaMixerOutput) {
        guard !outputs.contains(where: { $0 === output }) else {
            return
        }
        outputs.append(output)
    }

    /// Removes an output observer.
    public func removeOutput(_ output: some MediaMixerOutput) {
        if let index = outputs.firstIndex(where: { $0 === output }) {
            outputs.remove(at: index)
        }
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    func setBackgroundMode(_ background: Bool) {
        guard #available(tvOS 17.0, *) else {
            return
        }
        if background {
            videoIO.setBackgroundMode(background)
        } else {
            videoIO.setBackgroundMode(background)
            session.startRunningIfNeeded()
        }
    }
    #endif
}

extension MediaMixer: AsyncRunner {
    // MARK: AsyncRunner
    public func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        Task {
            for await inputs in videoIO.inputs where isRunning {
                Task { @ScreenActor in
                    screen.append(inputs.0, buffer: inputs.1)
                }
            }
        }
        Task {
            for await video in videoIO.output where isRunning {
                for output in outputs {
                    output.mixer(self, track: UInt8.max, didOutput: video)
                }
            }
        }
        Task {
            for await audio in audioIO.output where isRunning {
                for output in outputs {
                    output.mixer(self, track: UInt8.max, didOutput: audio.0, when: audio.1)
                }
            }
        }
        Task { @ScreenActor in
            for await _ in AsyncDisplayLink.updateFrames where await isRunning {
                guard let buffer = screen.makeSampleBuffer() else {
                    continue
                }
                await outputs.forEach { $0.mixer(self, track: UInt8.max, didOutput: buffer) }
            }
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter
            .Publisher(center: .default, name: UIApplication.didEnterBackgroundNotification, object: nil)
            .sink { _ in
                Task {
                    self.setBackgroundMode(true)
                }
            }
            .store(in: &cancellables)
        NotificationCenter
            .Publisher(center: .default, name: UIApplication.willEnterForegroundNotification, object: nil)
            .sink { _ in
                Task {
                    self.setBackgroundMode(false)
                }
            }
            .store(in: &cancellables)
        #endif
    }

    public func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
