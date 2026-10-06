import SwiftUI

struct TerminalView: View {
    let filePath: String
    @Binding var isPresented: Bool
    @State private var outputText: String = ""
    @State private var isRunning = true
    @State private var cursorVisible = true
    @State private var terminalExecutor: DebConversionExecutor?
    @State private var lastOutputLength = 0
    @EnvironmentObject private var appState: AppState

    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)

            VStack {
                HStack {
                    Spacer()

                    if isRunning {
                        ProgressView()
                            .progressViewStyle(
                                CircularProgressViewStyle(tint: .white)
                            )
                            .scaleEffect(0.8)
                            .padding()
                    } else {
                        Button(action: {
                            isPresented = false

                            if let executor = terminalExecutor,
                                executor.conversionSucceededValue
                            {
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.5
                                ) {
                                    appState.showShareSheet = true
                                }
                            } else {
                                appState.resetState()
                                NotificationCenter.default.post(
                                    name: Notification.Name(
                                        "hoshuclearSelectedFile"
                                    ),
                                    object: "conversion-failed"
                                )
                            }

                            terminalExecutor?.stop()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white)
                                .font(.system(size: 24))
                                .padding()
                        }
                    }
                }

                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading) {
                            Text(
                                outputText
                                    + (cursorVisible && isRunning ? "█" : "")
                            )
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("output")
                        }
                        .onChange(of: outputText) { newValue in
                            if newValue.count > lastOutputLength {
                                lastOutputLength = newValue.count
                                proxy.scrollTo("output", anchor: .bottom)
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.05
                                ) {
                                    withAnimation {
                                        proxy.scrollTo(
                                            "output",
                                            anchor: .bottom
                                        )
                                    }
                                }
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.2
                                ) {
                                    proxy.scrollTo("output", anchor: .bottom)
                                }
                            }
                        }
                        .onAppear {
                            lastOutputLength = outputText.count
                            proxy.scrollTo("output", anchor: .bottom)
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.1
                            ) {
                                proxy.scrollTo("output", anchor: .bottom)
                            }
                        }
                    }
                }

                Spacer()
            }
        }
        .onReceive(timer) { _ in
            cursorVisible.toggle()
        }
        .onAppear {
            startTerminalExecution()
        }
    }

    private func startTerminalExecution() {
        let executor = DebConversionExecutor(
            outputHandler: { newText in
                DispatchQueue.main.async {
                    self.outputText += newText
                }
            },
            completionHandler: { succeeded in
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.appState.isProcessing = false
                    if !succeeded {
                        self.appState.convertedFilePath = nil
                    }
                }
            },
            onConvertedFileFound: { convertedFilePath in
                DispatchQueue.main.async {
                    self.appState.convertedFilePath = convertedFilePath
                }
            }
        )

        self.terminalExecutor = executor
        executor.start(withFilePath: filePath)
    }
}
