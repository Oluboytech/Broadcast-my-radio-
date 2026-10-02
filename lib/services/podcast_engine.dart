import 'package:flutter/services.dart';

class PodcastRecordingState {
  final bool recording;
  final String? filePath;
  final int durationSeconds;
  const PodcastRecordingState({required this.recording, this.filePath, this.durationSeconds = 0});
}

class PodcastEngine {
  PodcastEngine._();
  static final instance = PodcastEngine._();
  static const _method = MethodChannel('ng.soccerhub.bcast/engine');
  static const _channel = EventChannel('ng.soccerhub.bcast/podcast');
  Stream<PodcastRecordingState>? _stream;

  Future<void> startRecording({String title = 'Untitled Episode'}) =>
      _method.invokeMethod('startPodcastRecording', {'title': title});

  Future<void> stopRecording() => _method.invokeMethod('stopPodcastRecording');

  Future<bool> isRecording() async => await _method.invokeMethod<bool>('isPodcastRecording') ?? false;

  Stream<PodcastRecordingState> get stateStream {
    _stream ??= _channel.receiveBroadcastStream().map((event) {
      final m = Map<dynamic, dynamic>.from(event as Map);
      return PodcastRecordingState(
        recording: m['recording'] as bool? ?? false,
        filePath: m['filePath'] as String?,
        durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
      );
    });
    return _stream!;
  }
}
