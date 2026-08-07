package ng.soccerhub.bcast.audio

import android.util.Log
import java.util.concurrent.ConcurrentLinkedQueue

enum class RepeatMode { OFF, REPEAT_ONE, REPEAT_ALL }

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
 *
 * Shuffle and repeat operate on a full library list (set via [setLibrary]),
 * separate from the manual "add to queue" list — this mirrors how most
 * playlist apps work: the library is what Auto DJ draws from randomly/in
 * order, while explicit queueTrack() calls (e.g. from Cart Wall-style
 * "play next" actions) always take priority and play before the library
 * resumes.
 */
class TrackPlayer(
    private val mixer: AudioMixer,
    private val onTrackChanged: (String?) -> Unit,
    private val onQueueChanged: (List<String>) -> Unit
) {
    companion object {
        private const val TAG = "TrackPlayer"
    }

    private val manualQueue = ConcurrentLinkedQueue<String>()
    private var library: List<String> = emptyList()
    private var libraryPlayOrder: MutableList<String> = mutableListOf()
    private var libraryPosition = 0

    @Volatile
    var shuffleEnabled = false
        private set

    @Volatile
    var repeatMode = RepeatMode.OFF
        private set

    @Volatile
    private var isPlaying = false

    @Volatile
    private var currentFilePath: String? = null

    private var playbackThread: Thread? = null

    /** Sets the full track library Auto DJ draws from for shuffle/repeat-all. */
    fun setLibrary(filePaths: List<String>) {
        library = filePaths
        rebuildPlayOrder(preserveCurrent = true)
    }

    fun setShuffle(enabled: Boolean) {
        shuffleEnabled = enabled
        rebuildPlayOrder(preserveCurrent = true)
    }

    fun setRepeatMode(mode: RepeatMode) {
        repeatMode = mode
    }

    private fun rebuildPlayOrder(preserveCurrent: Boolean) {
        val current = if (preserveCurrent) currentFilePath else null
        libraryPlayOrder = if (shuffleEnabled) {
            library.shuffled().toMutableList()
        } else {
            library.toMutableList()
        }
        libraryPosition = if (current != null) {
            libraryPlayOrder.indexOf(current).coerceAtLeast(0)
        } else {
            0
        }
    }

    fun queueTrack(filePath: String) {
        manualQueue.offer(filePath)
        onQueueChanged(upcomingPreview())
        if (!isPlaying && currentFilePath == null) {
            advanceToNext()
        }
    }

    fun play(filePath: String) {
        manualQueue.clear()
        stopCurrent()
        currentFilePath = filePath
        val idx = libraryPlayOrder.indexOf(filePath)
        if (idx >= 0) libraryPosition = idx
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
        manualQueue.clear()
        stopCurrent()
        currentFilePath = null
        onTrackChanged(null)
        onQueueChanged(emptyList())
    }

    /** True if nothing is currently playing and nothing is queued/library-available. */
    fun isIdle(): Boolean = !isPlaying && currentFilePath == null

    /**
     * Starts Auto DJ playback from the library if nothing is currently
     * playing — used for auto-resume when the mic goes quiet. No-ops if
     * already playing (won't interrupt a manually-started track) or if the
     * library is empty (nothing to play).
     */
    fun autoResumeIfIdle() {
        if (isPlaying || currentFilePath != null) return
        if (manualQueue.isNotEmpty()) {
            advanceToNext()
            return
        }
        if (libraryPlayOrder.isEmpty()) return
        val next = libraryPlayOrder.getOrNull(libraryPosition) ?: return
        currentFilePath = next
        startPlaybackThread(next)
    }

    private fun upcomingPreview(): List<String> {
        val preview = mutableListOf<String>()
        preview.addAll(manualQueue)
        if (repeatMode != RepeatMode.REPEAT_ONE && libraryPlayOrder.isNotEmpty()) {
            val nextLibIndex = (libraryPosition + 1) % libraryPlayOrder.size
            preview.add(libraryPlayOrder[nextLibIndex])
        }
        return preview
    }

    private fun advanceToNext() {
        // Manual queue always takes priority over the library/Auto DJ order.
        val manualNext = manualQueue.poll()
        if (manualNext != null) {
            onQueueChanged(upcomingPreview())
            currentFilePath = manualNext
            startPlaybackThread(manualNext)
            return
        }

        if (repeatMode == RepeatMode.REPEAT_ONE && currentFilePath != null) {
            // Replay the same track rather than advancing.
            val same = currentFilePath!!
            startPlaybackThread(same)
            return
        }

        if (libraryPlayOrder.isEmpty()) {
            currentFilePath = null
            onTrackChanged(null)
            onQueueChanged(emptyList())
            return
        }

        libraryPosition++
        if (libraryPosition >= libraryPlayOrder.size) {
            if (repeatMode == RepeatMode.REPEAT_ALL) {
                libraryPosition = 0
                if (shuffleEnabled) {
                    // Reshuffle each time we loop back to the start, so
                    // repeat-all + shuffle doesn't replay the exact same
                    // order every cycle.
                    libraryPlayOrder = library.shuffled().toMutableList()
                }
            } else {
                // Reached the end with repeat off — stop rather than loop.
                currentFilePath = null
                onTrackChanged(null)
                onQueueChanged(emptyList())
                return
            }
        }

        val next = libraryPlayOrder[libraryPosition]
        currentFilePath = next
        startPlaybackThread(next)
        onQueueChanged(upcomingPreview())
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
