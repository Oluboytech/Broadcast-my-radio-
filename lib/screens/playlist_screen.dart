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
  bool _shuffleEnabled = false;
  String _repeatMode = 'off'; // 'off', 'repeat_one', 'repeat_all'
  bool _autoResumeEnabled = false;
  bool _urlStreamPlaying = false;
  String? _urlStreamUrl;

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
    _engine.urlStreamStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _urlStreamPlaying = state.playing;
          _urlStreamUrl = state.url;
        });
      }
    });
    _engine.urlStreamErrorStream.listen((reason) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(reason)));
      }
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
    _shuffleEnabled = prefs.getBool('playlist_shuffle') ?? false;
    _repeatMode = prefs.getString('playlist_repeat_mode') ?? 'off';
    _autoResumeEnabled = prefs.getBool('playlist_auto_resume') ?? false;

    // Push current state to the native side so it's in sync even if this
    // is the first time the playlist screen is opened this session.
    _engine.setPlaylistLibrary(_library.map((t) => t.filePath).toList());
    _engine.setShuffle(_shuffleEnabled);
    _engine.setRepeatMode(_repeatMode);
    _engine.setAutoResumeEnabled(_autoResumeEnabled);

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
    _engine.setPlaylistLibrary(_library.map((t) => t.filePath).toList());
  }

  void _removeTrack(int index) {
    setState(() => _library.removeAt(index));
    _saveLibrary();
    _engine.setPlaylistLibrary(_library.map((t) => t.filePath).toList());
  }

  Future<void> _toggleShuffle() async {
    setState(() => _shuffleEnabled = !_shuffleEnabled);
    _engine.setShuffle(_shuffleEnabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('playlist_shuffle', _shuffleEnabled);
  }

  Future<void> _cycleRepeatMode() async {
    final next = switch (_repeatMode) {
      'off' => 'repeat_all',
      'repeat_all' => 'repeat_one',
      _ => 'off',
    };
    setState(() => _repeatMode = next);
    _engine.setRepeatMode(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('playlist_repeat_mode', next);
  }

  Future<void> _toggleAutoResume() async {
    setState(() => _autoResumeEnabled = !_autoResumeEnabled);
    _engine.setAutoResumeEnabled(_autoResumeEnabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('playlist_auto_resume', _autoResumeEnabled);
  }

  IconData get _repeatIcon => switch (_repeatMode) {
        'repeat_one' => Icons.repeat_one,
        'repeat_all' => Icons.repeat,
        _ => Icons.repeat,
      };

  String get _repeatTooltip => switch (_repeatMode) {
        'repeat_one' => 'Repeat: one track',
        'repeat_all' => 'Repeat: all tracks',
        _ => 'Repeat: off',
      };

  Future<void> _showPlayFromUrlDialog() async {
    if (!_engine.currentStatusIsLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Go live from the Studio screen to play a stream URL'),
        ),
      );
      return;
    }

    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Play from URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'https://stream.example.com/live.mp3',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Direct MP3/AAC stream URLs only — HLS (.m3u8) isn\'t supported yet.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Play'),
          ),
        ],
      ),
    );

    if (url == null || url.isEmpty) return;

    if (url.toLowerCase().endsWith('.m3u8')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'HLS (.m3u8) streams aren\'t supported yet — only direct MP3/AAC URLs',
            ),
          ),
        );
      }
      return;
    }

    _engine.playUrlStream(url);
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
            icon: const Icon(Icons.link),
            tooltip: 'Play from URL',
            onPressed: _showPlayFromUrlDialog,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add tracks',
            onPressed: _addTracks,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ControlChip(
                  icon: Icons.shuffle,
                  label: 'Shuffle',
                  active: _shuffleEnabled,
                  onTap: _toggleShuffle,
                ),
                _ControlChip(
                  icon: _repeatIcon,
                  label: _repeatMode == 'off'
                      ? 'Repeat'
                      : _repeatTooltip.replaceFirst('Repeat: ', ''),
                  active: _repeatMode != 'off',
                  onTap: _cycleRepeatMode,
                ),
                _ControlChip(
                  icon: Icons.auto_mode,
                  label: 'Auto DJ',
                  active: _autoResumeEnabled,
                  onTap: _toggleAutoResume,
                ),
              ],
            ),
          ),
          if (_urlStreamPlaying)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Row(
                children: [
                  const Icon(Icons.podcasts),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Playing from URL',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(
                          _urlStreamUrl ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.stop),
                    tooltip: 'Stop stream',
                    onPressed: () => _engine.stopUrlStream(),
                  ),
                ],
              ),
            ),
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

class _ControlChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ControlChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
