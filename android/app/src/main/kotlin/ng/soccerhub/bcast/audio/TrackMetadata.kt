package ng.soccerhub.bcast.audio

/**
 * Metadata for a library track, used by TrackPlayer's rotation logic
 * (artist separation, category-based rotation) — distinct from just a file
 * path, since those rules need to know more about each track than where it
 * lives on disk.
 */
data class TrackMetadata(
    val filePath: String,
    val artist: String = "",
    val category: String = "" // e.g. "music", "jingle", "ad" — used for rotation rules
)
