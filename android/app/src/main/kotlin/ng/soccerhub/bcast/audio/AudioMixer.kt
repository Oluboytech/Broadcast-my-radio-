package ng.soccerhub.bcast.audio

import kotlin.math.max
import kotlin.math.min

/**
 * Combines mic PCM and track/cart PCM into a single mixed buffer for the
 * encoder. Mic audio arrives continuously from AudioCaptureManager's capture
 * thread; track/cart audio is pushed in by whatever is currently playing
 * (TrackPlayer for the playlist bed, or a fire-and-forget cart sound).
 *
 * Threading note: mix() is called from the mic capture thread (since mic
 * timing drives the overall stream cadence) and pulls the latest available
 * track samples via a lock-free ring buffer rather than blocking on playback
 * timing — this keeps mic latency low and avoids stalling the stream if
 * track playback is momentarily behind.
 */
class AudioMixer {

    private var micGain: Float = 1.0f
    private var trackGain: Float = 1.0f

    // Crossfade state: when active, gains ramp linearly toward target values
    // over crossfadeRemainingSamples, recalculated each mix() call.
    @Volatile
    private var crossfadeTargetMicGain: Float? = null
    @Volatile
    private var crossfadeTargetTrackGain: Float? = null
    private var crossfadeStepMic: Float = 0f
    private var crossfadeStepTrack: Float = 0f
    private var crossfadeSamplesRemaining: Int = 0

    // Track/cart audio ring buffer — written by TrackPlayer/CartPlayer on their
    // own decode thread(s), read here on the mic thread during mix().
    private val trackRing = PcmRingBuffer(capacitySamples = AudioCaptureManager.SAMPLE_RATE * 2)

    fun setMicGain(value: Float) {
        micGain = value.coerceIn(0.0f, 1.0f)
    }

    fun setTrackGain(value: Float) {
        trackGain = value.coerceIn(0.0f, 1.0f)
    }

    /**
     * Smoothly ramps mic/track gains toward a crossfade target over
     * [durationMs]. target "mic" fades mic toward 1.0 and track toward a
     * lowered bed level (0.25) rather than fully silencing it, so a track can
     * still be heard faintly under the mic — standard radio ducking behavior.
     * target "track" fades the opposite direction, mic lowered to a
     * background level rather than fully cut, in case of a hot mic moment.
     */
    fun crossfadeTo(target: MixTarget, durationMs: Int) {
        val (targetMic, targetTrack) = when (target) {
            MixTarget.MIC -> 1.0f to 0.25f
            MixTarget.TRACK -> 0.15f to 1.0f
        }
        val totalSamples = (AudioCaptureManager.SAMPLE_RATE * (durationMs / 1000.0)).toInt().coerceAtLeast(1)

        crossfadeTargetMicGain = targetMic
        crossfadeTargetTrackGain = targetTrack
        crossfadeStepMic = (targetMic - micGain) / totalSamples
        crossfadeStepTrack = (targetTrack - trackGain) / totalSamples
        crossfadeSamplesRemaining = totalSamples
    }

    /** Called by track/cart playback to feed decoded PCM into the mix. */
    fun pushTrackSamples(samples: ShortArray, length: Int) {
        trackRing.write(samples, length)
    }

    /**
     * Mixes [micBuffer] (already gain-adjusted and level-metered by the
     * caller — AudioCaptureManager applies mic gain upstream) with the
     * currently buffered track/cart audio, sample-for-sample, clamping to
     * avoid integer overflow/clipping artifacts.
     *
     * Returns a new buffer of the same length as micBuffer — this is what
     * gets handed to the encoder.
     */
    fun mix(micBuffer: ShortArray, length: Int): ShortArray {
        val trackBuffer = ShortArray(length)
        trackRing.read(trackBuffer, length) // zero-fills if underrun (no track playing)

        val output = ShortArray(length)
        for (i in 0 until length) {
            if (crossfadeSamplesRemaining > 0) {
                micGain += crossfadeStepMic
                trackGain += crossfadeStepTrack
                crossfadeSamplesRemaining--
                if (crossfadeSamplesRemaining == 0) {
                    // Snap exactly to target to avoid float drift leaving gain
                    // slightly off from the intended crossfade endpoint.
                    crossfadeTargetMicGain?.let { micGain = it }
                    crossfadeTargetTrackGain?.let { trackGain = it }
                }
            }

            val micSample = (micBuffer[i] * micGain).toInt()
            val trackSample = (trackBuffer[i] * trackGain).toInt()
            val mixed = micSample + trackSample

            output[i] = mixed.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        return output
    }

    fun reset() {
        trackRing.clear()
    }
}

enum class MixTarget { MIC, TRACK }

/**
 * Minimal single-producer/single-consumer ring buffer for track/cart PCM.
 * Not a general-purpose queue — sized generously (2 seconds of audio) so a
 * momentary decode stall doesn't underrun mid-word, and read() zero-fills
 * on underrun rather than blocking, since the mic thread must never stall
 * waiting on track playback.
 */
private class PcmRingBuffer(private val capacitySamples: Int) {
    private val buffer = ShortArray(capacitySamples)
    private var writeIndex = 0
    private var readIndex = 0
    private var available = 0
    private val lock = Any()

    fun write(samples: ShortArray, length: Int) {
        synchronized(lock) {
            val writable = min(length, capacitySamples - available)
            for (i in 0 until writable) {
                buffer[writeIndex] = samples[i]
                writeIndex = (writeIndex + 1) % capacitySamples
            }
            available = min(available + writable, capacitySamples)
        }
    }

    fun read(out: ShortArray, length: Int) {
        synchronized(lock) {
            val readable = min(length, available)
            for (i in 0 until readable) {
                out[i] = buffer[readIndex]
                readIndex = (readIndex + 1) % capacitySamples
            }
            // Zero-fill any remainder (underrun — no track audio available)
            for (i in readable until length) {
                out[i] = 0
            }
            available = max(0, available - readable)
        }
    }

    fun clear() {
        synchronized(lock) {
            writeIndex = 0
            readIndex = 0
            available = 0
        }
    }
}
