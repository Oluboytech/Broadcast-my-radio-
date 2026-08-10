import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/broadcast_engine.dart';

class PlaylistTrack {
  final String filePath;
  final String label;
  final String artist;
  final String category;

  const PlaylistTrack({
    required this.filePath,
    required this.label,
    this.artist = '',
    this.category = '',
  });

  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'label': label,
        'artist': artist,
        'category': category,
      };

  factory PlaylistTrack.fromJson(Map<String, dynamic> json) => PlaylistTrack(
        filePath: json['filePath'] as String,
        label: json['label'] as String,
        artist: json['artist'] as String? ?? '',
        category: json['category'] as String? ?? '',
      );

  PlaylistTrack copyWith({String? artist, String? category}) => PlaylistTrack(
        filePath: filePath,
        label: label,
        artist: artist ?? this.artist,
        category: category ?? this.category,
      );
}

/// Playlist / Auto DJ screen: a queue of tracks that plays continuously as
/// the background bed, auto-advancing when each track finishes, with
/// rotation rules (repeat protection, artist separation, category
/// rotation) to keep automated playback feeling like a real station rather
/// than a naive shuffle.
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
  String _repeatMode = 'off';
  bool _autoResumeEnabled = false;
  bool _repeatProtectionEnabled = true;
  bool _artistSeparationEnabled = true;
  bool _categoryRotationEnabled = false;
  bool _autoCrossfadeEnabled = false;
  bool _autoLevelingEnabled = false;

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
    _repeatProtectionEnabled = prefs.getBool('playlist_repeat_protection') ?? true;
    _artistSeparationEnabled = prefs.getBool('playlist_artist_separation') ?? true;
    _categoryRotationEnabled = prefs.getBool('playlist_category_rotation') ?? false;
    _autoCrossfadeEnabled = prefs.getBool('playlist_auto_crossfade') ?? false;
    _autoLevelingEnabled = prefs.getBool('playlist_auto_leveling') ?? false;

    _pushLibraryToNative();
    _engine.setShuffle(_shuffleEnabled);
    _engine.setRepeatMode(_repeatMode);
    _engine.setAutoResumeEnabled(_autoResumeEnabled);
    _engine.setRepeatProtectionEnabled(_repeatProtectionEnabled);
    _engine.setArtistSeparationEnabled(_artistSeparationEnabled);
    _engine.setCategoryRotationEnabled(_categoryRotationEnabled);
    _engine.setAutoCrossfadeEnabled(_autoCrossfadeEnabled);
    _engine.setAutoLevelingEnabled(_autoLevelingEnabled);

    if (mounted) setState(() => _isLoading = false);
  }

  void _pushLibraryToNative() {
    _engine.setPlaylistLibrary(
      _library
          .map((t) => {
                'filePath': t.filePath,
                'artist': t.artist,
                'category': t.category,
              })
          .toList(),
    );
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
    _pushLibraryToNative();
  }

  void _removeTrack(int index) {
    setState(() => _library.removeAt(index));
    _saveLibrary();
    _pushLibraryToNative();
  }

  Future<void> _editTrackMetadata(int index) async {
    final track = _library[index];
    final artistController = TextEditingController(text: track.artist);
    final categoryController = TextEditingController(text: track.category);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(track.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: artistController,
              decoration: const InputDecoration(
                labelText: 'Artist',
                helperText: 'Used for artist separation',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: categoryController,
              decoration: const InputDecoration(
                labelText: 'Category',
                hintText: 'e.g. music, jingle, ad',
                helperText: 'Used for category rotation',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true) {
      setState(() {
        _library[index] = track.copyWith(
          artist: artistController.text.trim(),
          category: categoryController.text.trim(),
        );
      });
      await _saveLibrary();
      _pushLibraryToNative();
    }
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

  Future<void> _toggleSetting(
    String prefsKey,
    bool previousValue,
    void Function(bool) applyToState,
    Future<void> Function(bool) applyToEngine,
  ) async {
    final newValue = !previousValue;
    setState(() => applyToState(newValue));
    await applyToEngine(newValue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, newValue);
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
            icon: const Icon(Icons.tune),
            tooltip: 'Rotation rules',
            onPressed: _showRotationRulesSheet,
          ),
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
                      final subtitleParts = [
                        if (track.artist.isNotEmpty) track.artist,
                        if (track.category.isNotEmpty) track.category,
                      ];
                      return ListTile(
                        leading: Icon(
                          isPlaying ? Icons.graphic_eq : Icons.music_note,
                          color: isPlaying
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(track.label),
                        subtitle: subtitleParts.isNotEmpty
                            ? Text(subtitleParts.join(' • '))
                            : null,
                        onTap: () => _editTrackMetadata(index),
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

  Future<void> _showRotationRulesSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          Widget rotationSwitch({
            required String title,
            required String subtitle,
            required bool value,
            required String prefsKey,
            required void Function(bool) applyToState,
            required Future<void> Function(bool) applyToEngine,
          }) {
            return SwitchListTile(
              title: Text(title),
              subtitle: Text(subtitle),
              value: value,
              onChanged: (v) async {
                await _toggleSetting(prefsKey, value, applyToState, applyToEngine);
                setSheetState(() {});
              },
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Auto DJ rotation rules',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  rotationSwitch(
                    title: 'Song repeat protection',
                    subtitle:
                        'Avoid replaying a recently-played track, even with shuffle on',
                    value: _repeatProtectionEnabled,
                    prefsKey: 'playlist_repeat_protection',
                    applyToState: (v) => _repeatProtectionEnabled = v,
                    applyToEngine: _engine.setRepeatProtectionEnabled,
                  ),
                  rotationSwitch(
                    title: 'Artist separation',
                    subtitle: 'Avoid playing the same artist twice in a row',
                    value: _artistSeparationEnabled,
                    prefsKey: 'playlist_artist_separation',
                    applyToState: (v) => _artistSeparationEnabled = v,
                    applyToEngine: _engine.setArtistSeparationEnabled,
                  ),
                  rotationSwitch(
                    title: 'Category rotation',
                    subtitle:
                        'Rotate music/jingles/ads proportionally, not purely at random. Set a track\'s category by tapping it.',
                    value: _categoryRotationEnabled,
                    prefsKey: 'playlist_category_rotation',
                    applyToState: (v) => _categoryRotationEnabled = v,
                    applyToEngine: _engine.setCategoryRotationEnabled,
                  ),
                  rotationSwitch(
                    title: 'Auto volume leveling',
                    subtitle:
                        'Normalize loudness across tracks so quiet/loud songs don\'t jar listeners',
                    value: _autoLevelingEnabled,
                    prefsKey: 'playlist_auto_leveling',
                    applyToState: (v) => _autoLevelingEnabled = v,
                    applyToEngine: _engine.setAutoLevelingEnabled,
                  ),
                  rotationSwitch(
                    title: 'Auto crossfade',
                    subtitle:
                        'Not yet live — accepted but track transitions still use a clean cut for now',
                    value: _autoCrossfadeEnabled,
                    prefsKey: 'playlist_auto_crossfade',
                    applyToState: (v) => _autoCrossfadeEnabled = v,
                    applyToEngine: _engine.setAutoCrossfadeEnabled,
                  ),
                ],
              ),
            ),
          );
        },
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
