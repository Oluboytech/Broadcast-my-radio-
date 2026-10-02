import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/podcast_episode.dart';
import '../models/podcast_publishing.dart';
import 'podcast_service.dart';

class PodcastPublishingService {
  static const _configKey = 'podcast_publishing_config_v1';
  static const _analyticsKey = 'podcast_analytics_v1';
  final PodcastService podcasts = PodcastService();

  Future<PodcastPublishingConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_configKey);
    if (raw == null) return const PodcastPublishingConfig();
    try {
      return PodcastPublishingConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const PodcastPublishingConfig();
    }
  }

  Future<void> saveConfig(PodcastPublishingConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(config.toJson()));
  }

  Future<String> exportRss(PodcastPublishingConfig config) =>
      podcasts.generateRssFeed(baseUrl: config.rssBaseUrl.isNotEmpty ? config.rssBaseUrl : 'https://example.com');

  Future<PodcastEpisode> uploadEpisode(PodcastEpisode episode) async {
    final config = await loadConfig();
    if (!config.enabled || config.baseUrl.trim().isEmpty) {
      throw StateError('Podcast hosting is not configured. Add the publishing API URL first.');
    }
    final audio = File(episode.audioPath);
    if (!audio.existsSync()) throw StateError('Episode audio file no longer exists.');

    final uri = Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/$'), '')}/v1/podcasts/episodes');
    final request = http.MultipartRequest('POST', uri);
    if (config.apiKey.isNotEmpty) request.headers['Authorization'] = 'Bearer ${config.apiKey}';
    request.fields.addAll({
      'id': episode.id,
      'title': episode.title,
      'description': episode.description,
      'showName': episode.showName,
      'host': episode.host,
      'category': episode.category,
      'episodeType': episode.episodeType,
      'season': '${episode.season}',
      'episodeNumber': '${episode.episodeNumber}',
      'explicit': '${episode.explicit}',
      'language': episode.language,
      'website': episode.website,
      'copyright': episode.copyright,
      'keywords': episode.keywords,
      'chapters': jsonEncode(episode.chapters.map((c) => c.toJson()).toList()),
    });
    request.files.add(await http.MultipartFile.fromPath('audio', episode.audioPath));
    if (episode.artworkPath != null && File(episode.artworkPath!).existsSync()) {
      request.files.add(await http.MultipartFile.fromPath('artwork', episode.artworkPath!));
    }
    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Publishing API returned ${response.statusCode}: $body');
    }
    final data = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    episode.remoteId = data['id']?.toString() ?? episode.remoteId ?? episode.id;
    episode.rssUrl = data['rssUrl']?.toString() ?? episode.rssUrl;
    episode.status = 'uploaded';
    episode.distribution['Podcast RSS'] = 'uploaded';
    await podcasts.saveEpisode(episode);
    return episode;
  }

  Future<PodcastEpisode> publishEpisode(PodcastEpisode episode) async {
    final config = await loadConfig();
    if (!config.enabled || config.baseUrl.trim().isEmpty) {
      throw StateError('Podcast hosting is not configured.');
    }
    final remoteId = episode.remoteId ?? episode.id;
    final uri = Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/$'), '')}/v1/podcasts/episodes/$remoteId/publish');
    final response = await http.post(uri,
        headers: {
          if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'publishAt': episode.publishAt?.toUtc().toIso8601String()}));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Publish request failed (${response.statusCode}).');
    }
    episode.status = 'published';
    episode.distribution['Podcast RSS'] = 'published';
    await podcasts.saveEpisode(episode);
    return episode;
  }

  Future<Map<String, dynamic>> loadAnalytics({String? episodeId}) async {
    final config = await loadConfig();
    if (config.enabled && config.baseUrl.isNotEmpty) {
      final uri = Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/$'), '')}/v1/podcasts/analytics${episodeId == null ? '' : '?episodeId=${Uri.encodeQueryComponent(episodeId)}'}');
      final response = await http.get(uri, headers: {if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}'});
      if (response.statusCode >= 200 && response.statusCode < 300 && response.body.isNotEmpty) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_analyticsKey);
    if (raw == null) return {'downloads': 0, 'streams': 0, 'listeners': 0};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> recordLocalAnalytics({required String event, String? episodeId}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_analyticsKey);
    final data = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    data[event] = (data[event] as num? ?? 0) + 1;
    if (episodeId != null) {
      final byEpisode = Map<String, dynamic>.from(data['episodes'] as Map? ?? {});
      final item = Map<String, dynamic>.from(byEpisode[episodeId] as Map? ?? {});
      item[event] = (item[event] as num? ?? 0) + 1;
      byEpisode[episodeId] = item;
      data['episodes'] = byEpisode;
    }
    await prefs.setString(_analyticsKey, jsonEncode(data));
  }
}
