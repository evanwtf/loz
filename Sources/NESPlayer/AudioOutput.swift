import Foundation
import AVFoundation
import os
import NESCore

/// Single-producer, single-consumer sample queue between emulation and the
/// audio render thread.
///
/// The emulator fills this on the main actor; CoreAudio drains it on a
/// real-time thread. `OSAllocatedUnfairLock` is the right primitive here — it
/// participates in priority inheritance, so the audio thread cannot be blocked
/// indefinitely by a lower-priority producer, and the critical sections are
/// just memory copies.
final class AudioRingBuffer: @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock()
    private var storage: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    /// Last value emitted, repeated on underrun — abrupt silence clicks.
    private var lastSample: Float = 0

    init(capacity: Int = 16384) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return (writeIndex - readIndex + capacity) % capacity
    }

    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            let next = (writeIndex + 1) % capacity
            // Drop on overflow rather than stall emulation. Dropping a few
            // samples is inaudible; a hitched frame is not.
            if next == readIndex { break }
            storage[writeIndex] = sample
            writeIndex = next
        }
    }

    func read(into destination: UnsafeMutablePointer<Float>, count requested: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<requested {
            if readIndex != writeIndex {
                lastSample = storage[readIndex]
                readIndex = (readIndex + 1) % capacity
            }
            destination[i] = lastSample
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        lastSample = 0
    }
}

/// Plays APU output through AVAudioEngine.
final class AudioOutput {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring = AudioRingBuffer()
    let sampleRate: Double

    private(set) var isRunning = false

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    /// Queues freshly generated samples. Called once per emulated frame.
    func enqueue(_ samples: [Float]) {
        ring.write(samples)
    }

    /// Samples already queued — used to keep emulation and audio in step.
    var bufferedSampleCount: Int { ring.count }

    func start() {
        guard !isRunning else { return }
        configureSession()

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return }

        let node = AVAudioSourceNode(format: format) { [ring] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            guard let first = buffers.first,
                  let pointer = first.mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            ring.read(into: pointer, count: frames)

            // Mono source into a possibly multi-channel bus: copy across.
            for extra in 1..<buffers.count {
                if let destination = buffers[extra].mData {
                    destination.copyMemory(
                        from: pointer, byteCount: frames * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
            isRunning = true
        } catch {
            // Audio failing must never take the game down with it.
            print("audio: engine failed to start — \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        ring.clear()
        isRunning = false
    }

    private func configureSession() {
        #if os(iOS) || os(tvOS)
        do {
            // .ambient respects the ring/silent switch and mixes with other
            // audio, so starting the game never interrupts a podcast.
            try AVAudioSession.sharedInstance().setCategory(
                .ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("audio: session configuration failed — \(error)")
        }
        #endif
    }
}
