import AppKit
import Defaults
import Foundation

@MainActor
final class AssistantManager: ObservableObject {
    static let shared = AssistantManager()

    @Published var draft = ""
    @Published var shareScreenWithNextRequest = false
    @Published private(set) var phase: AssistantPhase = .idle
    @Published private(set) var liveTranscript = ""
    @Published private(set) var responseText = ""
    @Published private(set) var pointCommands: [AssistantPointCommand] = []
    @Published private(set) var suggestedActions: [AssistantSuggestedAction] = []
    @Published private(set) var actionConfirmation = ""
    @Published private(set) var isUsingScreenContext = false

    let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    private let codexService: AssistantCodexService
    private let voiceCaptureService: AssistantVoiceCaptureService
    private let speechService: AssistantSpeechService
    private var requestTask: Task<Void, Never>?
    private var voiceSessionID: UUID?
    private var lastQuestion = ""

    private init(
        codexService: AssistantCodexService = AssistantCodexService(),
        voiceCaptureService: AssistantVoiceCaptureService = AssistantVoiceCaptureService(),
        speechService: AssistantSpeechService = AssistantSpeechService()
    ) {
        self.codexService = codexService
        self.voiceCaptureService = voiceCaptureService
        self.speechService = speechService

        if isUITesting {
            draft = "What does this control do?"
            responseText = "That control changes how quickly spoken replies play. It does not affect dictation speed."
        }
    }

    var hasCompactPresentation: Bool {
        phase == .listening || phase == .processing
    }

    var statusLabel: String {
        switch phase {
        case .idle:
            return responseText.isEmpty ? "Ready" : "Answered"
        case .listening:
            return liveTranscript.isEmpty ? "Listening" : liveTranscript
        case .processing:
            return isUsingScreenContext ? "Reading screen" : "Thinking"
        case .responding:
            return "Speaking"
        case .failed:
            return "Needs attention"
        }
    }

    func toggleListening() {
        if phase == .listening {
            finishListening()
        } else if !phase.isBusy {
            startListening()
        }
    }

    func submitDraft() {
        submit(question: draft)
    }

    func cancel() {
        requestTask?.cancel()
        requestTask = nil
        voiceSessionID = nil
        voiceCaptureService.cancel()
        speechService.stop()
        AssistantPointerOverlayController.shared.dismiss()
        phase = .idle
        liveTranscript = ""
        isUsingScreenContext = false
    }

    func clearResponse() {
        responseText = ""
        pointCommands = []
        suggestedActions = []
        actionConfirmation = ""
        AssistantPointerOverlayController.shared.dismiss()
        phase = .idle
    }

    @discardableResult
    func copyResponse() -> Bool {
        guard !responseText.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(responseText, forType: .string)
    }

    func perform(_ action: AssistantSuggestedAction) {
        switch action {
        case .openCodex:
            let handoff = """
                Continue this Boring Notch Assistant request:

                User question:
                \(lastQuestion)

                Assistant answer:
                \(responseText)
                """
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            _ = pasteboard.setString(handoff, forType: .string)
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            ) else {
                actionConfirmation = "Codex is not installed. The handoff was copied."
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                Task { @MainActor [weak self] in
                    self?.actionConfirmation = error == nil
                        ? "Handoff copied. Paste it into Codex."
                        : "The handoff was copied, but Codex could not open."
                }
            }
        case .showCodexActivity:
            BoringViewCoordinator.shared.currentView = .codex
        case .showShelf:
            BoringViewCoordinator.shared.currentView = .shelf
        case .openAssistantSettings:
            SettingsWindowController.shared.showWindow(selectedTab: .assistant)
        case .playPause:
            MusicManager.shared.playPause()
            actionConfirmation = "Play or pause sent."
        case .nextTrack:
            MusicManager.shared.nextTrack()
            actionConfirmation = "Next track sent."
        case .previousTrack:
            MusicManager.shared.previousTrack()
            actionConfirmation = "Previous track sent."
        }
    }

    private func startListening() {
        let sessionID = UUID()
        voiceSessionID = sessionID
        liveTranscript = ""
        phase = .listening

        Task {
            do {
                try await voiceCaptureService.start(
                    onUpdate: { [weak self] transcript in
                        guard let self, voiceSessionID == sessionID else { return }
                        liveTranscript = transcript
                    },
                    onFinal: { [weak self] transcript in
                        guard let self, voiceSessionID == sessionID else { return }
                        voiceSessionID = nil
                        voiceCaptureService.cancel()
                        draft = transcript
                        submit(question: transcript)
                    },
                    onError: { [weak self] error in
                        guard let self, voiceSessionID == sessionID else { return }
                        fail(error)
                    }
                )
            } catch {
                guard voiceSessionID == sessionID else { return }
                fail(error)
            }
        }
    }

    private func finishListening() {
        let sessionID = voiceSessionID
        voiceCaptureService.stop()
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard voiceSessionID == sessionID, phase == .listening else { return }
            voiceSessionID = nil
            voiceCaptureService.cancel()
            let transcript = AssistantInputSanitizer.question(
                liveTranscript.isEmpty ? voiceCaptureService.latestTranscript : liveTranscript
            )
            guard !transcript.isEmpty else {
                phase = .failed("I didn't hear anything. Try again when you're ready.")
                return
            }
            draft = transcript
            submit(question: transcript)
        }
    }

    private func submit(question rawQuestion: String) {
        let question = AssistantInputSanitizer.question(rawQuestion)
        guard !question.isEmpty else { return }
        let shouldCaptureScreen = shareScreenWithNextRequest
        shareScreenWithNextRequest = false
        isUsingScreenContext = shouldCaptureScreen
        requestTask?.cancel()
        voiceSessionID = nil
        voiceCaptureService.cancel()
        speechService.stop()
        liveTranscript = ""
        responseText = ""
        pointCommands = []
        suggestedActions = []
        actionConfirmation = ""
        lastQuestion = question
        phase = .processing

        requestTask = Task {
            do {
                let capture = shouldCaptureScreen
                    ? try await AssistantScreenCaptureService.captureDisplayUnderPointer()
                    : nil
                let response = try await codexService.answer(
                    question: question,
                    screenCapture: capture
                )
                try Task.checkCancellation()
                responseText = response.text
                pointCommands = response.points
                suggestedActions = response.actions
                if let capture, !response.points.isEmpty {
                    AssistantPointerOverlayController.shared.show(
                        response.points,
                        on: capture.displayFrame
                    )
                }
                draft = ""
                phase = .idle
                isUsingScreenContext = false
                if Defaults[.assistantSpeakReplies] {
                    speechService.speak(
                        response.text,
                        rate: Float(Defaults[.assistantSpeechRate])
                    )
                }
            } catch is CancellationError {
                phase = .idle
                isUsingScreenContext = false
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        voiceSessionID = nil
        voiceCaptureService.cancel()
        liveTranscript = ""
        isUsingScreenContext = false
        let message = AssistantInputSanitizer.response(error.localizedDescription)
        phase = .failed(message.isEmpty ? "The assistant could not finish that request." : message)
    }
}
