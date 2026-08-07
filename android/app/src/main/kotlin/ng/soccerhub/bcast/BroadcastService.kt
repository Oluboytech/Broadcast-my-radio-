package ng.soccerhub.bcast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import ng.soccerhub.bcast.audio.AudioCaptureManager
import ng.soccerhub.bcast.audio.AudioMixer
import ng.soccerhub.bcast.audio.CartPlayer
import ng.soccerhub.bcast.audio.IcecastConnectionConfig
import ng.soccerhub.bcast.audio.IcecastSourceClient
import ng.soccerhub.bcast.audio.MixTarget
import ng.soccerhub.bcast.audio.SourceStatus
import ng.soccerhub.bcast.audio.StreamEncoder
import ng.soccerhub.bcast.audio.TrackPlayer

/**
 * Foreground service that owns the entire live audio pipeline for its lifetime:
 * mic capture -> mixer (mic + track/cart) -> AAC encoder -> Icecast source connection.
 *
 * This survives the Flutter UI backgrounding or the screen locking, because it
 * runs as a proper Android foreground service with a persistent notification,
 * as required for continuous mic + streaming work on modern Android.
 *
 * MainActivity binds to this service (via [LocalBinder]) to forward fine-grained
 * controls (gain, mute, crossfade) and to receive pipeline callbacks that get
 * pushed up to Flutter through the event channels.
 */
class BroadcastService : Service() {

    companion object {
        const val NOTIFICATION_CHANNEL_ID = "broadcast_live_channel"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "ng.soccerhub.bcast.action.START"
        const val ACTION_STOP = "ng.soccerhub.bcast.action.STOP"

        const val EXTRA_SERVER_ADDRESS = "server_address"
        const val EXTRA_PORT = "port"
        const val EXTRA_MOUNT_POINT = "mount_point"
        const val EXTRA_USERNAME = "username"
        const val EXTRA_PASSWORD = "password"
        const val EXTRA_FORMAT = "format"
        const val EXTRA_BITRATE = "bitrate_kbps"
        const val EXTRA_STATION_NAME = "station_name"
    }

    /** Callbacks the service pushes out — MainActivity forwards these to Flutter's event channels. */
    interface PipelineListener {
        fun onStatusChanged(status: String)
        fun onLevels(mic: Float, track: Float)
        fun onStats(bitrateKbps: Int, liveDurationSeconds: Int)
        fun onError(message: String)
        fun onCartPlaybackChanged(filePath: String?)
        fun onTrackChanged(filePath: String?)
        fun onQueueChanged(queue: List<String>)
    }

    inner class LocalBinder : Binder() {
        fun getService(): BroadcastService = this@BroadcastService
    }

    private val binder = LocalBinder()
    var listener: PipelineListener? = null

    private var wakeLock: PowerManager.WakeLock? = null

    @Volatile
    private var isLive = false

    private lateinit var audioCapture: AudioCaptureManager
    private lateinit var mixer: AudioMixer
    private lateinit var encoder: StreamEncoder
    private var sourceClient: IcecastSourceClient? = null
    private var cartPlayer: CartPlayer? = null
    private var trackPlayer: TrackPlayer? = null

