package ng.soccerhub.bcast.audio

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer

/**
 * Encodes mixed PCM (from AudioMixer) into AAC using Android's built-in
 * MediaCodec — no external native dependencies required, unlike MP3 (which
 * needs a bundled LAME/shine .so via JNI). Zeno.fm's Icecast source accepts
 * AAC directly, so this is a fully supported v1 path.
 *
 * Output is wrapped in ADTS framing (7-byte header per AAC frame), which is
 * what allows the resulting byte stream to be pushed straight to an Icecast
 * mount point as a self-describing AAC stream, the same way a raw MP3 stream
 * is just a sequence of self-describing MP3 frames back to back.
 *
 * MP3 (via a bundled native encoder) can be added later as an alternate
 * format behind the same interface — callers only see PCM in, encoded bytes
 * out, so swapping/adding an encoder implementation shouldn't require
 * touching the mixer or Icecast client.
 */
class StreamEncoder(
    private val sampleRate: Int = AudioCaptureManager.SAMPLE_RATE,
    private val channelCount: Int = 1, // mono, matching AudioCaptureManager
    private val bitrateKbps: Int = 128,
    private val onEncodedFrame: (ByteArray) -> Unit
) {
    companion object {
        private const val TAG = "StreamEncoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_AUDIO_AAC
        private const val TIMEOUT_US = 10_000L
    }

    private var codec: MediaCodec? = null

    @Volatile
    private var isRunning = false

    fun start(): Boolean {
        return try {
            val format = MediaFormat.createAudioFormat(MIME_TYPE, sampleRate, channelCount).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
                // Generous input buffer size — mix() produces buffers on the mic
                // capture cadence (roughly 20-40ms worth of samples at a time),
                // this just needs headroom above that.
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
            }

            val mediaCodec = MediaCodec.createEncoderByType(MIME_TYPE)
            mediaCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            mediaCodec.start()

            codec = mediaCodec
            isRunning = true
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start AAC encoder", e)
            false
        }
    }

    /**
     * Feeds one buffer of mixed PCM shorts into the encoder and drains any
     * ready output frames synchronously. Called repeatedly from the mic
     * capture thread after each mix() call — keeping encode on the same
     * thread as capture avoids an extra handoff/queue and keeps latency low.
     */
    fun encode(pcmBuffer: ShortArray, length: Int) {
        val mediaCodec = codec ?: return
        if (!isRunning) return

        try {
            val inputIndex = mediaCodec.dequeueInputBuffer(TIMEOUT_US)
            if (inputIndex >= 0) {
                val inputBuffer = mediaCodec.getInputBuffer(inputIndex)
                inputBuffer?.clear()

                // Convert shorts to little-endian bytes for the codec input.
                val byteBuffer = ByteBuffer.allocate(length * 2)
                for (i in 0 until length) {
                    val sample = pcmBuffer[i]
                    byteBuffer.put((sample.toInt() and 0xFF).toByte())
                    byteBuffer.put(((sample.toInt() shr 8) and 0xFF).toByte())
                }
                byteBuffer.flip()

                inputBuffer?.put(byteBuffer)
                mediaCodec.queueInputBuffer(inputIndex, 0, length * 2, presentationTimeUs(), 0)
                totalSamplesFed += length
            }

            drainOutput(mediaCodec)
        } catch (e: Exception) {
            Log.e(TAG, "Encode error", e)
        }
    }

    private var totalSamplesFed: Long = 0

    private fun presentationTimeUs(): Long {
        val timeUs = (totalSamplesFed * 1_000_000L) / sampleRate
        return timeUs
    }

    private fun drainOutput(mediaCodec: MediaCodec) {
        val bufferInfo = MediaCodec.BufferInfo()
        while (true) {
            val outputIndex = mediaCodec.dequeueOutputBuffer(bufferInfo, 0)
            if (outputIndex < 0) break

            val outputBuffer = mediaCodec.getOutputBuffer(outputIndex) ?: continue
            if (bufferInfo.size > 0) {
                val aacFrame = ByteArray(bufferInfo.size)
                outputBuffer.position(bufferInfo.offset)
                outputBuffer.get(aacFrame, 0, bufferInfo.size)

                val framed = wrapWithAdtsHeader(aacFrame, bufferInfo.size)
                onEncodedFrame(framed)
            }
            mediaCodec.releaseOutputBuffer(outputIndex, false)
        }
    }

    /**
     * MediaCodec's raw AAC output is "bare" (no framing) — ADTS headers are
     * what make each frame self-describing so an Icecast client/relay can
     * parse the stream without needing an out-of-band container (unlike,
     * say, an MP4 file where framing info lives in a separate moov atom).
     * This is required for a live AAC Icecast source stream to work at all.
     */
    private fun wrapWithAdtsHeader(aacFrame: ByteArray, length: Int): ByteArray {
        val frameLength = length + 7 // 7-byte ADTS header
        val adts = ByteArray(frameLength)

        val profile = 2 // AAC LC
        val freqIdx = sampleRateIndex(sampleRate)
        val chanCfg = channelCount

        adts[0] = 0xFF.toByte()
        adts[1] = 0xF9.toByte() // MPEG-4, no CRC
        adts[2] = (((profile - 1) shl 6) + (freqIdx shl 2) + (chanCfg shr 2)).toByte()
        adts[3] = (((chanCfg and 3) shl 6) + (frameLength shr 11)).toByte()
        adts[4] = ((frameLength and 0x7FF) shr 3).toByte()
        adts[5] = ((((frameLength and 7) shl 5) + 0x1F).toByte())
        adts[6] = 0xFC.toByte()

        System.arraycopy(aacFrame, 0, adts, 7, length)
        return adts
    }

    private fun sampleRateIndex(rate: Int): Int {
        val rates = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
        val idx = rates.indexOf(rate)
        return if (idx >= 0) idx else 4 // default to 44100's index if unmatched
    }

    fun stop() {
        isRunning = false
        codec?.apply {
            try {
                stop()
            } catch (e: IllegalStateException) {
                // already stopped
            }
            release()
        }
        codec = null
        totalSamplesFed = 0
    }
}
