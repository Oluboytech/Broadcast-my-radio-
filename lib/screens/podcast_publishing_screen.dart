import 'package:flutter/material.dart';
import '../models/podcast_publishing.dart';
import '../models/podcast_episode.dart';
import '../services/podcast_publishing_service.dart';

class PodcastPublishingScreen extends StatefulWidget {
  final PodcastEpisode? episode;
  const PodcastPublishingScreen({super.key, this.episode});
  @override
  State<PodcastPublishingScreen> createState() => _PodcastPublishingScreenState();
}

class _PodcastPublishingScreenState extends State<PodcastPublishingScreen> {
  final _service = PodcastPublishingService();
  final _base = TextEditingController();
  final _rss = TextEditingController();
  final _website = TextEditingController();
  final _language = TextEditingController(text: 'en');
  final _copyright = TextEditingController();
  final _apiKey = TextEditingController();
  bool _enabled = false;
  bool _auto = false;
  bool _busy = false;
  Map<String, dynamic> _analytics = {};

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final c = await _service.loadConfig();
    _base.text = c.baseUrl;
    _rss.text = c.rssBaseUrl;
    _website.text = c.defaultWebsite;
    _language.text = c.defaultLanguage;
    _copyright.text = c.copyright;
    _apiKey.text = c.apiKey;
    _enabled = c.enabled;
    _auto = c.autoPublishAfterRecording;
    _analytics = await _service.loadAnalytics(episodeId: widget.episode?.id);
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    await _service.saveConfig(PodcastPublishingConfig(
      enabled: _enabled,
      baseUrl: _base.text.trim(),
      apiKey: _apiKey.text.trim(),
      rssBaseUrl: _rss.text.trim(),
      defaultWebsite: _website.text.trim(),
      defaultLanguage: _language.text.trim().isEmpty ? 'en' : _language.text.trim(),
      copyright: _copyright.text.trim(),
      autoPublishAfterRecording: _auto,
    ));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Podcast publishing settings saved')));
  }

  Future<void> _publish() async {
    final episode = widget.episode;
    if (episode == null) return;
    setState(() => _busy = true);
    try {
      final uploaded = await _service.uploadEpisode(episode);
      await _service.publishEpisode(uploaded);
      await _service.recordLocalAnalytics(event: 'published', episodeId: episode.id);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Episode uploaded and published to the podcast RSS feed')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  void dispose() { for (final c in [_base,_rss,_website,_language,_copyright,_apiKey]) c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    return Scaffold(
      appBar: AppBar(title: const Text('Podcast Publishing Hub')),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('HOSTING & RSS', style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 10),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _enabled, onChanged: (v)=>setState(()=>_enabled=v), title: const Text('Enable automatic podcast publishing')),
          TextField(controller: _base, decoration: const InputDecoration(labelText: 'Publishing API URL', hintText: 'https://podcast.example.com')),
          TextField(controller: _apiKey, obscureText: true, decoration: const InputDecoration(labelText: 'API key / token')),
          TextField(controller: _rss, decoration: const InputDecoration(labelText: 'Public RSS/audio base URL', hintText: 'https://media.example.com')),
          TextField(controller: _website, decoration: const InputDecoration(labelText: 'Podcast website')),
          Row(children: [Expanded(child: TextField(controller: _language, decoration: const InputDecoration(labelText: 'Language'))), const SizedBox(width: 12), Expanded(child: TextField(controller: _copyright, decoration: const InputDecoration(labelText: 'Copyright')))]),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _auto, onChanged: (v)=>setState(()=>_auto=v), title: const Text('Auto-publish after recording')),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('SAVE PUBLISHING SETTINGS')),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('DISTRIBUTION', style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 10),
          _row('Podcast RSS', episode?.distribution['Podcast RSS'] ?? 'Not connected'),
          _row('Apple Podcasts', 'RSS submission / directory'),
          _row('Spotify', 'RSS submission / hosting connection'),
          _row('Amazon Music', 'RSS submission'),
          _row('Other podcast apps', 'RSS compatible'),
          const SizedBox(height: 8),
          Text('Directory distribution is driven by the hosted RSS feed. Provider-specific credentials can be added to the publishing backend without changing the mobile recorder.', style: Theme.of(context).textTheme.bodySmall),
        ]))),
        const SizedBox(height: 12),
        if (episode != null) Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('PUBLISH THIS EPISODE', style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8), Text(episode.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _busy ? null : _publish, icon: const Icon(Icons.cloud_upload), label: Text(_busy ? 'PUBLISHING…' : 'UPLOAD & PUBLISH')),
        ]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ANALYTICS', style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 12),
          Row(children: [Expanded(child: _metric('Streams', '${_analytics['streams'] ?? 0}')), Expanded(child: _metric('Downloads', '${_analytics['downloads'] ?? 0}')), Expanded(child: _metric('Listeners', '${_analytics['listeners'] ?? 0}'))]),
          const SizedBox(height: 8), Text('Live analytics are read from the publishing API when connected; local counters are retained as a fallback.', style: Theme.of(context).textTheme.bodySmall),
        ]))),
      ]),
    );
  }

  Widget _row(String name, String status) => ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.check_circle_outline), title: Text(name), subtitle: Text(status));
  Widget _metric(String label, String value) => Column(children: [Text(value, style: Theme.of(context).textTheme.headlineSmall), Text(label, style: Theme.of(context).textTheme.bodySmall)]);
}
