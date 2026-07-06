import SwiftUI
import AVFoundation

import Combine // <-- Add this line
// MARK: - 1. NETWORK & DATA MODELS
struct SceneResponse: Codable {
    let status: String
    let data: SceneData
}

struct SceneData: Codable {
    let scenes: [String]
}

// MARK: - 2. THE CAMERA MANAGER (HARDWARE LOGIC)
class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var isRecording = false
    @Published var currentTake = 1
    
    let captureSession = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    // Developer Flags
    let use10BitColor = true
    let targetFPS: Double = 24.0

    func setupCamera() {
        captureSession.beginConfiguration()
        
        // Explicitly lock to the main wide-angle physical lens to prevent OS auto-switching
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        guard let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else { return }
        self.videoDeviceInput = videoInput

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }
        
        // Add Audio
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            
            // Force H.265 (HEVC)
            if let connection = movieOutput.connection(with: .video) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
        }
        
        configureSensorFormat(device: videoDevice)
        captureSession.commitConfiguration()
    }

    private func configureSensorFormat(device: AVCaptureDevice) {
        var selectedFormat: AVCaptureDevice.Format? = nil
        
        for format in device.formats {
            let ranges = format.videoSupportedFrameRateRanges
            let supports24FPS = ranges.contains { $0.minFrameRate <= targetFPS && $0.maxFrameRate >= targetFPS }
            
            if !supports24FPS { continue }
            
            // Check for 10-bit format (e.g., Apple Log or HDR)
let is10Bit = format.supportedColorSpaces.contains(.appleLog) || format.supportedColorSpaces.contains(.HLG_BT2020)            
            if use10BitColor && is10Bit {
                selectedFormat = format
                break
            } else if !use10BitColor && !is10Bit {
                selectedFormat = format
            }
        }
        
        if let format = selectedFormat ?? device.formats.first {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                // Lock framerate
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(targetFPS))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(targetFPS))
                device.unlockForConfiguration()
            } catch {
                print("Failed to lock sensor configuration")
            }
        }
    }

    func startSession() {
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .background).async {
                self.captureSession.startRunning()
            }
        }
    }

    func stopSession() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    func toggleRecording(baseFilename: String) {
        guard let connection = movieOutput.connection(with: .video) else { return }
        
        if isRecording {
            movieOutput.stopRecording()
        } else {
            // Lock orientation to current device orientation when recording starts
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight // Adjust based on physical rig setup
            }
            
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            let fileName = "\(baseFilename)-\(currentTake).mov"
            let fileUrl = paths[0].appendingPathComponent(fileName)
            
            try? FileManager.default.removeItem(at: fileUrl)
            movieOutput.startRecording(to: fileUrl, recordingDelegate: self)
        }
        
        DispatchQueue.main.async {
            self.isRecording.toggle()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.currentTake += 1
        }
    }
}

// MARK: - 3. VIEWFINDER BRIDGE
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        // Ensure preview rotates correctly
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        view.layer.addSublayer(previewLayer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 4. UI STATE & MAIN VIEW
struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    
    // App State
    @State private var isInCameraMode = false
    @State private var activeScenes: [String] = []
    @State private var selectedSceneIndex = 0
    @State private var showFinishDialog = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if isInCameraMode {
                cameraScreen
            } else {
                setupScreen
            }
        }
        .onAppear(perform: fetchFilenames)
        .alert(isPresented: $showFinishDialog) {
            Alert(
                title: Text("Finish Recording?"),
                message: Text("Are you done with scene:\n\(activeScenes[selectedSceneIndex])?"),
                primaryButton: .destructive(Text("YES, FINISH")) {
                    finishScene()
                },
                secondaryButton: .cancel(Text("CANCEL"))
            )
        }
    }
    
    // MARK: Setup UI
    var setupScreen: some View {
        VStack(spacing: 30) {
            Text("SELECT NEXT SCENE")
                .font(.headline)
                .bold()
                .foregroundColor(.white)
            
            if activeScenes.isEmpty {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
            } else {
                Picker("Scene", selection: $selectedSceneIndex) {
                    ForEach(0..<activeScenes.count, id: \.self) { index in
                        Text(activeScenes[index]).tag(index)
                    }
                }
                .pickerStyle(WheelPickerStyle())
                .frame(width: 300, height: 150)
                .background(Color.white)
                .cornerRadius(10)
                
                Button(action: enterCamera) {
                    Text("ENTER CAMERA")
                        .bold()
                        .frame(width: 300, height: 64)
                        .background(Color(white: 0.25))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
    }
    
    // MARK: Camera UI
    var cameraScreen: some View {
        ZStack {
            CameraPreview(session: cameraManager.captureSession)
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Spacer()
                    Button("EXIT APP") {
                        exit(0)
                    }
                    .font(.system(size: 10))
                    .padding(8)
                    .background(Color(white: 0.25))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .padding()
                }
                
                Spacer()
                
                // Bottom Control Bar
                HStack {
                    Spacer()
                    
                    // Record Toggle
                    Button(action: {
                        cameraManager.toggleRecording(baseFilename: activeScenes[selectedSceneIndex])
                    }) {
                        if cameraManager.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white, lineWidth: 2)
                                        .frame(width: 40, height: 40)
                                )
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 64, height: 64)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 4)
                                        .frame(width: 76, height: 76)
                                )
                        }
                    }
                    .frame(width: 80, height: 80)
                    
                    // Scene Info Box (Trigger for finish)
                    if !activeScenes.isEmpty {
                        Button(action: {
                            if cameraManager.isRecording {
                                // Ignore or show toast logic
                            } else {
                                showFinishDialog = true
                            }
                        }) {
                            let base = activeScenes[selectedSceneIndex]
                            let display = base.count > 10 ? String(base.prefix(10)) + "..." : base
                            Text("\(display)-\(cameraManager.currentTake)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(Color.white)
                                .cornerRadius(4)
                        }
                        .padding(.leading, 32)
                    }
                    
                    Spacer()
                }
                .padding(.bottom, 24)
                .background(Color.black.opacity(0.5))
            }
        }
    }
    
    // MARK: Logic
    private func fetchFilenames() {
        guard let url = URL(string: "https://auckland-oner-poc.netlify.app/filenames.json") else { return }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let data = data {
                do {
                    let decoded = try JSONDecoder().decode(SceneResponse.self, from: data)
                    DispatchQueue.main.async {
                        self.activeScenes = decoded.data.scenes
                    }
                } catch {
                    // Fallback
                    DispatchQueue.main.async {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyyMMdd-HHmmss"
                        self.activeScenes = [formatter.string(from: Date())]
                    }
                }
            }
        }.resume()
    }
    
    private func enterCamera() {
        isInCameraMode = true
        cameraManager.currentTake = 1
        cameraManager.setupCamera()
        cameraManager.startSession()
    }
    
    private func finishScene() {
        cameraManager.stopSession()
        activeScenes.remove(at: selectedSceneIndex)
        selectedSceneIndex = 0
        isInCameraMode = false
    }
}