    private var liveStartTimeMs: Long = 0
    private var configuredBitrateKbps: Int = 128

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        mixer = AudioMixer()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> intent.let { startBroadcast(it) }
            ACTION_STOP -> stopBroadcast()
        }
        // START_STICKY: if the system kills the service under memory pressure,
        // it will attempt to recreate it. Note this alone does not resume a
        // live stream — the reconnect intent/state restoration would need to
        // be handled explicitly; acceptable gap for v1 given how rare this is
        // with a foreground service holding a wake lock.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder = binder

    // ---- Pipeline control, called from MainActivity's method channel handler ----

    fun setMicMuted(muted: Boolean) {
        if (::audioCapture.isInitialized) audioCapture.setMuted(muted)
    }

    fun setMicGain(gain: Float) {
        if (::audioCapture.isInitialized) audioCapture.setGain(gain)
    }

    fun setTrackGain(gain: Float) {
        if (::mixer.isInitialized) mixer.setTrackGain(gain)
    }

    fun crossfade(target: String, durationMs: Int) {
        if (!::mixer.isInitialized) return
        val mixTarget = if (target == "track") MixTarget.TRACK else MixTarget.MIC
        mixer.crossfadeTo(mixTarget, durationMs)
    }

    fun updateMetadata(title: String?, artist: String?) {
        sourceClient?.updateMetadata(title ?: "", artist ?: "")
    }

    /**
     * Fire-and-forget instant playback for the cart wall — decodes the file
     * and mixes it into the live stream immediately, over whatever else is
     * playing. Only works while a broadcast is live (mixer/pipeline must
     * already be running); silently no-ops otherwise since there's nothing
     * to mix into yet.
     */
    fun playCart(filePath: String) {
        if (!isLive || !::mixer.isInitialized) return
        if (cartPlayer == null) {
            cartPlayer = CartPlayer(
                mixer = mixer,
                onPlaybackComplete = { listener?.onCartPlaybackChanged(null) }
            )
        }
        cartPlayer?.play(filePath)
        listener?.onCartPlaybackChanged(filePath)
    }

    // TODO: playTrack/pauseTrack/skipTrack/queueTrack — playlist/bed playback,
    // distinct from cart wall's fire-and-forget model (needs pause/resume/
    // queue state). CartPlayer's decode loop is reusable for this but the
    // playback semantics differ enough to warrant a separate TrackPlayer
    // component built on the same MediaExtractor/MediaCodec approach.

    private fun ensureTrackPlayer(): TrackPlayer? {
        if (!::mixer.isInitialized) return null
        if (trackPlayer == null) {
            trackPlayer = TrackPlayer(
                mixer = mixer,
                onTrackChanged = { path -> listener?.onTrackChanged(path) },
                onQueueChanged = { queue -> listener?.onQueueChanged(queue) }
            )
        }
        return trackPlayer
    }

    /** Clears the queue and plays this file immediately as the new bed track. */
    fun playTrack(filePath: String) {
        if (!isLive) return
        ensureTrackPlayer()?.play(filePath)
    }

    /**
     * Stops the current track. Note: this does NOT resume from the same
     * position later — see TrackPlayer's class docs for why (no seek/resume
     * support in the current decode pipeline). Calling playTrack/queueTrack
     * again after pause starts fresh.
     */
    fun pauseTrack() {
        trackPlayer?.pause()
    }

    /** Stops the current track and immediately advances to the next queued one. */
    fun skipTrack() {
        trackPlayer?.skip()
    }

    /**
     * Adds a file to the end of the playback queue. If nothing is currently
     * playing, playback starts immediately with this track.
     */
    fun queueTrack(filePath: String) {
        if (!isLive) return
        ensureTrackPlayer()?.queueTrack(filePath)
    }    // ---- Lifecycle ----

    private fun startBroadcast(intent: Intent) {
        if (isLive) return

        val serverAddress = intent.getStringExtra(EXTRA_SERVER_ADDRESS)
        val port = intent.getIntExtra(EXTRA_PORT, 80)
        val mountPoint = intent.getStringExtra(EXTRA_MOUNT_POINT) ?: ""
        val username = intent.getStringExtra(EXTRA_USERNAME) ?: "source"
        val password = intent.getStringExtra(EXTRA_PASSWORD) ?: ""
        val format = intent.getStringExtra(EXTRA_FORMAT) ?: "aac"
        val bitrateKbps = intent.getIntExtra(EXTRA_BITRATE, 128)
        val stationName = intent.getStringExtra(EXTRA_STATION_NAME) ?: "Broadcast My Radio — Live"

        if (serverAddress.isNullOrBlank() || mountPoint.isBlank()) {
            listener?.onError("Broadcast server is not configured. Check Settings.")
            stopSelf()
            return
        }

        configuredBitrateKbps = bitrateKbps

        val notification = buildNotification(status = "Connecting…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        acquireWakeLock()

        val connectionConfig = IcecastConnectionConfig(
            serverAddress = serverAddress,
            port = port,
            mountPoint = mountPoint,
            username = username,
            password = password,
            format = format,
            bitrateKbps = bitrateKbps,
            stationName = stationName
        )

        val client = IcecastSourceClient(
            config = connectionConfig,
            onStatusChange = { status -> handleSourceStatus(status) },
            onError = { message ->
                listener?.onError(message)
                // Source client already tried its own reconnects; if it's
                // giving up, tear the whole pipeline down cleanly rather than
                // leaving mic capture running with nowhere to send audio.
                stopBroadcast()
            }
        )
        sourceClient = client

        encoder = StreamEncoder(
            bitrateKbps = bitrateKbps,
            onEncodedFrame = { frame -> client.sendFrame(frame) }
        )
        if (!encoder.start()) {
            listener?.onError("Failed to start audio encoder")
            stopBroadcast()
            return
        }

        audioCapture = AudioCaptureManager(
            onBuffer = { micBuffer, length ->
                val mixed = mixer.mix(micBuffer, length)
                encoder.encode(mixed, length)
            },
            onLevel = { level ->
                listener?.onLevels(level, 0f) // TODO: track level once TrackPlayer exists
            }
        )
        if (!audioCapture.start()) {
            listener?.onError("Failed to access microphone. Check permissions.")
            stopBroadcast()
            return
        }

        client.connect()
        liveStartTimeMs = System.currentTimeMillis()
        isLive = true

        startStatsTicker()
    }

    private fun handleSourceStatus(status: SourceStatus) {
        val statusName = when (status) {
            SourceStatus.CONNECTING -> "connecting"
            SourceStatus.LIVE -> "live"
            SourceStatus.RECONNECTING -> "reconnecting"
            SourceStatus.DISCONNECTED -> "disconnected"
        }
        listener?.onStatusChanged(statusName)
        updateNotification(
            when (status) {
                SourceStatus.LIVE -> "You are live"
                SourceStatus.CONNECTING -> "Connecting…"
                SourceStatus.RECONNECTING -> "Reconnecting…"
                SourceStatus.DISCONNECTED -> "Disconnected"
            }
        )
    }

    private var statsThread: Thread? = null

    private fun startStatsTicker() {
        statsThread = Thread({
            while (isLive) {
                val durationSeconds = ((System.currentTimeMillis() - liveStartTimeMs) / 1000).toInt()
                listener?.onStats(configuredBitrateKbps, durationSeconds)
                try {
                    Thread.sleep(1000)
                } catch (e: InterruptedException) {
                    break
                }
            }
        }, "StatsTickerThread").apply { start() }
    }

    private fun stopBroadcast() {
        if (!isLive) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        isLive = false
        statsThread?.interrupt()
        statsThread = null

        // Tear down in reverse order of startup: stop pulling audio before
        // stopping the things that produced it, so nothing writes to an
        // already-closed downstream component.
        sourceClient?.disconnect()
        sourceClient = null
        cartPlayer?.stop()
        cartPlayer = null
        trackPlayer?.stop()
        trackPlayer = null
        if (::encoder.isInitialized) encoder.stop()
        if (::audioCapture.isInitialized) audioCapture.stop()
        if (::mixer.isInitialized) mixer.reset()

        listener?.onStatusChanged("idle")
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // ---- Foreground service plumbing ----

    private fun acquireWakeLock() {
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "BroadcastMyRadio::StreamWakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire(12 * 60 * 60 * 1000L /* 12 hour safety cap, not indefinite */)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Live Broadcast",
                NotificationManager.IMPORTANCE_LOW // no sound/vibration for a status notification
            ).apply {
                description = "Shows when Broadcast My Radio is live"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(status: String): Notification {
        val stopIntent = Intent(this, BroadcastService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Broadcast My Radio")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now) // TODO: replace with app icon asset
            .setOngoing(true)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }

    private fun updateNotification(status: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(status))
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
