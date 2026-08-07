import 'package:shared_preferences/shared_preferences.dart';
import '../services/broadcast_engine.dart';

/// Persists Icecast/Shoutcast server settings locally (e.g. Zeno.fm broadcast
/// settings: server address, port, mount point, username, password, format,
/// bitrate). Values map 1:1 to what's shown in tools.zeno.fm > Broadcast settings.
class SettingsService {
  static const _kServerAddress = 'server_address';
  static const _kPort = 'port';
  static const _kMountPoint = 'mount_point';
  static const _kUsername = 'username';
  static const _kPassword = 'password';
  static const _kFormat = 'format';
  static const _kBitrate = 'bitrate_kbps';
  static const _kStationName = 'station_name';

  Future<IcecastConfig?> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString(_kServerAddress);
    if (server == null || server.isEmpty) return null;

    return IcecastConfig(
      serverAddress: server,
      port: prefs.getInt(_kPort) ?? 80,
      mountPoint: prefs.getString(_kMountPoint) ?? '',
      username: prefs.getString(_kUsername) ?? 'source',
      password: prefs.getString(_kPassword) ?? '',
      format: prefs.getString(_kFormat) ?? 'aac',
      bitrateKbps: prefs.getInt(_kBitrate) ?? 128,
      stationName: prefs.getString(_kStationName) ?? 'BroadcastNG — Live',
    );
  }

  Future<void> saveConfig(IcecastConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerAddress, config.serverAddress);
    await prefs.setInt(_kPort, config.port);
    await prefs.setString(_kMountPoint, config.mountPoint);
    await prefs.setString(_kUsername, config.username);
    await prefs.setString(_kPassword, config.password);
    await prefs.setString(_kFormat, config.format);
    await prefs.setInt(_kBitrate, config.bitrateKbps);
    await prefs.setString(_kStationName, config.stationName);
  }
}
