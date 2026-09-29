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
                        Text("Reading and solving the visible questions…")
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
        HStack {
            Label(
                result.questions.isEmpty ? "没有确定的题目" : "读取成功",
                systemImage: result.questions.isEmpty ? "eye.slash.fill" : "checkmark.circle.fill"
            )
            .foregroundStyle(result.questions.isEmpty ? .orange : .green)
            Spacer()
            Text(controller.model)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }

        GroupBox {
            HStack {
                Text("确定的题目")
                    .font(.headline)
                Spacer()
                Text("\(result.questions.count)")
                    .font(.largeTitle.bold())
                    .foregroundStyle(result.questions.isEmpty ? .orange : .green)
            }
            .padding(.top, 5)
        }

        if result.questions.isEmpty {
            Text("请调整距离、对焦或角度后重新截取。")
                .font(.body)
                .foregroundStyle(.secondary)
        } else {
            ForEach(result.questions) { question in
                GroupBox("\(question.questionNumber)：\(question.opening)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("答案")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(question.answer)
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 5)
                }
            }
        }
    }
}
