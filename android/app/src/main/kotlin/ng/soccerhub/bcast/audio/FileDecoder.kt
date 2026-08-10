package ng.soccerhub.bcast.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer

/**
 * Shared decode-and-pace logic for turning a local audio file OR a remote
 * audio stream URL into PCM pushed to the mixer in roughly real-time. Used
 * by CartPlayer, TrackPlayer, and UrlStreamPlayer so the MediaCodec
 * plumbing and overflow-prevention pacing only exist in one place.
 *
 * Supports whatever formats/sources Android's MediaExtractor/MediaCodec
 * support natively:
 * - Local files: MP3, AAC, WAV, OGG, FLAC
 * - Remote URLs: direct HTTP(S) MP3/AAC streams (MediaExtractor opens these
 *   as ordinary network data sources)
 *
 * Does NOT support HLS (.m3u8) — that's a playlist format requiring
 * segment-stitching logic MediaExtractor doesn't provide (would need
 * ExoPlayer or similar). Tracked as a follow-up, not yet implemented.
 *
 * Does NOT resample — source audio should already be 44100Hz to match the
 * pipeline's fixed rate; a mismatch plays back with slightly wrong
 * pitch/speed rather than failing, with a log warning to flag it.
 */
object FileDecoder {
    private const val TAG = "FileDecoder"
    private const val TIMEOUT_US = 10_000L

    /**
     * Decodes [source] (a local file path OR an http(s):// URL) and pushes
     * PCM into [mixer], paced to real-time so the mixer's ring buffer never
     * overflows regardless of how fast the CPU decodes. Blocks the calling
     * thread for the duration of playback — callers run this on their own
     * dedicated thread.
     *
     * [shouldContinue] is polled between chunks so callers can interrupt
     * playback early (stop/skip) without waiting for the whole file/stream
     * to finish. Returns true if playback completed naturally (reached end
     * of file — never happens for a genuinely live stream, which only ends
     * via [shouldContinue] returning false), false if stopped early.
     *
     * [autoLevelingEnabled] applies a lightweight adaptive gain normalizer:
     * tracks a running RMS estimate as the file plays and nudges gain toward
     * a target loudness, so a quiet track and a loud track played back to
     * back don't jar the listener. This is NOT true LUFS/EBU R128 loudness
     * normalization (that needs a full-file analysis pass before playback
     * starts, adding latency) — it's a simpler real-time approximation that
     * converges over the first second or two of each track, which is a
     * reasonable tradeoff for a live radio bed track.
     */
    fun decodeAndPush(
        source: String,
        mixer: AudioMixer,
        shouldContinue: () -> Boolean,
        autoLevelingEnabled: Boolean = false
    ): Boolean {
        val extractor = MediaExtractor()
        if (source.startsWith("http://") || source.startsWith("https://")) {
            extractor.setDataSource(source, emptyMap())
        } else {
            extractor.setDataSource(source)
        }

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
            Log.e(TAG, "No audio track found in $source")
            extractor.release()
            return false
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
        var completedNaturally = false

        val playbackStartNanos = System.nanoTime()
        var samplesPushedSoFar = 0L
        val leveler = if (autoLevelingEnabled) AdaptiveLeveler() else null

        try {
            while (!sawOutputEOS && shouldContinue()) {
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
                        leveler?.applyInPlace(pcmChunk)

                        val targetElapsedNanos =
                            (samplesPushedSoFar * 1_000_000_000L) / AudioCaptureManager.SAMPLE_RATE
                        val actualElapsedNanos = System.nanoTime() - playbackStartNanos
                        val waitNanos = targetElapsedNanos - actualElapsedNanos
                        if (waitNanos > 0) {
                            val waitMillis = waitNanos / 1_000_000L
                            val waitRemainderNanos = (waitNanos % 1_000_000L).toInt()
                            Thread.sleep(waitMillis, waitRemainderNanos)
                        }

                        mixer.pushTrackSamples(pcmChunk, pcmChunk.size)
                        samplesPushedSoFar += pcmChunk.size
                    }
                    codec.releaseOutputBuffer(outputIndex, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        sawOutputEOS = true
                        completedNaturally = true
                    }
                }
            }
        } catch (e: InterruptedException) {
            // Stopped/skipped early — not an error, just an interruption.
        } finally {
            codec.stop()
            codec.release()
            extractor.release()
        }

        if (sourceSampleRate != AudioCaptureManager.SAMPLE_RATE) {
            Log.w(
                TAG,
                "File sample rate ($sourceSampleRate Hz) differs from pipeline " +
                    "rate (${AudioCaptureManager.SAMPLE_RATE} Hz) — played back " +
                    "without resampling; pitch/speed may be slightly off."
            )
        }

        return completedNaturally
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

/**
 * Lightweight real-time adaptive gain normalizer — NOT true loudness
 * normalization (LUFS/EBU R128), which requires analyzing the whole file
 * before playback to compute an accurate integrated loudness value. This
 * instead tracks a running RMS estimate as audio streams through and nudges
 * gain toward a target level, converging over roughly the first second or
 * two of a track. Good enough to stop a noticeably-quiet track from feeling
 * jarring next to a noticeably-loud one, without adding pre-scan latency
 * before playback starts — the right tradeoff for a live radio bed track
 * where "starts playing immediately" matters more than perfect precision.
 */
private class AdaptiveLeveler {
    // Target RMS chosen to sit comfortably below clipping headroom while
    // still being a healthy, audible level for a music/voice bed track.
    private val targetRms = 0.15
    private var currentGain = 1.0
    private val maxGain = 4.0 // cap how much a very quiet track can be boosted
    private val minGain = 0.25 // cap how much a very loud track can be cut
    private val adaptRate = 0.08 // how quickly gain converges per chunk (0-1)

    fun applyInPlace(buffer: ShortArray) {
        if (buffer.isEmpty()) return

        var sumSquares = 0.0
        for (sample in buffer) {
            val normalized = sample / 32768.0
            sumSquares += normalized * normalized
        }
        val rms = kotlin.math.sqrt(sumSquares / buffer.size)

        if (rms > 0.0001) { // avoid adjusting gain during near-silence
            val desiredGain = (targetRms / rms).coerceIn(minGain, maxGain)
            currentGain += (desiredGain - currentGain) * adaptRate
        }

        for (i in buffer.indices) {
            val leveled = (buffer[i] * currentGain).toInt()
            buffer[i] = leveled.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
    }
}
