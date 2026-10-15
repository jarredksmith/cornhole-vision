import Vision
import CoreML
import CoreVideo
import CoreGraphics

/// Optional learned detector. Looks for `BagDetector.mlpackage` in the app
/// bundle (produced by training/train.py). If it is missing or fails to load,
/// the app runs on the colour detector alone.
final class CoreMLBagDetector {
    struct Observation {
        let box: CGRect        // Vision-normalized (origin bottom-left)
        let label: String      // bag | bag_in_hole | board | hole
        let confidence: Float
    }

    private let model: VNCoreMLModel
    var minimumConfidence: Float = 0.35

    init?() {
        let candidates = [
            Bundle.main.url(forResource: "BagDetector", withExtension: "mlmodelc"),
            Bundle.main.url(forResource: "BagDetector", withExtension: "mlpackage"),
            Bundle.main.url(forResource: "BagDetector", withExtension: "mlmodel"),
        ].compactMap { $0 }
        guard let url = candidates.first else { return nil }
        do {
            let compiled: URL
            if url.pathExtension == "mlmodelc" {
                compiled = url
            } else {
                compiled = try MLModel.compileModel(at: url)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let ml = try MLModel(contentsOf: compiled, configuration: config)
            model = try VNCoreMLModel(for: ml)
        } catch {
            print("CoreMLBagDetector: failed to load model: \(error)")
            return nil
        }
    }

    func detect(_ pixelBuffer: CVPixelBuffer) -> [Observation] {
        let request = VNCoreMLRequest(model: model)
        // Letterbox like the training pipeline; Vision maps boxes back to the full frame.
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
        var out: [Observation] = []
        for r in results {
            guard let top = r.labels.first, top.confidence >= minimumConfidence else { continue }
            out.append(Observation(box: r.boundingBox, label: top.identifier, confidence: top.confidence))
        }
        return out
    }
}
