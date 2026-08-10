import 'dart:async';
import 'package:flutter/services.dart';

/// Connection state of the live Icecast stream, as reported by the native engine.
enum StreamStatus { idle, connecting, live, reconnecting, disconnected, error }

/// What the mixer is currently favoring — used for crossfade UI state.
enum MixTarget { mic, track }

class StreamStats {
  final int bitrateKbps;
  final Duration liveDuration;
  final int? listenerCount;

  const StreamStats({
    required this.bitrateKbps,
    required this.liveDuration,
    this.listenerCount,
  });

  factory StreamStats.fromMap(Map<dynamic, dynamic> map) {
    return StreamStats(
      bitrateKbps: map['bitrateKbps'] as int? ?? 0,
      liveDuration: Duration(seconds: map['liveDurationSeconds'] as int? ?? 0),
      listenerCount: map['listenerCount'] as int?,
    );
  }
}

class IcecastConfig {
  final String serverAddress;
  final int port;
  final String mountPoint; // stored WITHOUT leading slash; engine adds it
  final String username;
  final String password;
  final String format; // "aac" (v1 default — no external native deps) or "mp3" (future)
  final int bitrateKbps;
  final String stationName; // fallback metadata when no track is playing

  const IcecastConfig({
    required this.serverAddress,
    required this.port,
    required this.mountPoint,
    required this.username,
    required this.password,
    this.format = 'aac',
    this.bitrateKbps = 128,
    required this.stationName,
  });

  Map<String, dynamic> toMap() => {
        'serverAddress': serverAddress,
        'port': port,
        'mountPoint': mountPoint.startsWith('/') ? mountPoint : '/$mountPoint',
        'username': username,
        'password': password,
        'format': format,
        'bitrateKbps': bitrateKbps,
        'stationName': stationName,
      };
}

/// Single point of contact between Flutter UI and the native Kotlin audio engine.
/// The native side runs as a foreground service and owns mic capture, mixing,
/// encoding, and the Icecast source connection independently of the Flutter UI
/// lifecycle — this class just sends commands and listens for events.
class BroadcastEngine {
  BroadcastEngine._internal() {
    // Subscribe to our own status stream immediately on construction, so
    // currentStatusIsLive is always accurate — previously this only updated
    // when *some* screen happened to be listening to statusStream (e.g.
    // Studio), which meant currentStatusIsLive could silently report stale
    // data if Playlist/Cart Wall were opened without Studio's subscription
    // active first, making play/queue buttons look broken with no error.
    statusStream.listen((_) {});
  }
  static final BroadcastEngine instance = BroadcastEngine._internal();

  static const MethodChannel _methodChannel =
      MethodChannel('ng.soccerhub.bcast/engine');
  static const EventChannel _statusChannel =
      EventChannel('ng.soccerhub.bcast/status');
  static const EventChannel _levelsChannel =
      EventChannel('ng.soccerhub.bcast/levels');
  static const EventChannel _statsChannel =
      EventChannel('ng.soccerhub.bcast/stats');
  static const EventChannel _errorChannel =
      EventChannel('ng.soccerhub.bcast/errors');
  static const EventChannel _cartChannel =
      EventChannel('ng.soccerhub.bcast/cart');
  static const EventChannel _trackChannel =
      EventChannel('ng.soccerhub.bcast/track');
  static const EventChannel _queueChannel =
      EventChannel('ng.soccerhub.bcast/queue');
  static const EventChannel _urlStreamChannel =
      EventChannel('ng.soccerhub.bcast/urlstream');
  static const EventChannel _urlStreamErrorChannel =
      EventChannel('ng.soccerhub.bcast/urlstream_error');
  static const EventChannel _deadAirChannel =
      EventChannel('ng.soccerhub.bcast/deadair');
  static const EventChannel _effectsChannel =
      EventChannel('ng.soccerhub.bcast/effects');

  Stream<StreamStatus>? _statusStream;
  StreamStatus _lastKnownStatus = StreamStatus.idle;
  Stream<({double mic, double track})>? _levelsStream;
  Stream<StreamStats>? _statsStream;
  Stream<String>? _errorStream;
  Stream<String?>? _cartStream;
  Stream<String?>? _trackStream;
  Stream<List<String>>? _queueStream;
  Stream<({bool playing, String? url})>? _urlStreamStateStream;
  Stream<String>? _urlStreamErrorStream;
  Stream<int>? _deadAirStream;
  Stream<({bool echoCancellation, bool noiseSuppression, bool autoGain})>?
      _effectsStream;

  // ---- Commands: Flutter -> Native ----

  Future<void> startStream(IcecastConfig config) =>
      _methodChannel.invokeMethod('startStream', config.toMap());

  Future<void> stopStream() => _methodChannel.invokeMethod('stopStream');

  Future<void> setMicMuted(bool muted) =>
      _methodChannel.invokeMethod('setMicMuted', {'muted': muted});

