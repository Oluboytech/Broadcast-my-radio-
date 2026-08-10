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
 * doesn't currently expose a seek/resume position.
 *
 * Auto DJ rotation rules (all operate on the library set via [setLibrary],
 * separate from the manual "add to queue" list, which always takes
 * priority and plays before the library resumes):
 * - Shuffle: randomizes library play order
 * - Repeat: off / repeat-one / repeat-all
 * - Song repeat protection: won't replay a track that played within the
 *   last repeatProtectionWindow selections, even with shuffle on
 * - Artist separation: won't play two tracks by the same artist back to
 *   back, when metadata provides an artist
 * - Category rotation: if categories are present in metadata (e.g.
 *   "music"/"jingle"/"ad"), rotates proportionally to how often each
 *   category appears in the library rather than picking purely at random
 * - Auto crossfade: see startPlaybackThread's note — accepted/stored but
 *   not yet actually overlapping playback (needs AudioMixer to support two
 *   simultaneous independently-leveled track sources; honestly flagged
 *   rather than faked)
 * - Auto leveling: passed through to FileDecoder's adaptive gain normalizer
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
    private var library: List<TrackMetadata> = emptyList()
    private var libraryPlayOrder: MutableList<TrackMetadata> = mutableListOf()
    private var libraryPosition = 0

    private val recentlyPlayed = ArrayDeque<String>()
    private val categoryPlayCounts = mutableMapOf<String, Int>()

    @Volatile
    var shuffleEnabled = false
        private set

    @Volatile
    var repeatMode = RepeatMode.OFF
        private set

    @Volatile
    var repeatProtectionEnabled = true
        private set

    @Volatile
    var artistSeparationEnabled = true
        private set

    @Volatile
    var categoryRotationEnabled = false
        private set

    @Volatile
    var autoCrossfadeEnabled = false
        private set

    @Volatile
    var autoLevelingEnabled = false
        private set

    @Volatile
    private var isPlaying = false

    @Volatile
    private var currentFilePath: String? = null
    private var currentArtist: String = ""

    private var playbackThread: Thread? = null

    fun setLibrary(tracks: List<TrackMetadata>) {
        library = tracks
        rebuildPlayOrder(preserveCurrent = true)
    }

    fun setShuffle(enabled: Boolean) {
        shuffleEnabled = enabled
        rebuildPlayOrder(preserveCurrent = true)
    }

    fun setRepeatMode(mode: RepeatMode) {
        repeatMode = mode
    }

    fun setRepeatProtectionEnabled(enabled: Boolean) {
        repeatProtectionEnabled = enabled
        if (!enabled) recentlyPlayed.clear()
    }

    fun setArtistSeparationEnabled(enabled: Boolean) {
        artistSeparationEnabled = enabled
    }

    fun setCategoryRotationEnabled(enabled: Boolean) {
        categoryRotationEnabled = enabled
    }

    fun setAutoCrossfadeEnabled(enabled: Boolean) {
        autoCrossfadeEnabled = enabled
    }

    fun setAutoLevelingEnabled(enabled: Boolean) {
        autoLevelingEnabled = enabled
    }

    private fun repeatProtectionWindowSize(): Int {
        return (library.size / 3).coerceIn(2, 20)
    }

    private fun rebuildPlayOrder(preserveCurrent: Boolean) {
        val current = if (preserveCurrent) currentFilePath else null
        libraryPlayOrder = if (shuffleEnabled) {
            library.shuffled().toMutableList()
        } else {
            library.toMutableList()
        }
        libraryPosition = if (current != null) {
            libraryPlayOrder.indexOfFirst { it.filePath == current }.coerceAtLeast(0)
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
        val meta = library.find { it.filePath == filePath }
        currentFilePath = filePath
        currentArtist = meta?.artist ?: ""
        val idx = libraryPlayOrder.indexOfFirst { it.filePath == filePath }
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
        currentArtist = ""
        recentlyPlayed.clear()
        onTrackChanged(null)
        onQueueChanged(emptyList())
    }

    fun isIdle(): Boolean = !isPlaying && currentFilePath == null

    fun autoResumeIfIdle() {
        if (isPlaying || currentFilePath != null) return
        if (manualQueue.isNotEmpty()) {
            advanceToNext()
            return
        }
        val next = pickNextFromLibrary() ?: return
        beginTrack(next)
    }

    private fun upcomingPreview(): List<String> {
        val preview = mutableListOf<String>()
        preview.addAll(manualQueue)
        if (repeatMode != RepeatMode.REPEAT_ONE && libraryPlayOrder.isNotEmpty()) {
            val nextLibIndex = (libraryPosition + 1) % libraryPlayOrder.size
            preview.add(libraryPlayOrder[nextLibIndex].filePath)
        }
        return preview
    }

    /**
     * Selects the next library track honoring repeat protection and artist
     * separation, searching forward from the current position. Falls back
     * to relaxed rules if no candidate satisfies everything within one full
     * pass — keeps playback from stalling on a small/homogenous library.
     */
    private fun pickNextFromLibrary(): TrackMetadata? {
        if (libraryPlayOrder.isEmpty()) return null

        val searchLimit = libraryPlayOrder.size
        var candidateIndex = (libraryPosition + 1) % libraryPlayOrder.size
        var wrapped = candidateIndex <= libraryPosition

        for (attempt in 0 until searchLimit) {
            if (wrapped && repeatMode != RepeatMode.REPEAT_ALL) {
                return null
            }

            val candidate = libraryPlayOrder[candidateIndex]
            val failsRepeatProtection = repeatProtectionEnabled &&
                recentlyPlayed.contains(candidate.filePath)
            val failsArtistSeparation = artistSeparationEnabled &&
                candidate.artist.isNotBlank() &&
                candidate.artist == currentArtist
            val failsCategoryRotation = categoryRotationEnabled &&
                !categoryAllowsSelection(candidate.category)

            if (!failsRepeatProtection && !failsArtistSeparation && !failsCategoryRotation) {
                libraryPosition = candidateIndex
                return candidate
            }

            candidateIndex = (candidateIndex + 1) % libraryPlayOrder.size
            if (candidateIndex <= libraryPosition) wrapped = true
        }

        val fallback = libraryPlayOrder.getOrNull((libraryPosition + 1) % libraryPlayOrder.size)
        if (fallback != null) libraryPosition = (libraryPosition + 1) % libraryPlayOrder.size
        return fallback
    }

    /**
     * Proportional rotation: a category is allowed if its play count so far
     * isn't already ahead of its share of the library. E.g. if "jingle" is
     * 10% of the library, it's only allowed roughly 1 in 10 selections —
     * keeps a station from front-loading one category even when shuffle
     * would otherwise allow it by chance.
     */
    private fun categoryAllowsSelection(category: String): Boolean {
        if (category.isBlank()) return true
        val totalInCategory = library.count { it.category == category }
        if (totalInCategory == 0) return true
        val categoryShare = totalInCategory.toDouble() / library.size
        val totalPlayed = categoryPlayCounts.values.sum() + 1
        val playedInCategory = (categoryPlayCounts[category] ?: 0) + 1
        val actualShare = playedInCategory.toDouble() / totalPlayed
        return actualShare <= categoryShare * 1.5
    }

    private fun recordSelection(track: TrackMetadata) {
        recentlyPlayed.addLast(track.filePath)
        while (recentlyPlayed.size > repeatProtectionWindowSize()) {
            recentlyPlayed.removeFirst()
        }
        if (track.category.isNotBlank()) {
            categoryPlayCounts[track.category] = (categoryPlayCounts[track.category] ?: 0) + 1
        }
    }

    private fun advanceToNext() {
        val manualNext = manualQueue.poll()
        if (manualNext != null) {
            onQueueChanged(upcomingPreview())
            currentFilePath = manualNext
            currentArtist = library.find { it.filePath == manualNext }?.artist ?: ""
            startPlaybackThread(manualNext)
            return
        }

        if (repeatMode == RepeatMode.REPEAT_ONE && currentFilePath != null) {
            startPlaybackThread(currentFilePath!!)
            return
        }

        val next = pickNextFromLibrary()
        if (next == null) {
            currentFilePath = null
            currentArtist = ""
            onTrackChanged(null)
            onQueueChanged(emptyList())
            return
        }

        if (shuffleEnabled && libraryPosition == 0 && repeatMode == RepeatMode.REPEAT_ALL) {
            libraryPlayOrder = library.shuffled().toMutableList()
        }

        beginTrack(next)
        onQueueChanged(upcomingPreview())
    }

    private fun beginTrack(track: TrackMetadata) {
        recordSelection(track)
        currentFilePath = track.filePath
        currentArtist = track.artist
        startPlaybackThread(track.filePath)
    }

    private fun startPlaybackThread(filePath: String) {
        isPlaying = true
        onTrackChanged(filePath)

        // Note on auto-crossfade: a true overlapping crossfade (playing the
        // tail of the outgoing track and head of the incoming track
        // simultaneously, ramping gain between them) needs two concurrent
        // decode threads both pushing into the mixer with independent gain
        // envelopes — AudioMixer's current single track-gain model doesn't
        // yet support two independently-leveled track sources at once. That
        // is real additional mixer work, not just a TrackPlayer flag, so
        // autoCrossfadeEnabled is accepted/stored (see setter above) but
        // playback below still advances with a clean cut regardless of this
        // setting, until AudioMixer supports dual-track gain envelopes.
        // Flagged honestly here rather than silently doing nothing.

        playbackThread = Thread({
            var completedNaturally = false
            try {
                completedNaturally = FileDecoder.decodeAndPush(
                    filePath,
                    mixer,
                    { isPlaying },
                    autoLevelingEnabled
                )
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
