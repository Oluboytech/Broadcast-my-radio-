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
  BroadcastEngine._internal();
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

  Stream<StreamStatus>? _statusStream;
  StreamStatus _lastKnownStatus = StreamStatus.idle;
  Stream<({double mic, double track})>? _levelsStream;
  Stream<StreamStats>? _statsStream;
  Stream<String>? _errorStream;
  Stream<String?>? _cartStream;
  Stream<String?>? _trackStream;
  Stream<List<String>>? _queueStream;

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
}
