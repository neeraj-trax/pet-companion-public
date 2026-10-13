import AVFoundation
import CoreAudio

/// "Listening": true while the user is actually speaking into the microphone.
/// Only listens while some other app already has the mic open (a call, a recording), so the pet never
/// turns the mic on by itself. Needs Microphone permission once; macOS asks the first time a call starts.
final class MicWatcher {
    private(set) var speaking = false
    private(set) var level: Float = 0            // smoothed RMS, 0…1-ish
    private var engine: AVAudioEngine?
    private var noiseFloor: Float = 0.004
    private var speakingSince: TimeInterval = 0
    private var quietSince: TimeInterval = 0
    private var checkTimer: Timer?
    private var denied = false
    private var pausedForCheck = false

    init() {
        checkTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(checkTimer!, forMode: .common)
    }

    /// Is any process (other than us) using the default input device?
    private func micInUseElsewhere() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private func check() {
        if engine == nil {
            if !denied && micInUseElsewhere() { start() }
            return
        }
        // we are running too, so "running somewhere" is always true; pause briefly now and then to re-check
        if !pausedForCheck {
            pausedForCheck = true
            engine?.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                if self.micInUseElsewhere() { try? self.engine?.start() } else { self.stop() }
                self.pausedForCheck = false
            }
        }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async { if ok { self?.startEngine() } else { self?.denied = true } }
            }
        default: denied = true
        }
    }

    private func startEngine() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(n))
            DispatchQueue.main.async { self.ingest(rms) }
        }
        do { try e.start(); engine = e } catch { engine = nil }
    }

    private func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        speaking = false
        level = 0
    }

    private func ingest(_ rms: Float) {
        level += (rms - level) * 0.35
        // adaptive noise floor: follows quiet levels slowly, never rises quickly
        if rms < noiseFloor * 1.5 { noiseFloor += (rms - noiseFloor) * 0.05 } else { noiseFloor += (rms - noiseFloor) * 0.002 }
        noiseFloor = max(0.0015, noiseFloor)
        let now = CACurrentMediaTime()
        let loud = level > max(noiseFloor * 3.5, 0.012)
        if loud {
            quietSince = 0
            if speakingSince == 0 { speakingSince = now }
            if now - speakingSince > 0.15 { speaking = true }
        } else {
            speakingSince = 0
            if quietSince == 0 { quietSince = now }
            if now - quietSince > 0.6 { speaking = false }
        }
    }
}
