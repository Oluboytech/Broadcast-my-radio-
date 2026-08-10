package ng.soccerhub.bcast.audio

import android.util.Log

/**
 * Fire-and-forget instant playback for cart wall sounds (jingles, stingers,
 * effects). Only one cart plays at a time — starting a new one stops
 * whatever was playing, matching how physical cart machines and most radio
 * automation software behave for a single cart bank.
 *
 * Decoding is handled by the shared [FileDecoder], which paces PCM delivery
 * to real-time so the mixer's ring buffer never overflows.
 */
class CartPlayer(
    private val mixer: AudioMixer,
    private val onPlaybackComplete: (() -> Unit)? = null
) {
    companion object {
        private const val TAG = "CartPlayer"
    }

    @Volatile
    private var isPlaying = false

    private var playbackThread: Thread? = null

    fun play(filePath: String) {
        stop()

        isPlaying = true
        playbackThread = Thread({
            try {
                FileDecoder.decodeAndPush(filePath, mixer, { isPlaying })
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

    fun isCurrentlyPlaying(): Boolean = isPlaying
}
