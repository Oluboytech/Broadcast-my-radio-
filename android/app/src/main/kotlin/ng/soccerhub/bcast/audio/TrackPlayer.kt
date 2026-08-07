package ng.soccerhub.bcast.audio

import android.util.Log
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Manages a playlist queue that plays continuously as the background "bed"
 * track, auto-advancing to the next queued file when one finishes — distinct
 * from CartPlayer's fire-and-forget single-sound model, which needs
 * pause/resume/queue state that a cart doesn't.
 *
 * Note: pause here is implemented as stop-and-resume-from-start, not a true
 * mid-file pause/resume — FileDecoder's MediaExtractor/MediaCodec pipeline
 * doesn't currently expose a seek/resume position. This is a real limitation
 * worth knowing about: pausing and resuming a track restarts it rather than
 * continuing where it left off. Acceptable for v1 (most radio automation
 * workflows skip rather than pause mid-track anyway) but worth revisiting
 * if resume-from-position turns out to matter in practice.
 */
class TrackPlayer(
    private val mixer: AudioMixer,
    private val onTrackChanged: (String?) -> Unit,
    private val onQueueChanged: (List<String>) -> Unit
) {
    companion object {
        private const val TAG = "TrackPlayer"
    }

    private val queue = ConcurrentLinkedQueue<String>()

    @Volatile
    private var isPlaying = false

    @Volatile
    private var currentFilePath: String? = null

    private var playbackThread: Thread? = null

    fun queueTrack(filePath: String) {
        queue.offer(filePath)
        onQueueChanged(queue.toList())
        if (!isPlaying && currentFilePath == null) {
            advanceToNext()
        }
    }

    fun play(filePath: String) {
        queue.clear()
        stopCurrent()
        currentFilePath = filePath
        startPlaybackThread(filePath)
    }

    fun pause() {
        stopCurrent()
    }

    fun skip() {
        stopCurrent()
        advanceToNext()
    }

    fun stop() {
        queue.clear()
        stopCurrent()
        currentFilePath = null
        onTrackChanged(null)
        onQueueChanged(emptyList())
    }

    private fun advanceToNext() {
        val next = queue.poll()
        onQueueChanged(queue.toList())
        if (next == null) {
            currentFilePath = null
            onTrackChanged(null)
            return
        }
        currentFilePath = next
        startPlaybackThread(next)
    }

    private fun startPlaybackThread(filePath: String) {
        isPlaying = true
        onTrackChanged(filePath)

        playbackThread = Thread({
            var completedNaturally = false
            try {
                completedNaturally = FileDecoder.decodeAndPush(filePath, mixer) { isPlaying }
            } catch (e: Exception) {
                Log.e(TAG, "Track playback failed for $filePath", e)
            } finally {
                isPlaying = false
                if (completedNaturally) {
                    advanceToNext()
                }
            }
        }, "TrackPlaybackThread").apply { start() }
    }

    private fun stopCurrent() {
        isPlaying = false
        playbackThread?.interrupt()
        playbackThread = null
    }
}
