import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit
import Speech

enum AssistantServiceError: LocalizedError {
    case codexUnavailable
    case emptyResponse
    case microphoneDenied
    case speechRecognitionDenied
    case speechRecognitionUnavailable
    case screenCaptureUnavailable
    case requestTimedOut
    case responseTooLarge
    case codexFailed

    var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            return "Codex is not available. Install or open Codex, then try again."
        case .emptyResponse:
            return "The assistant finished without an answer."
        case .microphoneDenied:
            return "Microphone access is off. Enable it in System Settings to use voice."
        case .speechRecognitionDenied:
            return "Speech Recognition access is off. Enable it in System Settings to use voice."
        case .speechRecognitionUnavailable:
            return "On-device speech recognition is not available right now."
        case .screenCaptureUnavailable:
            return "No display is available to share right now."
        case .requestTimedOut:
            return "Codex took too long to answer. Try a shorter request."
        case .responseTooLarge:
            return "Codex returned more text than Assistant can safely display."
        case .codexFailed:
            return "Codex could not answer. Open Codex, confirm you're signed in, and try again."
        }
    }
}

// Adapted from Clicky (MIT) at commit a80fa80721a8aebe51a170a7780705024ebc6e46.
// Copyright (c) 2026 Farza.
struct AssistantScreenCapture: Sendable {
    let imageData: Data
    let displayFrame: CGRect
}

// Adapted from Clicky (MIT) at commit a80fa80721a8aebe51a170a7780705024ebc6e46.
// Copyright (c) 2026 Farza.
@MainActor
enum AssistantScreenCaptureService {
    static func captureDisplayUnderPointer() async throws -> AssistantScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let pointerLocation = NSEvent.mouseLocation
        let screensByDisplayID = [CGDirectDisplayID: NSScreen](
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID else { return nil }
                return (displayID, screen)
            }
        )
        guard let display = content.displays.first(where: { display in
            (screensByDisplayID[display.displayID]?.frame ?? display.frame)
                .contains(pointerLocation)
        }) ?? content.displays.first else {
            throw AssistantServiceError.screenCaptureUnavailable
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        let configuration = SCStreamConfiguration()
        let maximumDimension = 1_280
        let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
        if display.width >= display.height {
            configuration.width = maximumDimension
            configuration.height = max(1, Int(CGFloat(maximumDimension) / aspectRatio))
        } else {
            configuration.height = maximumDimension
            configuration.width = max(1, Int(CGFloat(maximumDimension) * aspectRatio))
        }
        configuration.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: ownWindows),
            configuration: configuration
        )
        guard let imageData = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.78]
        ) else {
            throw AssistantServiceError.emptyResponse
        }
        let displayFrame = screensByDisplayID[display.displayID]?.frame ?? display.frame
        return AssistantScreenCapture(imageData: imageData, displayFrame: displayFrame)
    }
}

struct AssistantCodexService: Sendable {
    private let executableLocator: CodexExecutableLocator

    init(executableLocator: CodexExecutableLocator = CodexExecutableLocator()) {
        self.executableLocator = executableLocator
    }

    func answer(question: String, screenCapture: AssistantScreenCapture?) async throws
        -> AssistantParsedResponse
    {
        let executable: URL
        do {
            executable = try executableLocator.locate()
        } catch {
            throw AssistantServiceError.codexUnavailable
        }

        return try await runBoundedProcessOperation {
            let fileManager = FileManager.default
            let requestDirectory = fileManager.temporaryDirectory.appendingPathComponent(
                "boring-notch-assistant-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: requestDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: requestDirectory) }

            var arguments = [
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--color", "never",
                "-C", requestDirectory.path,
            ]
            if let screenCapture {
                let imageURL = requestDirectory.appendingPathComponent("screen.jpg")
                try screenCapture.imageData.write(to: imageURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
                arguments.append(contentsOf: ["--image", imageURL.path])
            }
            arguments.append(AssistantPromptBuilder.prompt(
                question: question,
                includesScreen: screenCapture != nil
            ))

            let runner = try BoundedProcessRunner(
                executableURL: executable,
                arguments: arguments,
                timeout: 90,
                maximumOutputSize: 256 * 1_024
            )
            defer { runner.stop() }
            do {
                try runner.readToExit()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BoundedProcessRunnerError {
                switch error {
                case .timedOut:
                    throw AssistantServiceError.requestTimedOut
                case .responseTooLarge:
                    throw AssistantServiceError.responseTooLarge
                default:
                    throw AssistantServiceError.codexFailed
                }
            }
            guard let response = String(data: runner.output, encoding: .utf8) else {
                throw AssistantServiceError.emptyResponse
            }
            let parsed = AssistantResponseParser.parse(response)
            guard !parsed.text.isEmpty else { throw AssistantServiceError.emptyResponse }
            return parsed
        }
    }
}

@MainActor
final class AssistantVoiceCaptureService {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledAudioTap = false
    private(set) var latestTranscript = ""

    func start(
        onUpdate: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async throws {
        guard await requestMicrophonePermission() else {
            throw AssistantServiceError.microphoneDenied
        }
        try Task.checkCancellation()
        guard await requestSpeechRecognitionPermission() else {
            throw AssistantServiceError.speechRecognitionDenied
        }
        try Task.checkCancellation()
        guard
            let recognizer = preferredRecognizer(),
            recognizer.isAvailable,
            recognizer.supportsOnDeviceRecognition
        else {
            throw AssistantServiceError.speechRecognitionUnavailable
        }
        try Task.checkCancellation()

        cancel()
        latestTranscript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    onUpdate(self.latestTranscript)
                    if result.isFinal { onFinal(self.latestTranscript) }
                } else if let error {
                    onError(error)
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        hasInstalledAudioTap = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        recognitionRequest?.endAudio()
    }

    func cancel() {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func preferredRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: .autoupdatingCurrent)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestSpeechRecognitionPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

@MainActor
final class AssistantSpeechService {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, rate: Float) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.autoupdatingCurrent.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
