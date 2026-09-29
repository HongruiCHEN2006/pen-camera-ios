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
                result.readSuccess == .yes ? "读取成功" : "读取失败",
                systemImage: result.readSuccess == .yes ? "checkmark.circle.fill" : "eye.slash.fill"
            )
            .foregroundStyle(result.readSuccess == .yes ? .green : .orange)
            Spacer()
            Text(controller.model)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }

        GroupBox {
            HStack {
                Text("题目是否读取成功")
                    .font(.headline)
                Spacer()
                Text(result.readSuccess.rawValue)
                    .font(.largeTitle.bold())
                    .foregroundStyle(result.readSuccess == .yes ? .green : .orange)
            }
            .padding(.top, 5)
        }

        if result.completeQuestions.isEmpty {
            Text("请调整距离、对焦或角度后重新截取。")
                .font(.body)
                .foregroundStyle(.secondary)
        } else {
            ForEach(result.completeQuestions) { question in
                GroupBox("题目 \(question.questionNumber)") {
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
