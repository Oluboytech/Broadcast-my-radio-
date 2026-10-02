class PodcastPublishingConfig {
  final bool enabled;
  final String baseUrl;
  final String apiKey;
  final String rssBaseUrl;
  final String defaultWebsite;
  final String defaultLanguage;
  final String copyright;
  final bool autoPublishAfterRecording;

  const PodcastPublishingConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.apiKey = '',
    this.rssBaseUrl = '',
    this.defaultWebsite = '',
    this.defaultLanguage = 'en',
    this.copyright = '',
    this.autoPublishAfterRecording = false,
  });

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'rssBaseUrl': rssBaseUrl,
        'defaultWebsite': defaultWebsite,
        'defaultLanguage': defaultLanguage,
        'copyright': copyright,
        'autoPublishAfterRecording': autoPublishAfterRecording,
      };

  factory PodcastPublishingConfig.fromJson(Map<String, dynamic> json) => PodcastPublishingConfig(
        enabled: json['enabled'] as bool? ?? false,
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        rssBaseUrl: json['rssBaseUrl'] as String? ?? '',
        defaultWebsite: json['defaultWebsite'] as String? ?? '',
        defaultLanguage: json['defaultLanguage'] as String? ?? 'en',
        copyright: json['copyright'] as String? ?? '',
        autoPublishAfterRecording: json['autoPublishAfterRecording'] as bool? ?? false,
      );
}

class PodcastDistributionStatus {
  final String provider;
  final String status;
  final String? message;
  final DateTime? updatedAt;

  const PodcastDistributionStatus({
    required this.provider,
    required this.status,
    this.message,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'status': status,
        'message': message,
        'updatedAt': updatedAt?.toIso8601String(),
      };
}
