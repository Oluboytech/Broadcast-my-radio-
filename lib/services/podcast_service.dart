import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/podcast_episode.dart';

class PodcastService {
  static const _key = 'podcast_episodes_v1';

  Future<List<PodcastEpisode>> loadEpisodes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => PodcastEpisode.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => File(e.audioPath).existsSync())
          .toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveEpisode(PodcastEpisode episode) async {
    final episodes = await loadEpisodes();
    final index = episodes.indexWhere((e) => e.id == episode.id);
    if (index >= 0) {
      episodes[index] = episode;
    } else {
      episodes.insert(0, episode);
    }
    await _save(episodes);
  }

  Future<void> deleteEpisode(PodcastEpisode episode) async {
    final episodes = await loadEpisodes();
    episodes.removeWhere((e) => e.id == episode.id);
    await _save(episodes);
    final file = File(episode.audioPath);
    if (file.existsSync()) await file.delete();
  }

  Future<File> generateRssFeed({required String baseUrl}) async {
    final episodes = await loadEpisodes();
    final show = episodes.isNotEmpty ? episodes.first.showName : 'My Podcast';
    final cleanBase = baseUrl.replaceAll(RegExp(r'/$'), '');
    final published = episodes.where((e) => e.status == 'published' || e.status == 'scheduled' || e.status == 'uploaded').toList();
    final items = published.map((e) {
      final filename = File(e.audioPath).uri.pathSegments.last;
      final enclosureUrl = '$cleanBase/episodes/${Uri.encodeComponent(filename)}';
      final ext = filename.toLowerCase().split('.').last;
      final mime = ext == 'mp3' ? 'audio/mpeg' : ext == 'm4a' ? 'audio/mp4' : ext == 'aac' ? 'audio/aac' : 'audio/wav';
      final length = File(e.audioPath).existsSync() ? File(e.audioPath).lengthSync() : 0;
      final chapters = e.chapters.isEmpty ? '' : '<psc:chapters>${e.chapters.map((c) => '<psc:chapter start="${_formatChapter(c.seconds)}" title="${_xml(c.title)}"/>').join()}</psc:chapters>';
      return """<item>
<title>${_xml(e.title)}</title>
<description>${_xml(e.description)}</description>
<guid isPermaLink="false">broadcastng-${_xml(e.id)}</guid>
<pubDate>${(e.publishAt ?? e.createdAt).toUtc().toRfc822()}</pubDate>
<enclosure url="${_xml(enclosureUrl)}" length="$length" type="$mime" />
<itunes:author>${_xml(e.host)}</itunes:author>
<itunes:summary>${_xml(e.description)}</itunes:summary>
<itunes:episode>${e.episodeNumber}</itunes:episode>
<itunes:season>${e.season}</itunes:season>
<itunes:episodeType>${_xml(e.episodeType)}</itunes:episodeType>
<itunes:explicit>${e.explicit ? 'true' : 'false'}</itunes:explicit>
$chapters
</item>""";
    }).join('\n');
    final artworkEpisode = episodes.where((e) => e.artworkPath != null && e.artworkPath!.isNotEmpty).isNotEmpty
        ? episodes.firstWhere((e) => e.artworkPath != null && e.artworkPath!.isNotEmpty)
        : null;
    final image = artworkEpisode?.artworkPath == null ? '' : '<itunes:image href="${_xml('$cleanBase/artwork/${Uri.encodeComponent(File(artworkEpisode!.artworkPath!).uri.pathSegments.last)}')}" />';
    final xml = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:psc="http://podlove.org/simple-chapters">
<channel>
<title>${_xml(show)}</title>
<link>${_xml(cleanBase)}</link>
<description>${_xml('Podcast published by BroadcastNG')}</description>
<language>en</language>
<atom:link href="${_xml('$cleanBase/feed.xml')}" rel="self" type="application/rss+xml" />
$image
$items
</channel>
</rss>""";
    final dir = Directory('${Directory.current.path}/broadcastng_podcast_export');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/feed.xml');
    return file.writeAsString(xml);
  }

  String _formatChapter(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.000';
  }

  Future<void> _save(List<PodcastEpisode> episodes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(episodes.map((e) => e.toJson()).toList()));
  }

  String _xml(String value) => const HtmlEscape().convert(value);
}

extension on DateTime {
  String toRfc822() => HttpDate.format(toUtc());
}
