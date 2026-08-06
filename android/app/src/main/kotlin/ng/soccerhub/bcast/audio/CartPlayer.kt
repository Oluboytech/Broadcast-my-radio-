package ng.soccerhub.bcast.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer

/**
 * Decodes a local audio file (jingle/cart sound) to PCM and feeds it into
 * the mixer's track ring buffer for instant playback over the live mix.
 *
 * Supports whatever formats Android's MediaExtractor/MediaCodec support
 * natively (MP3, AAC, WAV, OGG, FLAC) — no bundled codecs needed, matching
 * the same "use what's built in" approach as StreamEncoder.
 *
 * Does NOT resample — source files should already be 44100Hz to match the
 * pipeline's fixed rate; a mismatch plays back with slightly wrong
 * pitch/speed rather than failing, with a log warning to flag it.
 */
class CartPlayer(
    private val mixer: AudioMixer,
    private val onPlaybackComplete: (() -> Unit)? = null
) {
    companion object {
        private const val TAG = "CartPlayer"
        private const val TIMEOUT_US = 10_000L
    }

    @Volatile
    private var isPlaying = false

    private var playbackThread: Thread? = null

    /** Starts decoding and pushing [filePath]'s audio into the mixer. Non-blocking. */
    fun play(filePath: String) {
        stop() // only one cart plays at a time for v1 — simpler mixing model

        isPlaying = true
        playbackThread = Thread({
            try {
                decodeAndPush(filePath)
            } catch (e: Exception) {
                Log.e(TAG, "Cart playback failed for $filePath", e)
            } finally {
                isPlaying = false
                onPlaybackComplete?.invoke()
            }
        }, "CartPlaybackThread").apply { start() }
    }

    fun stop() {
        isPlaying = false
        playbackThread?.interrupt()
        playbackThread = null
    }

    private fun decodeAndPush(filePath: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)

        var audioTrackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val trackFormat = extractor.getTrackFormat(i)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                audioTrackIndex = i
                format = trackFormat
                break
            }
        }

        if (audioTrackIndex < 0 || format == null) {
            Log.e(TAG, "No audio track found in $filePath")
            extractor.release()
            return
        }

        extractor.selectTrack(audioTrackIndex)

        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val sourceSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val sourceChannelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()

        val bufferInfo = MediaCodec.BufferInfo()
        var sawInputEOS = false
        var sawOutputEOS = false

        while (!sawOutputEOS && isPlaying) {
            if (!sawInputEOS) {
                val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inputIndex >= 0) {
                    val inputBuffer = codec.getInputBuffer(inputIndex)!!
                    val sampleSize = extractor.readSampleData(inputBuffer, 0)
                    if (sampleSize < 0) {
                        codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        sawInputEOS = true
                    } else {
                        codec.queueInputBuffer(inputIndex, 0, sampleSize, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            val outputIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
            if (outputIndex >= 0) {
                if (bufferInfo.size > 0) {
                    val outputBuffer = codec.getOutputBuffer(outputIndex)!!
                    val pcmChunk = extractPcmShorts(outputBuffer, bufferInfo, sourceChannelCount)
                    mixer.pushTrackSamples(pcmChunk, pcmChunk.size)
                }
                codec.releaseOutputBuffer(outputIndex, false)
                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    sawOutputEOS = true
                }
            }
        }

        codec.stop()
        codec.release()
        extractor.release()

        if (sourceSampleRate != AudioCaptureManager.SAMPLE_RATE) {
            Log.w(
                TAG,
                "Cart file sample rate ($sourceSampleRate Hz) differs from " +
                    "pipeline rate (${AudioCaptureManager.SAMPLE_RATE} Hz) — " +
                    "played back without resampling; pitch/speed may be slightly off. " +
                    "Re-encode source files to 44100Hz for accurate playback."
            )
        }
    }

    /**
     * Converts a decoded output buffer to mono 16-bit PCM shorts, downmixing
     * stereo sources by averaging channels to match AudioCaptureManager's
     * mono format.
     */
    private fun extractPcmShorts(
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        sourceChannelCount: Int
    ): ShortArray {
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        val shortBuffer: ShortBuffer = buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()

        val totalSamples = shortBuffer.remaining()

        return if (sourceChannelCount == 1) {
            val out = ShortArray(totalSamples)
            shortBuffer.get(out)
            out
        } else {
            val frameCount = totalSamples / sourceChannelCount
            val out = ShortArray(frameCount)
            val frame = ShortArray(sourceChannelCount)
            for (i in 0 until frameCount) {
                shortBuffer.get(frame)
                var sum = 0
                for (s in frame) sum += s
                out[i] = (sum / sourceChannelCount).toShort()
            }
            out
        }
    }
}
