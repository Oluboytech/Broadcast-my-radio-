import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/podcast_episode.dart';
import '../services/podcast_engine.dart';
import '../services/podcast_service.dart';
import '../services/podcast_publishing_service.dart';
import 'podcast_publishing_screen.dart';

class PodcastStudioScreen extends StatefulWidget {
  const PodcastStudioScreen({super.key});
  @override
  State<PodcastStudioScreen> createState() => _PodcastStudioScreenState();
}

class _PodcastStudioScreenState extends State<PodcastStudioScreen> {
  final _engine = PodcastEngine.instance;
  final _podcasts = PodcastService();
  final _publisher = PodcastPublishingService();
  final _title = TextEditingController(text: 'New Podcast Episode');
  StreamSubscription? _sub;
  bool _recording = false;
  int _seconds = 0;
  String? _activePath;
  List<PodcastEpisode> _episodes = [];

  @override
  void initState() {
    super.initState();
    _load();
    _sub = _engine.stateStream.listen((state) async {
      if (!mounted) return;
      setState(() {
        _recording = state.recording;
        _seconds = state.durationSeconds;
        if (state.filePath != null) _activePath = state.filePath;
      });
      if (!state.recording && state.filePath != null) {
        final ep = PodcastEpisode(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          title: _title.text.trim().isEmpty ? 'Untitled Episode' : _title.text.trim(),
          audioPath: state.filePath!,
          durationSeconds: state.durationSeconds,
        );
        await _podcasts.saveEpisode(ep);
        final config = await _publisher.loadConfig();
        if (config.autoPublishAfterRecording && config.enabled && config.baseUrl.isNotEmpty) {
          try {
            final uploaded = await _publisher.uploadEpisode(ep);
            await _publisher.publishEpisode(uploaded);
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Episode saved, but automatic publishing failed: $e')));
          }
        }
        await _load();
      }
    });
  }

  Future<void> _load() async {
    final items = await _podcasts.loadEpisodes();
    if (mounted) setState(() => _episodes = items);
  }

  Future<void> _toggle() async {
    if (_recording) {
      await _engine.stopRecording();
    } else {
      await _engine.startRecording(title: _title.text.trim().isEmpty ? 'Untitled Episode' : _title.text.trim());
    }
  }

  Future<void> _edit(PodcastEpisode episode) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PodcastEpisodeEditor(episode: episode)));
    _load();
  }

  String _duration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Podcast Studio'), actions: [IconButton(tooltip: 'Publishing Hub', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PodcastPublishingScreen())), icon: const Icon(Icons.cloud_upload_outlined))]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('RECORDING DESK', style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 10),
                  TextField(controller: _title, enabled: !_recording, decoration: const InputDecoration(labelText: 'Episode title', prefixIcon: Icon(Icons.title))),
                  const SizedBox(height: 18),
                  Container(
                    height: 150,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), color: Theme.of(context).colorScheme.surfaceContainerHighest),
                    child: CustomPaint(painter: _WavePainter(active: _recording), child: Center(child: Text(_duration(_seconds), style: Theme.of(context).textTheme.displaySmall))),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: FilledButton.icon(onPressed: _toggle, icon: Icon(_recording ? Icons.stop : Icons.mic), label: Text(_recording ? 'STOP & SAVE EPISODE' : 'START PODCAST RECORDING'))),
                  ]),
                  const SizedBox(height: 8),
                  Text(_recording ? 'Recording the post-mixer audio. You can keep the app in the background.' : 'Podcast recording can run independently or alongside a live broadcast.', style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ),
            const SizedBox(height: 22),
            Row(children: [Text('Episodes', style: Theme.of(context).textTheme.headlineSmall), const Spacer(), Text('${_episodes.length} saved')]),
            const SizedBox(height: 10),
            if (_episodes.isEmpty)
              const Card(child: Padding(padding: EdgeInsets.all(28), child: Column(children: [Icon(Icons.podcasts, size: 52), SizedBox(height: 10), Text('No podcast episodes yet'), Text('Record your first episode above.')]))),
            ..._episodes.map((e) => Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.podcasts)),
                title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${e.showName} • ${_duration(e.durationSeconds)} • ${e.status}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _edit(e),
              ),
            )),
          ],
        ),
      ),
    );
  }
}

class PodcastEpisodeEditor extends StatefulWidget {
  final PodcastEpisode episode;
  const PodcastEpisodeEditor({super.key, required this.episode});
  @override
  State<PodcastEpisodeEditor> createState() => _PodcastEpisodeEditorState();
}