  Future<void> setMicGain(double gain) =>
      _methodChannel.invokeMethod('setMicGain', {'gain': gain.clamp(0.0, 1.0)});

  Future<void> setTrackGain(double gain) => _methodChannel
      .invokeMethod('setTrackGain', {'gain': gain.clamp(0.0, 1.0)});

  Future<void> crossfade(MixTarget target, {int durationMs = 800}) =>
      _methodChannel.invokeMethod('crossfade', {
        'target': target.name,
        'durationMs': durationMs,
      });

  Future<void> playTrack(String filePath) =>
      _methodChannel.invokeMethod('playTrack', {'filePath': filePath});

  Future<void> pauseTrack() => _methodChannel.invokeMethod('pauseTrack');

  Future<void> skipTrack() => _methodChannel.invokeMethod('skipTrack');

  Future<void> queueTrack(String filePath) =>
      _methodChannel.invokeMethod('queueTrack', {'filePath': filePath});

  /// Sets the full track library Auto DJ draws from for shuffle/repeat-all
  /// and rotation-rule playback, separate from one-off queueTrack() calls.
  /// Each map should have keys 'filePath' (required), 'artist' (optional,
  /// used by artist separation), 'category' (optional, used by category
  /// rotation).
  Future<void> setPlaylistLibrary(List<Map<String, String>> tracks) =>
      _methodChannel.invokeMethod('setPlaylistLibrary', {'tracks': tracks});

  Future<void> setShuffle(bool enabled) =>
      _methodChannel.invokeMethod('setShuffle', {'enabled': enabled});

  /// mode: 'off', 'repeat_one', or 'repeat_all'
  Future<void> setRepeatMode(String mode) =>
      _methodChannel.invokeMethod('setRepeatMode', {'mode': mode});

  /// Won't replay a track that played within the last several selections,
  /// even with shuffle on.
  Future<void> setRepeatProtectionEnabled(bool enabled) => _methodChannel
      .invokeMethod('setRepeatProtectionEnabled', {'enabled': enabled});

  /// Won't play two tracks by the same artist back to back, when artist
  /// metadata is provided in the library.
  Future<void> setArtistSeparationEnabled(bool enabled) => _methodChannel
      .invokeMethod('setArtistSeparationEnabled', {'enabled': enabled});

  /// Rotates proportionally across categories (e.g. music/jingle/ad) rather
  /// than picking uniformly at random, when category metadata is provided.
  Future<void> setCategoryRotationEnabled(bool enabled) => _methodChannel
      .invokeMethod('setCategoryRotationEnabled', {'enabled': enabled});

  /// NOTE: accepted and stored, but track-to-track overlap isn't wired to
  /// real audio yet — the mixer doesn't yet support two simultaneous
  /// independently-leveled track sources. Tracks still advance with a clean
  /// cut regardless of this setting for now.
  Future<void> setAutoCrossfadeEnabled(bool enabled) => _methodChannel
      .invokeMethod('setAutoCrossfadeEnabled', {'enabled': enabled});

  /// Applies a lightweight real-time adaptive gain normalizer to playlist
  /// tracks so quiet and loud tracks don't jar the listener back to back.
  /// Not true LUFS loudness normalization — see FileDecoder's docs.
  Future<void> setAutoLevelingEnabled(bool enabled) => _methodChannel
      .invokeMethod('setAutoLevelingEnabled', {'enabled': enabled});

  /// When enabled, the playlist automatically starts playing if the mic
  /// stays quiet for a few seconds and nothing else is already playing —
  /// the actual "Auto DJ" behavior (fills silence automatically).
  Future<void> setAutoResumeEnabled(bool enabled) => _methodChannel
      .invokeMethod('setAutoResumeEnabled', {'enabled': enabled});

  /// Plays a remote audio stream URL (direct MP3/AAC HTTP(S) stream only —
  /// HLS/.m3u8 isn't supported yet) as the mixer bed. Stops any local
  /// playlist playback first since both share the same mixer track slot.
  Future<void> playUrlStream(String url) =>
      _methodChannel.invokeMethod('playUrlStream', {'url': url});

  Future<void> stopUrlStream() =>
      _methodChannel.invokeMethod('stopUrlStream');

  /// Immediately tears down the entire pipeline with no graceful ramp-down —
  /// for a single unmistakable "kill it now" action distinct from the
  /// normal stop button.
  Future<void> emergencyStop() =>
      _methodChannel.invokeMethod('emergencyStop');

  Future<void> setEchoCancellationEnabled(bool enabled) => _methodChannel
      .invokeMethod('setEchoCancellationEnabled', {'enabled': enabled});

  Future<void> setNoiseSuppressionEnabled(bool enabled) => _methodChannel
      .invokeMethod('setNoiseSuppressionEnabled', {'enabled': enabled});

  Future<void> setAutoGainEnabled(bool enabled) => _methodChannel
      .invokeMethod('setAutoGainEnabled', {'enabled': enabled});

