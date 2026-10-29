import AVFoundation

/// Пишет микрофон в 16 кГц моно — формат, который ждёт GigaAM.
final class Recorder {
    static let sampleRate = 16_000.0

    /// Уровень громкости 0…1, вызывается из аудиопотока.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Останавливает запись и возвращает накопленный звук.
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        return lock.withLock { samples }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        onLevel?(min(1, rms * 12))
    }

    static func writeWav(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples {
            put(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        try data.write(to: url)
    }
}
