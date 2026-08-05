package ng.soccerhub.bcast.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Wraps AudioRecord to capture mic input on a dedicated thread and hand off
 * PCM buffers to the mixer. Also computes a normalized level (0.0-1.0) per
 * buffer for the Flutter level meter UI.
 *
 * Runs at 44100Hz mono 16-bit PCM — a safe, universally supported format for
 * feeding into either an AAC MediaCodec encoder or a bundled LAME MP3 encoder
 * downstream. Mono halves the mixer/encoder workload vs stereo, which is the
 * right tradeoff for a voice-forward radio broadcast app (music beds can still
 * be mixed in mono without meaningfully hurting perceived quality at 128kbps).
 */
class AudioCaptureManager(
    private val onBuffer: (ShortArray, Int) -> Unit,
    private val onLevel: (Float) -> Unit
) {
    companion object {
        private const val TAG = "AudioCaptureManager"
        const val SAMPLE_RATE = 44100
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null

    @Volatile
    private var isCapturing = false

    @Volatile
    private var isMuted = false

    private var gain: Float = 1.0f // 0.0 - 1.0, applied before handing buffer to mixer

    private val bufferSizeBytes: Int by lazy {
        val minSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        if (minSize == AudioRecord.ERROR || minSize == AudioRecord.ERROR_BAD_VALUE) {
            // Fallback to a conservative 4096-sample buffer if the device query fails
            4096 * 2
        } else {
            // Double the minimum for headroom against scheduling jitter, avoiding
            // underruns that would otherwise cause audible glitches in the stream.
            minSize * 2
        }
    }

    /**
     * Starts capture on a dedicated background thread. Requires RECORD_AUDIO
     * permission to already be granted — caller (BroadcastService) is responsible
     * for checking this before invoking start(), since AudioRecord will silently
     * fail to initialize otherwise.
     *
     * @return true if capture started successfully, false otherwise (caller
     *   should surface this as an error back to Flutter via the error event channel).
     */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (isCapturing) return true

        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                CHANNEL_CONFIG,
                AUDIO_FORMAT,
                bufferSizeBytes
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to construct AudioRecord", e)
            return false
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialize (state=${record.state})")
            record.release()
            return false
        }

        audioRecord = record
        isCapturing = true

        captureThread = Thread(::captureLoop, "MicCaptureThread").apply {
            // Audio threads should run above normal priority to avoid being
            // starved by UI/GC work, which would otherwise cause buffer
            // underruns and audible dropouts in the live stream.
            priority = Thread.MAX_PRIORITY
            start()
        }

        record.startRecording()
        return true
    }

    fun stop() {
        isCapturing = false
        captureThread?.join(500)
        captureThread = null

        audioRecord?.apply {
            try {
                stop()
            } catch (e: IllegalStateException) {
                // already stopped — safe to ignore
            }
            release()
        }
        audioRecord = null
    }

    fun setMuted(muted: Boolean) {
        isMuted = muted
    }

    fun setGain(value: Float) {
        gain = value.coerceIn(0.0f, 1.0f)
    }

    private fun captureLoop() {
        val record = audioRecord ?: return
        val shortsPerBuffer = bufferSizeBytes / 2
        val buffer = ShortArray(shortsPerBuffer)

        while (isCapturing) {
            val samplesRead = record.read(buffer, 0, buffer.size)
            if (samplesRead <= 0) {
                // ERROR_INVALID_OPERATION, ERROR_BAD_VALUE, or ERROR_DEAD_OBJECT.
                // A dead object typically means the mic was taken by another app
                // (e.g. a phone call) — surfacing this as a level of 0 is enough
                // for now; BroadcastService's higher-level error handling covers
                // reconnect/recovery behavior.
                if (samplesRead == AudioRecord.ERROR_DEAD_OBJECT) {
                    Log.w(TAG, "AudioRecord dead object — mic likely taken by another app")
                    isCapturing = false
                }
                continue
            }

            if (isMuted) {
                // Still read from the device to keep the stream timing correct,
                // but zero the buffer so nothing leaks into the mix while muted.
                buffer.fill(0, 0, samplesRead)
                onLevel(0f)
                onBuffer(buffer, samplesRead)
                continue
            }

            applyGain(buffer, samplesRead, gain)
            onLevel(computeLevel(buffer, samplesRead))
            onBuffer(buffer, samplesRead)
        }
    }

    private fun applyGain(buffer: ShortArray, length: Int, gain: Float) {
        if (gain == 1.0f) return
        for (i in 0 until length) {
            buffer[i] = (buffer[i] * gain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
    }

    /** Simple RMS-based level, normalized to roughly 0.0-1.0 for the UI meter. */
    private fun computeLevel(buffer: ShortArray, length: Int): Float {
        if (length == 0) return 0f
        var sumSquares = 0.0
        for (i in 0 until length) {
            val sample = buffer[i] / 32768.0
            sumSquares += sample * sample
        }
        val rms = sqrt(sumSquares / length)
        // RMS of 0.3 is already a healthy, loud voice level — scale so the
        // meter reaches ~1.0 around normal speaking volume rather than only
        // at full-scale digital clipping, which would make the meter look
        // permanently low for typical mic input.
        return (rms * 3.0).coerceIn(0.0, 1.0).toFloat()
    }
}