  /// Fire-and-forget instant playback for the cart wall — mixed in immediately
  /// over whatever is currently playing (mic and/or track bed).
  Future<void> playCart(String filePath) =>
      _methodChannel.invokeMethod('playCart', {'filePath': filePath});

  Future<void> updateMetadata({String? title, String? artist}) =>
      _methodChannel.invokeMethod('updateMetadata', {
        'title': title,
        'artist': artist,
      });

  // ---- Events: Native -> Flutter ----

  Stream<StreamStatus> get statusStream {
    _statusStream ??= _statusChannel.receiveBroadcastStream().map((event) {
      final name = event as String;
      final status = StreamStatus.values.firstWhere(
        (s) => s.name == name,
        orElse: () => StreamStatus.error,
      );
      _lastKnownStatus = status;
      return status;
    });
    return _statusStream!;
  }

  /// Best-known live status without needing an active subscription — used
  /// for one-off checks (e.g. "is it worth trying to play a cart right now")
  /// rather than reactive UI updates, which should use [statusStream] instead.
  bool get currentStatusIsLive => _lastKnownStatus == StreamStatus.live;

  Stream<({double mic, double track})> get levelsStream {
    _levelsStream ??= _levelsChannel.receiveBroadcastStream().map((event) {
      final map = event as Map<dynamic, dynamic>;
      return (
        mic: (map['mic'] as num?)?.toDouble() ?? 0.0,
        track: (map['track'] as num?)?.toDouble() ?? 0.0,
      );
    });
    return _levelsStream!;
  }

  Stream<StreamStats> get statsStream {
    _statsStream ??= _statsChannel.receiveBroadcastStream().map(
          (event) => StreamStats.fromMap(event as Map<dynamic, dynamic>),
        );
    return _statsStream!;
  }

  Stream<String> get errorStream {
    _errorStream ??=
        _errorChannel.receiveBroadcastStream().map((event) => event as String);
    return _errorStream!;
  }

  /// Emits the file path of the currently-playing cart, or null when
  /// playback finishes — lets the Cart Wall UI show which slot is active.
  Stream<String?> get cartPlaybackStream {
    _cartStream ??= _cartChannel
        .receiveBroadcastStream()
        .map((event) => event as String?);
    return _cartStream!;
  }

  /// Emits the file path of the currently-playing playlist track, or null
  /// when nothing is playing (queue empty or stopped).
  Stream<String?> get currentTrackStream {
    _trackStream ??= _trackChannel
        .receiveBroadcastStream()
        .map((event) => event as String?);
    return _trackStream!;
  }

  /// Emits the current playlist queue (upcoming tracks, not including
  /// whatever is currently playing) whenever it changes.
  Stream<List<String>> get queueStream {
    _queueStream ??= _queueChannel.receiveBroadcastStream().map(
          (event) => (event as List).cast<String>(),
        );
    return _queueStream!;
  }

  /// Emits whether a remote URL stream is currently playing, and which URL.
  Stream<({bool playing, String? url})> get urlStreamStateStream {
    _urlStreamStateStream ??=
        _urlStreamChannel.receiveBroadcastStream().map((event) {
      final map = event as Map<dynamic, dynamic>;
      return (
        playing: map['playing'] as bool? ?? false,
        url: map['url'] as String?,
      );
    });
    return _urlStreamStateStream!;
  }

  /// Emits a human-readable reason whenever URL stream playback ends
  /// unexpectedly (connection lost, unsupported format like .m3u8, etc.) —
  /// distinct from a normal user-initiated stop.
  Stream<String> get urlStreamErrorStream {
    _urlStreamErrorStream ??= _urlStreamErrorChannel
        .receiveBroadcastStream()
        .map((event) => event as String);
    return _urlStreamErrorStream!;
  }

  /// Emits how many seconds of "dead air" (mic silent AND nothing else
  /// playing) have elapsed, repeating roughly every 5 seconds while it
  /// continues — a warning signal for the UI, independent of whether
  /// auto-resume is enabled.
  Stream<int> get deadAirStream {
    _deadAirStream ??=
        _deadAirChannel.receiveBroadcastStream().map((event) => event as int);
    return _deadAirStream!;
  }

  /// Reports which built-in Android audio effects (echo cancellation, noise
  /// suppression, auto gain) are actually available on this device — varies
  /// by manufacturer, so the UI should reflect real capability rather than
  /// assume everything is always supported.
  Stream<({bool echoCancellation, bool noiseSuppression, bool autoGain})>
      get effectAvailabilityStream {
    _effectsStream ??= _effectsChannel.receiveBroadcastStream().map((event) {
      final map = event as Map<dynamic, dynamic>;
      return (
        echoCancellation: map['echoCancellation'] as bool? ?? false,
        noiseSuppression: map['noiseSuppression'] as bool? ?? false,
        autoGain: map['autoGain'] as bool? ?? false,
      );
    });
    return _effectsStream!;
  }
}
