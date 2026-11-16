import AVFoundation
import Speech
import SwiftUI

@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var error: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var runID: UUID?
    private var tapInstalled = false
    private var sessionActive = false

    func toggle(onText: @escaping (String) -> Void) {
        if runID != nil { stop(); return }
        error = nil
        let id = UUID()
        runID = id
        Task { [weak self] in
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard let self, self.runID == id else { return }
            guard speech == .authorized else {
                self.error = "Speech recognition is disabled. Enable Speech Recognition for Notestrand in Settings."
                self.stop()
                return
            }
            let microphone = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard self.runID == id else { return }
            guard microphone else {
                self.error = "Microphone access is disabled. Enable the microphone for Notestrand in Settings."
                self.stop()
                return
            }
            self.start(id, onText: onText)
        }
    }

    private func start(_ id: UUID, onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is unavailable right now. Please try again."
            stop()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            sessionActive = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                error = "No microphone is available. Connect a microphone and try again."
                stop()
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRecording = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                Task { @MainActor [weak self] in
                    guard let self, self.runID == id else { return }
                    if let result {
                        onText(result.bestTranscription.formattedString)
                        guard self.runID == id else { return }
                        if result.isFinal { self.stop(); return }
                        self.resetSilenceTimeout(id)
                    }
                    if let failure {
                        let ns = failure as NSError
                        // Apple bug: the iOS 26.4/26.5 simulators always fail this way; real devices don't.
                        self.error = ns.domain == "kLSRErrorDomain" && ns.code == 300
                            ? "Speech recognition couldn't start on this device. Use the keyboard's mic key instead."
                            : "Dictation stopped: \(failure.localizedDescription)"
                        self.stop()
                    }
                }
            }
            resetSilenceTimeout(id)
        } catch {
            self.error = "Couldn't start dictation: \(error.localizedDescription)"
            stop()
        }
    }

    private func resetSilenceTimeout(_ id: UUID) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, self.runID == id else { return }
            self.stop()
        }
    }

    private func stop() {
        // Invalidate callbacks before cancelling the recognizer, including permission replies.
        runID = nil
        silenceTask?.cancel()
        silenceTask = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
        if sessionActive {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            } catch {
                self.error = self.error ?? "Couldn't release the microphone: \(error.localizedDescription)"
            }
        }
        assert(!engine.isRunning && !tapInstalled && recognitionTask == nil && request == nil)
    }

    deinit {
        silenceTask?.cancel()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        recognitionTask?.cancel()
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

struct MicButton: View {
    @ObservedObject var voice: VoiceInput
    var onText: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var shouldPulse: Bool { voice.isRecording && !reduceMotion }

    var body: some View {
        Button { voice.toggle(onText: onText) } label: {
            Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(voice.isRecording ? .red : .accentColor)
                .scaleEffect(pulsing && shouldPulse ? 1.08 : 1)
                .animation(shouldPulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: pulsing)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate")
        .onAppear { pulsing = shouldPulse }
        .onChange(of: shouldPulse) { pulsing = $0 }
    }
}
