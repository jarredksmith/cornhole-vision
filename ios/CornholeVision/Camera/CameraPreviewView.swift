import SwiftUI
import AVFoundation

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraManager
    let onLayer: @MainActor (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        camera.attachPreview(layer: view.previewLayer)
        let layer = view.previewLayer
        MainActor.assumeIsolated { onLayer(layer) }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}
