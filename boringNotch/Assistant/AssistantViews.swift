import AVFoundation
import Defaults
import Speech
import SwiftUI

struct AssistantCompactActivityView: View {
    @ObservedObject private var manager = AssistantManager.shared
    let notchWidth: CGFloat
    let height: CGFloat
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                compactWing(alignment: .trailing) {
                    Text(manager.phase == .listening ? "Voice" : "Assistant")
                }
                Color.black.frame(width: notchWidth)
                compactWing(alignment: .leading) {
                    HStack(spacing: 5) {
                        if manager.phase == .listening {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        } else if reduceMotion {
                            Image(systemName: "circle.fill")
                        } else {
                            ProgressView().controlSize(.mini).tint(.white.opacity(0.8))
                        }
                        Text(manager.statusLabel).lineLimit(1)
                    }
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assistant, \(manager.statusLabel)")
        .accessibilityHint("Open Assistant")
    }

    private func compactWing<Content: View>(
        alignment: Alignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 110, alignment: alignment)
            .padding(.horizontal, 9)
    }
}

struct AssistantPanel: View {
    @ObservedObject private var manager = AssistantManager.shared
    @State private var copied = false
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            responseArea
            Divider().overlay(.white.opacity(0.12))
            if manager.shareScreenWithNextRequest {
                screenShareNotice
            }
            composer
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("assistant-panel")
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: headerIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(headerColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant").font(.system(size: 13, weight: .semibold))
                Text(manager.statusLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer()
            if manager.phase.isBusy {
                Button("Cancel", systemImage: "xmark") { manager.cancel() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Cancel request")
                    .accessibilityLabel("Cancel Assistant request")
            }
            Button {
                SettingsWindowController.shared.showWindow(selectedTab: .assistant)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Assistant settings")
            .accessibilityLabel("Assistant settings")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder
    private var responseArea: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 9) {
                switch manager.phase {
                case .listening:
                    listeningView
                case .processing, .responding:
                    processingView
                case .failed(let message):
                    failureView(message)
                case .idle where !manager.responseText.isEmpty:
                    responseView
                case .idle:
                    emptyView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyView: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.effectiveAccent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask without leaving what you're doing")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Type a question or use your voice. Share the screen only when the answer needs it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var listeningView: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Listening…").font(.system(size: 12.5, weight: .semibold))
                Text(manager.liveTranscript.isEmpty ? "Tap the microphone again when you're done." : manager.liveTranscript)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening. \(manager.liveTranscript)")
    }

    private var processingView: some View {
        HStack(spacing: 10) {
            if reduceMotion {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color.effectiveAccent)
                    .frame(width: 28)
            } else {
                ProgressView().controlSize(.small).tint(Color.effectiveAccent).frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Working on it").font(.system(size: 12.5, weight: .semibold))
                Text("The question and any shared screen are sent through Codex. Temporary screenshots are deleted when it finishes.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func failureView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text("Couldn't finish that").font(.system(size: 12.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.68))
                    .textSelection(.enabled)
                Button("Try again") { manager.submitDraft() }
                    .buttonStyle(.link)
                    .font(.system(size: 10.5, weight: .semibold))
            }
        }
    }

    private var responseView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Answer").font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copied = manager.copyResponse()
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .font(.system(size: 10.5, weight: .semibold))
            }
            Text(manager.responseText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.82))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            actionButtons
            Button("Continue in Codex", systemImage: "arrow.up.right.square") {
                manager.perform(.openCodex)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5, weight: .semibold))
            .help("Copy this exchange and open Codex")
            if !manager.actionConfirmation.isEmpty {
                Text(manager.actionConfirmation)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.58))
                    .accessibilityLabel(manager.actionConfirmation)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        let actions = manager.suggestedActions.filter { $0 != .openCodex }
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Suggested actions")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 6) {
                    ForEach(actions, id: \.self) { action in
                        Button(action.title, systemImage: action.systemImage) {
                            manager.perform(action)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Runs only after you click")
                    }
                }
            }
        }
    }

    private var screenShareNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.rectangle.fill")
            Text("Current display will be sent to Codex once")
            Spacer()
            Button("Remove") { manager.shareScreenWithNextRequest = false }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.effectiveAccent)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Color.effectiveAccent.opacity(0.09))
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        HStack(spacing: 7) {
            Button {
                manager.shareScreenWithNextRequest.toggle()
            } label: {
                Image(systemName: manager.shareScreenWithNextRequest ? "checkmark.rectangle.fill" : "rectangle.on.rectangle")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(manager.shareScreenWithNextRequest ? Color.effectiveAccent : .white.opacity(0.64))
            .help(manager.shareScreenWithNextRequest ? "Remove screen from this request" : "Share current display with this request")
            .accessibilityLabel(manager.shareScreenWithNextRequest ? "Screen will be shared once" : "Share current display once")

            TextField("Ask anything", text: $manager.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($composerFocused)
                .onSubmit { manager.submitDraft() }
                .disabled(manager.phase.isBusy)
                .accessibilityLabel("Assistant question")

            Button {
                manager.toggleListening()
            } label: {
                Image(systemName: manager.phase == .listening ? "stop.fill" : "mic.fill")
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(manager.phase == .listening ? Color.red : Color.white.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(manager.phase == .processing || manager.phase == .responding)
            .accessibilityLabel(manager.phase == .listening ? "Stop listening" : "Start voice question")

            Button {
                manager.submitDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(manager.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.phase.isBusy)
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var headerIcon: String {
        switch manager.phase {
        case .listening: return "waveform"
        case .processing, .responding: return "sparkles"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "bubble.left.and.waveform.fill"
        }
    }

    private var headerColor: Color {
        switch manager.phase {
        case .listening: return .red
        case .failed: return .orange
        case .processing, .responding, .idle: return .effectiveAccent
        }
    }
}

struct AssistantSettingsView: View {
    @Default(.assistantEnabled) private var assistantEnabled
    @Default(.assistantSpeakReplies) private var speakReplies
    @Default(.assistantSpeechRate) private var speechRate

    var body: some View {
        Form {
            Section("Assistant") {
                Toggle("Show Assistant in the notch", isOn: $assistantEnabled)
                Text("Voice and screen access are requested only after you use the matching control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice") {
                Toggle("Speak replies", isOn: $speakReplies)
                LabeledContent("Speech speed") {
                    HStack {
                        Slider(value: $speechRate, in: 0.38...0.62, step: 0.01)
                            .frame(width: 180)
                        Text("\(Int(speechRate * 200))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Privacy") {
                LabeledContent("Screen context", value: "Per request")
                LabeledContent("Screenshot retention", value: "None")
                LabeledContent("Assistant session", value: "Ephemeral")
                Text("Only the display under the pointer is captured, Boring Notch windows are excluded, and the temporary image is removed after the bounded request finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Engine") {
                LabeledContent("Answers", value: "Your Codex account")
                LabeledContent("Speech", value: "On-device Apple Speech")
                Text("Questions and one-request screenshots are sent to OpenAI through your local Codex sign-in. Assistant requests run read-only, ignore project rules and hooks, and cannot approve or execute computer actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Assistant")
    }
}
