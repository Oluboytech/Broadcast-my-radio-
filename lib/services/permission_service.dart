import 'package:permission_handler/permission_handler.dart';

/// Handles runtime permission requests needed before going live:
/// - Microphone (required, Android 6.0+): without this AudioCaptureManager's
///   AudioRecord will silently fail to initialize.
/// - Notifications (required, Android 13+): the foreground service's
///   persistent "you are live" notification can't be shown without it —
///   the service would still run, but the person won't see live status.
class PermissionService {
  /// Requests everything needed to broadcast. Returns true if the app can
  /// proceed (mic granted); notification permission is requested too but
  /// isn't blocking, since the stream can still work without a visible
  /// notification, just with degraded UX.
  static Future<PermissionResult> requestBroadcastPermissions() async {
    final micStatus = await Permission.microphone.request();

    // Notification permission only exists as a distinct runtime prompt on
    // Android 13+; on older versions this resolves immediately as granted.
    final notificationStatus = await Permission.notification.request();

    return PermissionResult(
      micGranted: micStatus.isGranted,
      micPermanentlyDenied: micStatus.isPermanentlyDenied,
      notificationGranted: notificationStatus.isGranted,
    );
  }

  static Future<bool> hasMicPermission() async {
    return Permission.microphone.isGranted;
  }

  static Future<void> openSettings() async {
    await openAppSettings();
  }
}

class PermissionResult {
  final bool micGranted;
  final bool micPermanentlyDenied;
  final bool notificationGranted;

  const PermissionResult({
    required this.micGranted,
    required this.micPermanentlyDenied,
    required this.notificationGranted,
  });
}
