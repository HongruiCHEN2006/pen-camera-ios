import SwiftUI

struct AnalysisResultView: View {
    @ObservedObject var controller: ExamAnalysisController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let image = controller.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .frame(maxWidth: .infinity)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                switch controller.phase {
                case .idle:
                    ContentUnavailableView(
                        "No Analysis",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Capture a frame from the live camera first.")
                    )
                case .analyzing:
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Reading question numbers and options…")
                            .font(.headline)
                        Text("Do not close the app while the request is running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                case let .succeeded(result):
                    resultContent(result)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Analysis Failed", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text(message)
                            .textSelection(.enabled)
                    } actions: {
                        Button("Retry Same Frame") {
                            controller.retry()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Analysis Result")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func resultContent(_ result: ExamAnalysisResult) -> some View {
        if result.questions.isEmpty {
            ContentUnavailableView(
                "No Questions Found",
                systemImage: "questionmark.square.dashed",
                description: Text("Try moving the page closer, improving focus, or changing the angle.")
            )
        } else {
            HStack {
                Label("\(result.questions.count) question(s)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text(controller.model)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(result.questions.enumerated()), id: \.offset) { _, question in
                questionCard(question)
            }
        }
    }

    private func questionCard(_ question: ExamQuestion) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Question \(question.questionNumber)")
                        .font(.title3.bold())
                    Spacer()
                    Label(
                        question.isClear ? "Clear" : "Not fully clear",
                        systemImage: question.isClear ? "eye.fill" : "eye.slash.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(question.isClear ? .green : .orange)
                }

                if question.options.isEmpty {
                    Text("No answer options were identified.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        HStack(alignment: .top, spacing: 10) {
                            Text(option.label)
                                .font(.headline.monospaced())
                                .frame(minWidth: 24, alignment: .leading)
                            Text(option.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        }
    }
}
