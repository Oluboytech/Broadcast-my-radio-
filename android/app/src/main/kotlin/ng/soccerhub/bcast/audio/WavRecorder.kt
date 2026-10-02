package ng.soccerhub.bcast.audio

import java.io.File
import java.io.RandomAccessFile

/** Writes the post-mixer PCM stream to a standard 16-bit little-endian WAV file. */
class WavRecorder(
    private val file: File,
    private val sampleRate: Int = AudioCaptureManager.SAMPLE_RATE,
    private val channels: Int = 1
) {
    private var raf: RandomAccessFile? = null
    private var dataBytes: Long = 0

    @Synchronized
    fun start() {
        file.parentFile?.mkdirs()
        raf = RandomAccessFile(file, "rw").also {
            it.setLength(0)
            writeHeader(it, 0)
        }
        dataBytes = 0
    }

    @Synchronized
    fun write(samples: ShortArray, length: Int) {
        val out = raf ?: return
        if (length <= 0) return
        val bytes = ByteArray(length * 2)
        var j = 0
        for (i in 0 until length) {
            val s = samples[i].toInt()
            bytes[j++] = (s and 0xFF).toByte()
            bytes[j++] = ((s shr 8) and 0xFF).toByte()
        }
        out.write(bytes)
        dataBytes += bytes.size
    }

    @Synchronized
    fun stop(): File? {
        val out = raf ?: return null
        try {
            out.seek(0)
            writeHeader(out, dataBytes)
            out.fd.sync()
        } finally {
            out.close()
            raf = null
        }
        return file
    }

    private fun writeHeader(out: RandomAccessFile, dataSize: Long) {
        val byteRate = sampleRate * channels * 2
        val blockAlign = channels * 2
        out.writeBytes("RIFF")
        writeLeInt(out, (36 + dataSize).coerceAtMost(0xFFFFFFFFL).toInt())
        out.writeBytes("WAVE")
        out.writeBytes("fmt ")
        writeLeInt(out, 16)
        writeLeShort(out, 1)
        writeLeShort(out, channels)
        writeLeInt(out, sampleRate)
        writeLeInt(out, byteRate)
        writeLeShort(out, blockAlign)
        writeLeShort(out, 16)
        out.writeBytes("data")
        writeLeInt(out, dataSize.coerceAtMost(0xFFFFFFFFL).toInt())
    }

    private fun writeLeInt(out: RandomAccessFile, value: Int) {
        out.write(value and 0xFF)
        out.write((value ushr 8) and 0xFF)
        out.write((value ushr 16) and 0xFF)
        out.write((value ushr 24) and 0xFF)
    }

    private fun writeLeShort(out: RandomAccessFile, value: Int) {
        out.write(value and 0xFF)
        out.write((value ushr 8) and 0xFF)
    }
}
