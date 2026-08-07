import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/broadcast_engine.dart';

class PlaylistTrack {
  final String filePath;
  final String label;

  const PlaylistTrack({required this.filePath, required this.label});

  Map<String, dynamic> toJson() => {'filePath': filePath, 'label': label};

  factory PlaylistTrack.fromJson(Map<String, dynamic> json) => PlaylistTrack(
        filePath: json['filePath'] as String,
        label: json['label'] as String,
      );
}

/// Playlist / Auto DJ screen: a queue of tracks that plays continuously as
/// the background bed, auto-advancing when each track finishes. Distinct
/// from Cart Wall's fire-and-forget single sounds — this is ongoing
/// playback the mic talks over.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  static const _prefsKey = 'playlist_tracks';

  final _engine = BroadcastEngine.instance;
  List<PlaylistTrack> _library = [];
  String? _currentlyPlayingPath;
  List<String> _liveQueue = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
    _engine.currentTrackStream.listen((path) {
      if (mounted) setState(() => _currentlyPlayingPath = path);
    });
    _engine.queueStream.listen((queue) {
      if (mounted) setState(() => _liveQueue = queue);
    });
  }

  Future<void> _loadLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored) as List;
        _library = decoded
            .map((e) => PlaylistTrack.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _library = [];
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_library.map((t) => t.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  Future<void> _addTracks() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null) return;

    setState(() {
      for (final file in result.files) {
        if (file.path == null) continue;
        final label = file.name.contains('.')
            ? file.name.substring(0, file.name.lastIndexOf('.'))
            : file.name;
        _library.add(PlaylistTrack(filePath: file.path!, label: label));
      }
    });
    await _saveLibrary();
  }

  void _removeTrack(int index) {
    setState(() => _library.removeAt(index));
    _saveLibrary();
  }

  void _queueTrack(PlaylistTrack track) {
    if (!_engine.currentStatusIsLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Go live from the Studio screen to play the playlist'),
        ),
      );
      return;
    }
    _engine.queueTrack(track.filePath);
  }

  void _playNow(PlaylistTrack track) {
    if (!_engine.currentStatusIsLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Go live from the Studio screen to play the playlist'),
        ),
      );
      return;
    }
    _engine.playTrack(track.filePath);
  }

  String _labelForPath(String path) {
    final match = _library.where((t) => t.filePath == path);
    if (match.isNotEmpty) return match.first.label;
    return path.split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlist'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add tracks',
            onPressed: _addTracks,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_currentlyPlayingPath != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Row(
                children: [
                  const Icon(Icons.graphic_eq),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Now playing',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(
                          _labelForPath(_currentlyPlayingPath!),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    tooltip: 'Skip',
                    onPressed: () => _engine.skipTrack(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.stop),
                    tooltip: 'Stop',
                    onPressed: () => _engine.pauseTrack(),
                  ),
                ],
              ),
            ),
          if (_liveQueue.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Text(
                'Up next: ${_liveQueue.map(_labelForPath).join(', ')}',
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Expanded(
            child: _library.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No tracks yet. Tap + to add songs for your playlist.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _library.length,
                    itemBuilder: (context, index) {
                      final track = _library[index];
                      final isPlaying = track.filePath == _currentlyPlayingPath;
                      return ListTile(
                        leading: Icon(
                          isPlaying ? Icons.graphic_eq : Icons.music_note,
                          color: isPlaying
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(track.label),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.playlist_add),
                              tooltip: 'Add to queue',
                              onPressed: () => _queueTrack(track),
                            ),
                            IconButton(
                              icon: const Icon(Icons.play_arrow),
                              tooltip: 'Play now',
                              onPressed: () => _playNow(track),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Remove',
                              onPressed: () => _removeTrack(index),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
