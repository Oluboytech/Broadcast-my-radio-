package ng.soccerhub.bcast.audio

import android.util.Base64
import android.util.Log
import java.io.BufferedOutputStream
import java.io.OutputStream
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Opens an Icecast2 source connection and continuously streams encoded audio
 * frames to it. Implements the Icecast "source client" HTTP protocol directly
 * over a raw socket (rather than a full HTTP client library) since the source
 * protocol is a non-standard HTTP verb (SOURCE) with the whole connection kept
 * open indefinitely as a request body — most HTTP client libraries assume a
 * bounded request and don't handle this well.
 *
 * Confirmed against Zeno.fm's own documented setup (they run standard
 * Icecast2 under the hood): server/port/mount/username/password fields map
 * directly, and the mount point MUST be sent with a leading "/".
 */
class IcecastSourceClient(
    private val config: IcecastConnectionConfig,
    private val onStatusChange: (SourceStatus) -> Unit,
    private val onError: (String) -> Unit
) {
    companion object {
        private const val TAG = "IcecastSourceClient"
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val SOCKET_READ_TIMEOUT_MS = 15_000
        private const val MAX_RECONNECT_ATTEMPTS = 5
        private const val RECONNECT_BASE_DELAY_MS = 2000L
    }

    private var socket: Socket? = null
    private var outputStream: OutputStream? = null
    private var streamingThread: Thread? = null

    @Volatile
    private var isConnected = false

    @Volatile
    private var shouldReconnect = true

    private var reconnectAttempts = 0

    // Frames are queued from the encoder thread and drained on the dedicated
    // streaming thread, so a momentary socket write stall never blocks the
    // live mic/mixer/encoder pipeline upstream.
    private val frameQueue = LinkedBlockingQueue<ByteArray>()

    fun connect() {
        shouldReconnect = true
        streamingThread = Thread(::connectionLoop, "IcecastStreamThread").apply { start() }
    }

    fun disconnect() {
        shouldReconnect = false
        frameQueue.clear()
        closeSocket()
        streamingThread?.interrupt()
        streamingThread = null
    }

    /** Called by the encoder's output callback — queues a frame for sending. */
    fun sendFrame(frame: ByteArray) {
        if (!isConnected) return
        frameQueue.offer(frame)
    }

    /** Icecast supports in-band metadata updates via a separate HTTP GET admin call. */
    fun updateMetadata(title: String, artist: String) {
        Thread {
            try {
                sendMetadataUpdate(title, artist)
            } catch (e: Exception) {
                Log.w(TAG, "Metadata update failed (non-fatal)", e)
            }
        }.start()
    }

    private fun connectionLoop() {
        while (shouldReconnect && reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
            try {
                onStatusChange(if (reconnectAttempts == 0) SourceStatus.CONNECTING else SourceStatus.RECONNECTING)
                openConnection()
                reconnectAttempts = 0 // reset backoff after a successful connect
                onStatusChange(SourceStatus.LIVE)
                isConnected = true

                streamFrames() // blocks until disconnected or an error occurs

            } catch (e: Exception) {
                Log.e(TAG, "Icecast connection error", e)
                isConnected = false
                closeSocket()

                if (!shouldReconnect) break

                reconnectAttempts++
                if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
                    onStatusChange(SourceStatus.DISCONNECTED)
                    onError("Lost connection to broadcast server after $MAX_RECONNECT_ATTEMPTS attempts: ${e.message}")
                    break
                }

                // Exponential backoff: 2s, 4s, 8s, 16s, 32s
                val delayMs = RECONNECT_BASE_DELAY_MS * (1L shl (reconnectAttempts - 1))
                try {
                    Thread.sleep(delayMs)
                } catch (ie: InterruptedException) {
                    break
                }
            }
        }
        isConnected = false
    }

    private fun openConnection() {
        val newSocket = Socket()
        newSocket.connect(
            java.net.InetSocketAddress(config.serverAddress, config.port),
            CONNECT_TIMEOUT_MS
        )
        newSocket.soTimeout = SOCKET_READ_TIMEOUT_MS
        socket = newSocket

        val out = BufferedOutputStream(newSocket.getOutputStream())
        outputStream = out

        // Ensure mount point always has the leading slash Zeno.fm's own docs
        // require ("Please add a forward slash '/' at the beginning of your
        // mountpoint when connecting") — normalized here so callers/settings
        // UI don't need to worry about it.
        val mount = if (config.mountPoint.startsWith("/")) config.mountPoint else "/${config.mountPoint}"

        val credentials = "${config.username}:${config.password}"
        val encodedAuth = Base64.encodeToString(credentials.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)

        val contentType = when (config.format) {
            "aac" -> "audio/aac"
            else -> "audio/mpeg"
        }

        // Icecast2 source protocol: SOURCE request method, Basic auth, then
        // the connection stays open with the encoded audio as an unbounded
        // request body — no Content-Length, no chunked encoding, just a raw
        // continuous byte stream until the connection is closed.
        val request = buildString {
            append("SOURCE $mount HTTP/1.0\r\n")
            append("Authorization: Basic $encodedAuth\r\n")
            append("User-Agent: BroadcastMyRadio/0.1\r\n")
            append("Content-Type: $contentType\r\n")
            append("ice-name: ${config.stationName}\r\n")
            append("ice-public: 1\r\n")
            append("ice-bitrate: ${config.bitrateKbps}\r\n")
            append("\r\n")
        }

        out.write(request.toByteArray(Charsets.UTF_8))
        out.flush()

        // Read the server's response line to confirm the SOURCE request was
        // accepted (Icecast replies "HTTP/1.0 200 OK" on success) before
        // treating the connection as live.
        val response = readResponseLine(newSocket)
        if (!response.contains("200")) {
            throw java.io.IOException("Icecast server rejected SOURCE request: $response")
        }
    }

    private fun readResponseLine(socket: Socket): String {
        val input = socket.getInputStream()
        val buffer = StringBuilder()
        var lastByte = -1
        while (true) {
            val byte = input.read()
            if (byte == -1) break
            buffer.append(byte.toChar())
            // Stop at end of the first line (CRLF)
            if (lastByte == '\r'.code && byte == '\n'.code) break
            lastByte = byte
        }
        return buffer.toString().trim()
    }

    private fun streamFrames() {
        val out = outputStream ?: throw java.io.IOException("No output stream")

        while (isConnected && shouldReconnect) {
            val frame = frameQueue.poll(1, TimeUnit.SECONDS) ?: continue
            try {
                out.write(frame)
                out.flush()
            } catch (e: SocketException) {
                throw e // triggers reconnect logic in connectionLoop
            }
        }
    }

    private fun sendMetadataUpdate(title: String, artist: String) {
        // Icecast admin metadata update: a separate short-lived HTTP GET to
        // /admin/metadata, distinct from the long-lived SOURCE connection.
        val songTitle = if (artist.isNotBlank()) "$artist - $title" else title
        val encodedSong = java.net.URLEncoder.encode(songTitle, "UTF-8")
        val mount = if (config.mountPoint.startsWith("/")) config.mountPoint else "/${config.mountPoint}"

        val metaSocket = Socket()
        metaSocket.connect(
            java.net.InetSocketAddress(config.serverAddress, config.port),
            CONNECT_TIMEOUT_MS
        )
        val credentials = "${config.username}:${config.password}"
        val encodedAuth = Base64.encodeToString(credentials.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)

        val request = buildString {
            append("GET /admin/metadata?mount=$mount&mode=updinfo&song=$encodedSong HTTP/1.0\r\n")
            append("Authorization: Basic $encodedAuth\r\n")
            append("\r\n")
        }
        metaSocket.getOutputStream().write(request.toByteArray(Charsets.UTF_8))
        metaSocket.getOutputStream().flush()
        metaSocket.close()
    }

    private fun closeSocket() {
        try {
            outputStream?.close()
        } catch (e: Exception) { /* ignore */ }
        try {
            socket?.close()
        } catch (e: Exception) { /* ignore */ }
        outputStream = null
        socket = null
    }
}

enum class SourceStatus { CONNECTING, LIVE, RECONNECTING, DISCONNECTED }

data class IcecastConnectionConfig(
    val serverAddress: String,
    val port: Int,
    val mountPoint: String,
    val username: String,
    val password: String,
    val format: String, // "mp3" or "aac"
    val bitrateKbps: Int,
    val stationName: String
)
