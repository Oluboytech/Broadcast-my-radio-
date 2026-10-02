# BroadcastNG Podcast Publishing API contract

The mobile app can publish to any HTTPS backend implementing this small contract. This keeps Apple/Spotify/Amazon credentials on the server instead of inside the APK.

## POST /v1/podcasts/episodes

`multipart/form-data`

Fields:
- `id`
- `title`
- `description`
- `showName`
- `host`
- `category`
- `episodeType`
- `season`
- `episodeNumber`
- `explicit`
- `language`
- `website`
- `copyright`
- `keywords`
- `chapters` (JSON array)
- `audio` (WAV/AAC/MP3/M4A)
- `artwork` (optional)

Response:
```json
{"id":"episode-123","rssUrl":"https://media.example.com/feed.xml"}
```

## POST /v1/podcasts/episodes/{id}/publish

Publishes immediately or at the optional `publishAt` ISO-8601 timestamp.

## GET /v1/podcasts/analytics?episodeId=...

Example response:
```json
{"streams":1200,"downloads":840,"listeners":560}
```

## Server responsibilities

1. Store/transcode the master audio into podcast-friendly formats.
2. Store audio/artwork behind stable HTTPS URLs.
3. Generate and host a valid RSS feed.
4. Validate episode metadata and GUID uniqueness.
5. Execute scheduled publication.
6. Optionally submit/sync the feed to supported podcast directories using server-side credentials.
7. Collect download/stream analytics.

The Android app deliberately never stores directory credentials for Apple/Spotify/Amazon. RSS is the portable distribution layer; directory-specific automation belongs on the publishing backend.
