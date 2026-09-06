import SwiftUI
import AVFoundation
import Vision

/// Anteprima della fotocamera; i fotogrammi passano da Vision, che legge anche
/// i codici chiari su fondo scuro come la nuvola mostrata dal Mac.
struct ScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_ c: ScannerController, context: Context) { c.onCode = onCode }
}

final class ScannerController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let videoQueue = DispatchQueue(label: "trackair.scanner")
    private var busy = false
    private var lastCode = ""
    private var lastTime = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.sessionPreset = .hd1280x720
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(out) else { return }
        session.addOutput(out)
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        view.layer.addSublayer(p)
        preview = p
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let conn = preview?.connection {
            let o = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let angle: CGFloat
            switch o {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !busy, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        let req = VNDetectBarcodesRequest { [weak self] r, _ in
            defer { self?.busy = false }
            guard let self, let s = (r.results as? [VNBarcodeObservation])?.first?.payloadStringValue else { return }
            DispatchQueue.main.async {
                if s == self.lastCode && Date().timeIntervalSince(self.lastTime) < 2 { return }
                self.lastCode = s; self.lastTime = Date()
                self.onCode?(s)
            }
        }
        req.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .right, options: [:]).perform([req])
    }
}
