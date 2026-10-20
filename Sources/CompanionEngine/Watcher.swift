@preconcurrency import AVFoundation
import CompanionCore
import Foundation
import Vision

/// Where the face should look, gathered from the stereo microphone and the
/// camera and read by the face every frame.
public final class AttentionSense: @unchecked Sendable {
    private let lock = NSLock()
    private var attention = Attention()

    public init() {}

    public func hear(_ bearing: Point, weight: Double = 1, at time: Double = Duplex.now) {
        lock.withLock { attention.hear(bearing, weight: weight, at: time) }
    }

    public func look(at time: Double = Duplex.now) -> Point? {
        lock.withLock { attention.look(at: time) }
    }
}

/// The front camera, watching for who is talking: Vision finds the faces and
/// their lips about ten times a second, and the face whose mouth keeps
/// opening and shutting is the one to look at. Nothing is kept: each picture
/// is looked at and let go.
public final class Watcher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let interval = 0.1
    static let history = 12  // about a second of mouth
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "companion.watcher")
    private let attention: AttentionSense
    /// Faces from the last picture, matched to the next by where they are.
    private var tracks: [SeenFace] = []
    private var last = 0.0
    /// The front camera's picture is the camera's view; as the viewer sees
    /// the screen it is mirrored. On iOS the picture is asked for mirrored.
    private let mirrored: Bool

    public init(attention: AttentionSense) {
        self.attention = attention
        #if os(iOS)
        mirrored = true
        #else
        mirrored = false
        #endif
        super.init()
    }

    public static func permission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// The camera facing the person: built in, never a virtual one.
    static var camera: AVCaptureDevice? {
        #if os(iOS)
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        #else
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.first ?? AVCaptureDevice.default(for: .video)
        #endif
    }

    public func start() throws {
        guard let camera = Self.camera else { throw Problem("There is no camera to watch with.") }
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Problem("The camera can't be used just now.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    public func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Duplex.now
        guard now - last >= Self.interval, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        last = now
        let request = VNDetectFaceLandmarksRequest()
        #if os(iOS)
        let orientation = CGImagePropertyOrientation.leftMirrored  // front camera, phone upright
        #else
        let orientation = CGImagePropertyOrientation.up
        #endif
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([request])
        let seen = (request.results ?? []).map { face -> SeenFace in
            let box = face.boundingBox  // 0...1, origin bottom left
            let x = (box.midX * 2 - 1) * (mirrored ? 1 : -1)
            let y = 1 - box.midY * 2
            var openness = 0.0
            if let lips = face.landmarks?.innerLips?.normalizedPoints, !lips.isEmpty {
                let ys = lips.map { Double($0.y) }
                openness = (ys.max() ?? 0) - (ys.min() ?? 0)
            }
            return SeenFace(position: Point(x, y), size: Double(box.width * box.height), mouth: [openness])
        }
        tracks = seen.map { face in
            // The same face as last time, if one was near enough.
            var face = face
            if let previous = tracks.min(by: { distance($0.position, face.position) < distance($1.position, face.position) }),
               distance(previous.position, face.position) < 0.3 {
                face.mouth = Array((previous.mouth + face.mouth).suffix(Self.history))
            }
            return face
        }
        if let (position, weight) = SeenFace.lookAt(tracks) { attention.hear(position, weight: weight, at: now) }
    }

    private func distance(_ a: Point, _ b: Point) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
}
