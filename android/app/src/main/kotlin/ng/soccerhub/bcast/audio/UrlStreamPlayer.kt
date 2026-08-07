package ng.soccerhub.bcast.audio

import android.util.Log

/**
 * Plays a remote audio stream URL (direct MP3/AAC HTTP(S) stream) as the
 * mixer bed, continuously until stopped. Distinct from TrackPlayer's queue
 * model — a live stream doesn't have a "next track" to auto-advance to; if
 * the connection drops, this reports that back rather than silently retrying
 * forever, so the UI can show a clear "stream disconnected" state.
 *
 * Does NOT support HLS (.m3u8) — see FileDecoder's class docs. Attempting
 * to play an .m3u8 URL fails immediately with a clear error rather than
 * silently doing nothing, since MediaExtractor can't parse playlist formats.
 */
class UrlStreamPlayer(
    private val mixer: AudioMixer,
    private val onStreamStateChanged: (playing: Boolean, url: String?) -> Unit,
    private val onStreamEnded: (reason: String) -> Unit
) {
    companion object {
        private const val TAG = "UrlStreamPlayer"
    }

    @Volatile
    private var isPlaying = false

    private var currentUrl: String? = null
    private var playbackThread: Thread? = null

    fun play(url: String) {
        stop()

        if (url.trim().lowercase().endsWith(".m3u8")) {
            onStreamEnded("HLS (.m3u8) streams aren't supported yet — only direct MP3/AAC stream URLs")
            return
        }

        currentUrl = url
        isPlaying = true
        onStreamStateChanged(true, url)

        playbackThread = Thread({
            var completedNaturally = false
            try {
                completedNaturally = FileDecoder.decodeAndPush(url, mixer) { isPlaying }
            } catch (e: Exception) {
                Log.e(TAG, "URL stream playback failed for $url", e)
                onStreamEnded("Connection to stream lost: ${e.message ?: "unknown error"}")
            } finally {
                val wasPlaying = isPlaying
                isPlaying = false
                onStreamStateChanged(false, null)
                if (completedNaturally && wasPlaying) {
                    onStreamEnded("Stream ended or connection was closed by the server")
                }
            }
        }, "UrlStreamPlaybackThread").apply { start() }
    }

    fun stop() {
        isPlaying = false
        playbackThread?.interrupt()
        playbackThread = null
        currentUrl = null
    }

    fun isCurrentlyPlaying(): Boolean = isPlaying
}
