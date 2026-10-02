import 'studio_models.dart';

class PodcastChapter {
  final int seconds;
  final String title;
  const PodcastChapter({required this.seconds, required this.title});
  Map<String, dynamic> toJson() => {'seconds': seconds, 'title': title};
  factory PodcastChapter.fromJson(Map<String, dynamic> json) => PodcastChapter(
        seconds: (json['seconds'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
      );
}

class PodcastEpisode {
  final String id;
  String title;
  String description;
  String showName;
  String host;
  String category;
  String episodeType;
  int season;
  int episodeNumber;
  bool explicit;
  String audioPath;
  String? artworkPath;
  int durationSeconds;
  String status;
  DateTime createdAt;
  DateTime? publishAt;
  List<PodcastChapter> chapters;
  String notes;
  String transcript;
  String slug;
  String language;
  String website;
  String copyright;
  String keywords;
  String? remoteId;
  String? rssUrl;
  int playCount;
  Map<String, String> distribution;
  String introPath;
  String outroPath;
  bool noiseReductionEnabled;
  double noiseReductionStrength;
  List<PodcastEditOperation> editOperations;
  List<String> adBreakPaths;

  PodcastEpisode({
    required this.id,
    required this.title,
    this.description = '',
    this.showName = 'My Podcast',
    this.host = '',
    this.category = 'Society & Culture',
    this.episodeType = 'full',
    this.season = 1,
    this.episodeNumber = 1,
    this.explicit = false,
    required this.audioPath,
    this.artworkPath,
    this.durationSeconds = 0,
    this.status = 'draft',
    DateTime? createdAt,
    this.publishAt,
    List<PodcastChapter>? chapters,
    this.notes = '',
    this.transcript = '',
    this.slug = '',
    this.language = 'en',
    this.website = '',
    this.copyright = '',
    this.keywords = '',
    this.remoteId,
    this.rssUrl,
    this.playCount = 0,
    Map<String, String>? distribution,
    this.introPath = '',
    this.outroPath = '',
    this.noiseReductionEnabled = true,
    this.noiseReductionStrength = 0.65,
    List<PodcastEditOperation>? editOperations,
    List<String>? adBreakPaths,
  })  : editOperations = editOperations ?? [],
        adBreakPaths = adBreakPaths ?? [],
        createdAt = createdAt ?? DateTime.now(),
        chapters = chapters ?? [],
        distribution = distribution ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'showName': showName,
        'host': host,
        'category': category,
        'episodeType': episodeType,
        'season': season,
        'episodeNumber': episodeNumber,
        'explicit': explicit,
        'audioPath': audioPath,
        'artworkPath': artworkPath,
        'durationSeconds': durationSeconds,
        'status': status,
        'createdAt': createdAt.toIso8601String(),
        'publishAt': publishAt?.toIso8601String(),
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'notes': notes,
        'transcript': transcript,
        'slug': slug,
        'language': language,
        'website': website,
        'copyright': copyright,
        'keywords': keywords,
        'remoteId': remoteId,
        'rssUrl': rssUrl,
        'playCount': playCount,
        'distribution': distribution,
        'introPath': introPath,
        'outroPath': outroPath,
        'noiseReductionEnabled': noiseReductionEnabled,
        'noiseReductionStrength': noiseReductionStrength,
        'editOperations': editOperations.map((e) => e.toJson()).toList(),
        'adBreakPaths': adBreakPaths,
      };

  factory PodcastEpisode.fromJson(Map<String, dynamic> json) => PodcastEpisode(
        id: json['id'] as String,
        title: json['title'] as String? ?? 'Untitled Episode',
        description: json['description'] as String? ?? '',
        showName: json['showName'] as String? ?? 'My Podcast',
        host: json['host'] as String? ?? '',
        category: json['category'] as String? ?? 'Society & Culture',
        episodeType: json['episodeType'] as String? ?? 'full',
        season: (json['season'] as num?)?.toInt() ?? 1,
        episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 1,
        explicit: json['explicit'] as bool? ?? false,
        audioPath: json['audioPath'] as String? ?? '',
        artworkPath: json['artworkPath'] as String?,
        durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
        status: json['status'] as String? ?? 'draft',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        publishAt: DateTime.tryParse(json['publishAt'] as String? ?? ''),
        chapters: ((json['chapters'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => PodcastChapter.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        notes: json['notes'] as String? ?? '',
        transcript: json['transcript'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        language: json['language'] as String? ?? 'en',
        website: json['website'] as String? ?? '',
        copyright: json['copyright'] as String? ?? '',
        keywords: json['keywords'] as String? ?? '',
        remoteId: json['remoteId'] as String?,
        rssUrl: json['rssUrl'] as String?,
        playCount: (json['playCount'] as num?)?.toInt() ?? 0,
        distribution: Map<String, String>.from(json['distribution'] as Map? ?? {}),
        introPath: json['introPath'] as String? ?? '',
        outroPath: json['outroPath'] as String? ?? '',
        noiseReductionEnabled: json['noiseReductionEnabled'] as bool? ?? true,
        noiseReductionStrength: (json['noiseReductionStrength'] as num?)?.toDouble() ?? 0.65,
        editOperations: ((json['editOperations'] as List?) ?? []).whereType<Map>().map((e) => PodcastEditOperation.fromJson(Map<String,dynamic>.from(e))).toList(),
        adBreakPaths: List<String>.from(json['adBreakPaths'] ?? const []),
      );
}