class _PodcastEpisodeEditorState extends State<PodcastEpisodeEditor> {
  late final TextEditingController _title;
  late final TextEditingController _show;
  late final TextEditingController _description;
  late final TextEditingController _host;
  late final TextEditingController _notes;
  late final TextEditingController _chapter;
  late final TextEditingController _chapterTitle;
  late final TextEditingController _season;
  late final TextEditingController _episodeNumber;
  late final TextEditingController _keywords;
  late PodcastEpisode _episode;
  final _service = PodcastService();

  @override
  void initState() {
    super.initState();
    _episode = widget.episode;
    _title = TextEditingController(text: _episode.title);
    _show = TextEditingController(text: _episode.showName);
    _description = TextEditingController(text: _episode.description);
    _host = TextEditingController(text: _episode.host);
    _notes = TextEditingController(text: _episode.notes);
    _chapter = TextEditingController();
    _chapterTitle = TextEditingController();
    _season = TextEditingController(text: '${_episode.season}');
    _episodeNumber = TextEditingController(text: '${_episode.episodeNumber}');
    _keywords = TextEditingController(text: _episode.keywords);
  }

  Future<void> _save({String? status}) async {
    _episode.title = _title.text.trim();
    _episode.showName = _show.text.trim();
    _episode.description = _description.text.trim();
    _episode.host = _host.text.trim();
    _episode.notes = _notes.text.trim();
    _episode.season = int.tryParse(_season.text.trim()) ?? 1;
    _episode.episodeNumber = int.tryParse(_episodeNumber.text.trim()) ?? 1;
    _episode.keywords = _keywords.text.trim();
    if (status != null) _episode.status = status;
    await _service.saveEpisode(_episode);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(status == 'published' ? 'Episode marked ready for publishing' : 'Episode saved')));
    setState(() {});
  }

  Future<void> _addChapter() async {
    final seconds = int.tryParse(_chapter.text.trim());
    if (seconds == null || _chapterTitle.text.trim().isEmpty) return;
    _episode.chapters.add(PodcastChapter(seconds: seconds, title: _chapterTitle.text.trim()));
    _episode.chapters.sort((a, b) => a.seconds.compareTo(b.seconds));
    _chapter.clear();
    _chapterTitle.clear();
    await _save();
  }

  Future<void> _pickAudioAsset(String kind) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = result?.files.single.path;
    if (path == null) return;
    if (kind == 'intro') {
      _episode.introPath = path;
    } else if (kind == 'outro') {
      _episode.outroPath = path;
    } else {
      _episode.adBreakPaths.add(path);
    }
    await _save();
  }

  Future<void> _addEdit(String type) async {
    final start = TextEditingController();
    final end = TextEditingController();
    final label = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: Text('Add $type'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: start, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Start (seconds)')), if (type == 'trim' || type == 'silence') TextField(controller: end, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'End (seconds)')), TextField(controller: label, decoration: const InputDecoration(labelText: 'Label (optional)'))]), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add'))]));
    if (ok != true) return;
    _episode.editOperations.add(PodcastEditOperation(type: type, start: double.tryParse(start.text) ?? 0, end: double.tryParse(end.text) ?? 0, label: label.text.trim().isEmpty ? null : label.text.trim()));
    await _save();
  }

  Future<void> _pickArtwork() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path != null) {
      _episode.artworkPath = path;
      await _save();
    }
  }

  String _duration(int seconds) => '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  void dispose() {
    for (final c in [_title, _show, _description, _host, _notes, _chapter, _chapterTitle, _season, _episodeNumber, _keywords]) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Episode Editor'), actions: [IconButton(onPressed: _pickArtwork, icon: const Icon(Icons.image_outlined)), IconButton(tooltip: 'Publish', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PodcastPublishingScreen(episode: _episode))), icon: const Icon(Icons.cloud_upload_outlined))]),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
          if (_episode.artworkPath != null && File(_episode.artworkPath!).existsSync()) ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(File(_episode.artworkPath!), height: 180, width: double.infinity, fit: BoxFit.cover)),
          TextField(controller: _title, decoration: const InputDecoration(labelText: 'Episode title')),
          TextField(controller: _show, decoration: const InputDecoration(labelText: 'Show / podcast name')),
          TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / author')),
          Row(children: [Expanded(child: TextField(keyboardType: TextInputType.number, controller: _season, decoration: const InputDecoration(labelText: 'Season'))), const SizedBox(width: 12), Expanded(child: TextField(keyboardType: TextInputType.number, controller: _episodeNumber, decoration: const InputDecoration(labelText: 'Episode #')))]),
          TextField(controller: _keywords, decoration: const InputDecoration(labelText: 'Keywords / tags')),
          TextField(controller: _description, maxLines: 5, decoration: const InputDecoration(labelText: 'Description / show notes')),
          TextField(controller: _notes, maxLines: 4, decoration: const InputDecoration(labelText: 'Private production notes')),
          SwitchListTile(value: _episode.explicit, onChanged: (v) => setState(() => _episode.explicit = v), title: const Text('Explicit content')),
          DropdownButtonFormField<String>(value: _episode.episodeType, decoration: const InputDecoration(labelText: 'Episode type'), items: const [DropdownMenuItem(value: 'full', child: Text('Full')), DropdownMenuItem(value: 'trailer', child: Text('Trailer')), DropdownMenuItem(value: 'bonus', child: Text('Bonus'))], onChanged: (v) => setState(() => _episode.episodeType = v ?? 'full')),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Chapters', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Row(children: [Expanded(child: TextField(controller: _chapter, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Seconds'))), const SizedBox(width: 10), Expanded(child: TextField(controller: _chapterTitle, decoration: const InputDecoration(labelText: 'Chapter title'))), IconButton(onPressed: _addChapter, icon: const Icon(Icons.add_circle))]),
          ..._episode.chapters.map((c) => ListTile(dense: true, leading: Text(_duration(c.seconds)), title: Text(c.title))),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Production & automation', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          SwitchListTile(value: _episode.noiseReductionEnabled, onChanged: (v) { setState(() => _episode.noiseReductionEnabled = v); _save(); }, title: const Text('Noise removal'), subtitle: const Text('Apply the cleanup profile when the master is rendered.')),
          if (_episode.noiseReductionEnabled) Slider(value: _episode.noiseReductionStrength, min: 0, max: 1, divisions: 10, label: '${(_episode.noiseReductionStrength * 100).round()}%', onChanged: (v) { setState(() => _episode.noiseReductionStrength = v); _save(); }),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: () => _pickAudioAsset('intro'), icon: const Icon(Icons.play_circle_outline), label: Text(_episode.introPath.isEmpty ? 'Set intro' : 'Change intro')),
            OutlinedButton.icon(onPressed: () => _pickAudioAsset('outro'), icon: const Icon(Icons.stop_circle_outlined), label: Text(_episode.outroPath.isEmpty ? 'Set outro' : 'Change outro')),
            OutlinedButton.icon(onPressed: () => _pickAudioAsset('ad'), icon: const Icon(Icons.campaign_outlined), label: const Text('Insert ad')),
          ]),
          const SizedBox(height: 10),
          Text('Non-destructive edits', style: Theme.of(context).textTheme.titleMedium),
          Wrap(spacing: 8, children: [
            ActionChip(label: const Text('Trim'), onPressed: () => _addEdit('trim')),
            ActionChip(label: const Text('Remove silence'), onPressed: () => _addEdit('silence')),
            ActionChip(label: const Text('Fade'), onPressed: () => _addEdit('fade')),
            ActionChip(label: const Text('Marker'), onPressed: () => _addEdit('marker')),
          ]),
          if (_episode.editOperations.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._episode.editOperations.map((op) => ListTile(dense: true, leading: const Icon(Icons.edit_note), title: Text(op.type), subtitle: Text('${op.start.toStringAsFixed(1)}s → ${op.end.toStringAsFixed(1)}s${op.label == null ? '' : ' • ${op.label}'}'))),
          ],
          if (_episode.adBreakPaths.isNotEmpty) Text('${_episode.adBreakPaths.length} ad asset(s) queued'),
          const Divider(height: 24),
          Text('Master recording', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(_episode.audioPath, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PodcastPublishingScreen(episode: _episode))), icon: const Icon(Icons.cloud_upload), label: const Text('OPEN PUBLISHING HUB')),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: () => _save(status: 'published'), icon: const Icon(Icons.publish), label: const Text('MARK READY TO PUBLISH')),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: () => _save(), icon: const Icon(Icons.save), label: const Text('SAVE DRAFT')),
        ]))),
      ]),
    );
  }
}

class _WavePainter extends CustomPainter {
  final bool active;
  _WavePainter({required this.active});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeWidth = 2..style = PaintingStyle.stroke;
    final mid = size.height / 2;
    final path = Path();
    for (double x = 0; x <= size.width; x += 5) {
      final amp = active ? (8 + (x % 31)) : 7;
      final y = mid + (x % 23 < 11 ? -amp : amp) * ((x / size.width) % 0.18 + 0.82);
      if (x == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) => oldDelegate.active != active;
}
