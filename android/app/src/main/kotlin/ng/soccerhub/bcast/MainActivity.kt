package ng.soccerhub.bcast

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the platform channels that bridge Flutter <-> the native audio engine.
 * Binds to BroadcastService to forward fine-grained controls (gain, mute,
 * crossfade, metadata) and to receive pipeline callbacks, which get pushed
 * to Flutter through the event channel sinks.
 *
 * Channel names must match lib/services/broadcast_engine.dart exactly.
 */
class MainActivity : FlutterActivity() {

    private val methodChannelName = "ng.soccerhub.bcast/engine"
    private val statusChannelName = "ng.soccerhub.bcast/status"
    private val levelsChannelName = "ng.soccerhub.bcast/levels"
    private val statsChannelName = "ng.soccerhub.bcast/stats"
    private val errorChannelName = "ng.soccerhub.bcast/errors"

    private var statusSink: EventChannel.EventSink? = null
    private var levelsSink: EventChannel.EventSink? = null
    private var statsSink: EventChannel.EventSink? = null
    private var errorSink: EventChannel.EventSink? = null

    // Event sinks must only be invoked on the main thread — BroadcastService's
    // callbacks arrive from background audio threads, so all forwarding below
    // is dispatched through this handler.
    private val mainHandler = Handler(Looper.getMainLooper())

    private var broadcastService: BroadcastService? = null
    private var isBound = false

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val localBinder = binder as? BroadcastService.LocalBinder ?: return
            broadcastService = localBinder.getService().also {
                it.listener = pipelineListener
            }
            isBound = true
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            broadcastService = null
            isBound = false
        }
    }

    private val pipelineListener = object : BroadcastService.PipelineListener {
        override fun onStatusChanged(status: String) {
            mainHandler.post { statusSink?.success(status) }
        }

        override fun onLevels(mic: Float, track: Float) {
            mainHandler.post {
                levelsSink?.success(mapOf("mic" to mic, "track" to track))
            }
        }

        override fun onStats(bitrateKbps: Int, liveDurationSeconds: Int) {
            mainHandler.post {
                statsSink?.success(
                    mapOf(
                        "bitrateKbps" to bitrateKbps,
                        "liveDurationSeconds" to liveDurationSeconds
                    )
                )
            }
        }

        override fun onError(message: String) {
            mainHandler.post { errorSink?.success(message) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Bind immediately so gain/mute/crossfade calls work even before the
        // first startStream() — BroadcastService itself is created lazily by
        // startForegroundService, but binding establishes the connection path.
        bindService(
            Intent(this, BroadcastService::class.java),
            serviceConnection,
            Context.BIND_AUTO_CREATE
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startStream" -> {
                        val args = call.arguments as? Map<*, *>
                        val intent = Intent(this, BroadcastService::class.java).apply {
                            action = BroadcastService.ACTION_START
                            putExtra(BroadcastService.EXTRA_SERVER_ADDRESS, args?.get("serverAddress") as? String)
                            putExtra(BroadcastService.EXTRA_PORT, (args?.get("port") as? Int) ?: 80)
                            putExtra(BroadcastService.EXTRA_MOUNT_POINT, args?.get("mountPoint") as? String)
                            putExtra(BroadcastService.EXTRA_USERNAME, args?.get("username") as? String)
                            putExtra(BroadcastService.EXTRA_PASSWORD, args?.get("password") as? String)
                            putExtra(BroadcastService.EXTRA_FORMAT, args?.get("format") as? String)
                            putExtra(BroadcastService.EXTRA_BITRATE, (args?.get("bitrateKbps") as? Int) ?: 128)
                            putExtra(BroadcastService.EXTRA_STATION_NAME, args?.get("stationName") as? String)
                        }
                        startForegroundService(intent)
                        result.success(null)
                    }
                    "stopStream" -> {
                        val intent = Intent(this, BroadcastService::class.java).apply {
                            action = BroadcastService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "setMicMuted" -> {
                        val muted = (call.arguments as? Map<*, *>)?.get("muted") as? Boolean ?: false
                        broadcastService?.setMicMuted(muted)
                        result.success(null)
                    }
                    "setMicGain" -> {
                        val gain = ((call.arguments as? Map<*, *>)?.get("gain") as? Double)?.toFloat() ?: 1.0f
                        broadcastService?.setMicGain(gain)
                        result.success(null)
                    }
                    "setTrackGain" -> {
                        val gain = ((call.arguments as? Map<*, *>)?.get("gain") as? Double)?.toFloat() ?: 1.0f
                        broadcastService?.setTrackGain(gain)
                        result.success(null)
                    }
                    "crossfade" -> {
                        val args = call.arguments as? Map<*, *>
                        val target = args?.get("target") as? String ?: "mic"
                        val durationMs = (args?.get("durationMs") as? Int) ?: 800
                        broadcastService?.crossfade(target, durationMs)
                        result.success(null)
                    }
                    "updateMetadata" -> {
                        val args = call.arguments as? Map<*, *>
                        broadcastService?.updateMetadata(
                            args?.get("title") as? String,
                            args?.get("artist") as? String
                        )
                        result.success(null)
                    }
                    "playTrack", "pauseTrack", "skipTrack", "queueTrack", "playCart" -> {
                        // TODO: not yet implemented — depends on TrackPlayer/CartPlayer,
                        // the next component after the core mic->encoder->Icecast
                        // pipeline is verified working end-to-end.
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, statusChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statusSink = events
                }
                override fun onCancel(arguments: Any?) {
                    statusSink = null
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, levelsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    levelsSink = events
                }
                override fun onCancel(arguments: Any?) {
                    levelsSink = null
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, statsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statsSink = events
                }
                override fun onCancel(arguments: Any?) {
                    statsSink = null
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, errorChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    errorSink = events
                }
                override fun onCancel(arguments: Any?) {
                    errorSink = null
                }
            })
    }

    override fun onDestroy() {
        if (isBound) {
            broadcastService?.listener = null
            unbindService(serviceConnection)
            isBound = false
        }
        super.onDestroy()
    }
}
