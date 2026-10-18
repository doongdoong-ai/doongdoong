import AVFoundation
import Observation
import SoriCore

@Observable @MainActor
final class AudioEngine: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    var isRecording = false
    var isPausedRecording = false
    var isPlaying = false
    var recordingTime: Double = 0
    var currentTime: Double = 0
    var duration: Double = 0
    var level: Float = 0
    var liveLevels: [Float] = Array(repeating: 0.04, count: 80)
    var rate: Float = 1 { didSet { player?.rate = rate } }
    var volume: Float = 1 { didSet { player?.volume = volume } }
    var onRecordingError: ((String) -> Void)?
    var onPlaybackError: ((String) -> Void)?
    private(set) var loopRange: ClosedRange<Double>?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    // Installed once during main-actor initialization; deinit only invalidates them.
    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var inputObserver: NSObjectProtocol?
    private var recordingDeviceID: String?

    override init() {
        super.init()
        let clock = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
        inputObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] notification in
            let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
            Task { @MainActor in
                guard let self, let deviceID, self.isRecording, self.recordingDeviceID == deviceID else { return }
                self.finishRecording()
                self.onRecordingError?("사용하던 마이크의 연결이 해제되어 녹음을 마쳤습니다. 저장된 오디오는 보관되어 있으며 다시 전사할 수 있습니다.")
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let inputObserver { NotificationCenter.default.removeObserver(inputObserver) }
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startRecording(to url: URL) throws {
        stopPlayback()
        let options: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: options)
        recorder.delegate = self; recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else { throw SoriError.message("마이크를 시작할 수 없습니다. 입력 장치를 확인해 주세요.") }
        self.recorder = recorder; isRecording = true; isPausedRecording = false; recordingTime = 0
        recordingDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        liveLevels = Array(repeating: 0.04, count: 80)
    }

    func pauseRecording() {
        guard let recorder, isRecording else { return }
        if isPausedRecording {
            guard recorder.record() else {
                finishRecording()
                onRecordingError?("녹음을 다시 시작하지 못했습니다. 입력 장치를 확인해 주세요. 지금까지의 오디오는 보관됩니다.")
                return
            }
        } else { recorder.pause() }
        isPausedRecording.toggle()
    }

    @discardableResult func finishRecording() -> Double {
        let time = recorder?.currentTime ?? recordingTime
        let previous = recorder; recorder = nil
        previous?.stop(); isRecording = false; isPausedRecording = false; level = 0; recordingTime = time
        recordingDeviceID = nil
        return time
    }

    func load(_ url: URL) throws {
        stopPlayback()
        let player = try AVAudioPlayer(contentsOf: url)
        player.enableRate = true; player.rate = rate; player.volume = volume; player.delegate = self
        guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
            throw SoriError.message("오디오를 재생할 수 없습니다. 파일이 비어 있거나 손상되었는지 확인해 주세요.")
        }
        self.player = player; duration = player.duration; currentTime = 0
    }
    func togglePlayback() {
        guard let player, !isRecording else { return }
        if player.isPlaying { player.pause(); isPlaying = false }
        else {
            if let loopRange, !loopRange.contains(player.currentTime) || player.currentTime >= loopRange.upperBound {
                player.currentTime = loopRange.lowerBound
            } else if player.currentTime >= player.duration - 0.03 { player.currentTime = loopRange?.lowerBound ?? 0 }
            isPlaying = player.play()
            if !isPlaying { onPlaybackError?("재생을 시작하지 못했습니다. Mac의 출력 장치를 확인해 주세요.") }
        }
    }
    func seek(_ time: Double) {
        guard let player, time.isFinite else { return }
        let target = min(max(0, time), player.duration)
        if let loopRange, target < loopRange.lowerBound || target >= loopRange.upperBound { clearLoop() }
        player.currentTime = target; currentTime = target
    }
    func setLoop(start: Double, end: Double) {
        guard player != nil, start.isFinite, end.isFinite else { return }
        let lower = max(0, start), upper = min(duration, end)
        guard upper - lower >= 0.05 else { return }
        loopRange = lower...upper
        if currentTime < lower || currentTime >= upper { seek(lower) }
    }
    func clearLoop() { loopRange = nil }
    func stopPlayback() {
        player?.stop(); player = nil; isPlaying = false; currentTime = 0; duration = 0; clearLoop()
    }
    private func tick() {
        if let recorder, isRecording {
            recorder.updateMeters(); recordingTime = recorder.currentTime
            level = isPausedRecording ? 0.03 : max(0.03, min(1, pow(10, recorder.averagePower(forChannel: 0) / 35)))
            liveLevels.removeFirst(); liveLevels.append(level)
        }
        if let player, isPlaying {
            if let loopRange, player.currentTime >= loopRange.upperBound {
                player.currentTime = loopRange.lowerBound
                if !player.isPlaying { isPlaying = player.play() }
            }
            currentTime = player.currentTime
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            if flag, self.isPlaying, let loopRange = self.loopRange {
                player.currentTime = loopRange.lowerBound; self.currentTime = loopRange.lowerBound
                self.isPlaying = player.play()
            } else {
                self.isPlaying = false; self.currentTime = flag ? self.duration : player.currentTime
                if !flag { self.onPlaybackError?("오디오 재생이 중단되었습니다. 출력 장치와 파일을 확인해 주세요.") }
            }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.isPlaying = false
            self.onPlaybackError?("오디오 파일을 읽지 못했습니다. 다른 플레이어에서도 재생되는지 확인해 주세요.")
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.finishRecording()
            self.onRecordingError?("녹음을 저장하는 중 문제가 생겼습니다. 저장 공간과 마이크 연결을 확인해 주세요.")
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.finishRecording()
            self.onRecordingError?(flag ? "녹음이 예기치 않게 종료되었습니다. 저장된 오디오는 다시 전사할 수 있습니다." : "녹음이 중단되었습니다. 마이크 연결과 저장 공간을 확인해 주세요. 저장된 오디오는 보관됩니다.")
        }
    }

    nonisolated static func inspect(_ url: URL, bins: Int = 180) throws -> (duration: Double, waveform: [Float]) {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0, file.length > 0 else { throw SoriError.message("오디오 파일에 재생할 내용이 없습니다.") }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let bucketCount = max(1, min(10_000, bins))
        let bucketSize = max(1, Int(ceil(Double(file.length) / Double(bucketCount))))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            return (duration, [])
        }
        var peaks: [Float] = [], peak: Float = 0, count = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for index in 0..<Int(buffer.frameLength) {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let sample = abs(channels[channel][index])
                    if sample.isFinite { peak = max(peak, sample) }
                }
                count += 1
                if count >= bucketSize { peaks.append(peak); count = 0; peak = 0 }
            }
        }
        if count > 0 { peaks.append(peak) }
        let maxPeak = peaks.max() ?? 1
        return (duration, peaks.map { max(0.035, $0 / max(0.01, maxPeak)) })
    }
}
