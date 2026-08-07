import 'dart:async';
import 'package:flutter/material.dart';
import '../services/broadcast_engine.dart';
import '../services/settings_service.dart';
import '../services/permission_service.dart';
import '../services/broadcast_history_service.dart';
import 'settings_screen.dart';
import 'cart_wall_screen.dart';
import 'playlist_screen.dart';
import 'history_screen.dart';

/// Main "on air" view: mic toggle, live/stop control, level meters,
/// connection status, broadcast timer, and the mic/track crossfader. This
/// is the screen the broadcaster spends most of their time on while live.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  final _engine = BroadcastEngine.instance;
  final _settings = SettingsService();
  final _history = BroadcastHistoryService();

  StreamStatus _status = StreamStatus.idle;
  bool _micMuted = false;
  bool _pushToTalkMode = false;
  double _micLevel = 0.0;
  double _trackLevel = 0.0;
  double _mixPosition = 0.5;

  DateTime? _liveStartedAt;
  Duration _liveDuration = Duration.zero;
  Timer? _timerTicker;

  int _deadAirSeconds = 0;

  bool _echoCancellationEnabled = true;
  bool _noiseSuppressionEnabled = true;
  bool _autoGainEnabled = false;
  bool _echoCancellationAvailable = true;
  bool _noiseSuppressionAvailable = true;
  bool _autoGainAvailable = true;

  @override
  void initState() {
    super.initState();

    _engine.statusStream.listen((status) {
      final wasLive = _status == StreamStatus.live;
      if (mounted) setState(() => _status = status);

      if (status == StreamStatus.live && !wasLive) {
        _onWentLive();
      } else if (status != StreamStatus.live && wasLive) {
        _onStoppedBeingLive();
      }
    });

    _engine.levelsStream.listen((levels) {
      if (mounted) {
        setState(() {
          _micLevel = levels.mic;
          _trackLevel = levels.track;
        });
      }
    });

    _engine.errorStream.listen((error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    });

    _engine.deadAirStream.listen((seconds) {
      if (mounted) setState(() => _deadAirSeconds = seconds);
    });

    _engine.effectAvailabilityStream.listen((availability) {
      if (mounted) {
        setState(() {
          _echoCancellationAvailable = availability.echoCancellation;
          _noiseSuppressionAvailable = availability.noiseSuppression;
          _autoGainAvailable = availability.autoGain;
        });
      }
    });
  }

  void _onWentLive() {
    _liveStartedAt = DateTime.now();
    _deadAirSeconds = 0;
    _timerTicker?.cancel();
    _timerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_liveStartedAt != null && mounted) {
        setState(() => _liveDuration = DateTime.now().difference(_liveStartedAt!));
      }
    });

    _engine.setEchoCancellationEnabled(_echoCancellationEnabled);
    _engine.setNoiseSuppressionEnabled(_noiseSuppressionEnabled);
    _engine.setAutoGainEnabled(_autoGainEnabled);
  }

  void _onStoppedBeingLive() {
    _timerTicker?.cancel();
    _timerTicker = null;
    _deadAirSeconds = 0;

    if (_liveStartedAt != null) {
      _history.recordSession(_liveStartedAt!, DateTime.now());
    }
    _liveStartedAt = null;
    if (mounted) setState(() => _liveDuration = Duration.zero);
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleLive() async {
    if (_status == StreamStatus.live || _status == StreamStatus.connecting) {
      await _engine.stopStream();
      return;
    }

    final permissionResult =
        await PermissionService.requestBroadcastPermissions();

    if (!permissionResult.micGranted) {
      if (mounted) {
        if (permissionResult.micPermanentlyDenied) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Microphone access is required to broadcast. Enable it in system settings.',
              ),
              action: SnackBarAction(
                label: 'Open settings',
                onPressed: PermissionService.openSettings,
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission is required to broadcast'),
            ),
          );
        }
      }
      return;
    }

    final config = await _settings.loadConfig();
    if (config == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Set up your broadcast server in Settings first'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: _openSettings,
            ),
          ),
        );
      }
      return;
    }
    await _engine.startStream(config);
  }

  Future<void> _confirmEmergencyStop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Emergency stop?'),
        content: const Text(
          'This immediately kills the broadcast — mic, playback, and the '
          'connection to your server — with no graceful shutdown. Use this '
          'only if something is going wrong and you need to cut the stream '
          'right now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Emergency stop'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _engine.emergencyStop();
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _togglePushToTalkMode() {
    setState(() {
      _pushToTalkMode = !_pushToTalkMode;
      _micMuted = true;
    });
    _engine.setMicMuted(true);
  }

  String get _statusLabel {
    switch (_status) {
      case StreamStatus.idle:
        return 'Not live';
      case StreamStatus.connecting:
        return 'Connecting…';
      case StreamStatus.live:
        return 'LIVE';
      case StreamStatus.reconnecting:
        return 'Reconnecting…';
      case StreamStatus.disconnected:
        return 'Disconnected';
      case StreamStatus.error:
        return 'Error';
    }
  }

  Color get _statusColor {
    switch (_status) {
      case StreamStatus.live:
        return Colors.redAccent;
      case StreamStatus.connecting:
      case StreamStatus.reconnecting:
        return Colors.orangeAccent;
      case StreamStatus.error:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  void dispose() {
    _timerTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLive = _status == StreamStatus.live;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Studio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Broadcast history',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.queue_music),
            tooltip: 'Playlist',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlaylistScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.grid_view),
            tooltip: 'Cart Wall',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CartWallScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              if (_deadAirSeconds > 0)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Dead air — nothing audible for ${_deadAirSeconds}s',
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                ),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_statusLabel,
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              if (isLive)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _formatDuration(_liveDuration),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              const SizedBox(height: 24),

              Row(
                children: [
                  Expanded(
                    child: _LevelMeter(label: 'MIC', level: _micLevel),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _LevelMeter(label: 'TRACK', level: _trackLevel),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              GestureDetector(
                onTap: _toggleLive,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isLive ? Colors.redAccent : Colors.blueAccent,
                  ),
                  child: Icon(
                    isLive ? Icons.stop : Icons.podcasts,
                    size: 56,
                    color: Colors.white,
                  ),
                ),
              ),
              if (isLive)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextButton.icon(
                    onPressed: _confirmEmergencyStop,
                    icon: const Icon(Icons.dangerous, color: Colors.red),
                    label: const Text('Emergency stop',
                        style: TextStyle(color: Colors.red)),
                  ),
                ),
              const SizedBox(height: 20),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _pushToTalkMode
                      ? GestureDetector(
                          onTapDown: (_) {
                            setState(() => _micMuted = false);
                            _engine.setMicMuted(false);
                          },
                          onTapUp: (_) {
                            setState(() => _micMuted = true);
                            _engine.setMicMuted(true);
                          },
                          onTapCancel: () {
                            setState(() => _micMuted = true);
                            _engine.setMicMuted(true);
                          },
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _micMuted
                                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                                  : Colors.redAccent,
                            ),
                            child: Icon(
                              _micMuted ? Icons.mic_off : Icons.mic,
                              size: 32,
                              color: _micMuted
                                  ? Theme.of(context).colorScheme.onSurfaceVariant
                                  : Colors.white,
                            ),
                          ),
                        )
                      : IconButton.filledTonal(
                          iconSize: 32,
                          onPressed: () {
                            setState(() => _micMuted = !_micMuted);
                            _engine.setMicMuted(_micMuted);
                          },
                          icon: Icon(_micMuted ? Icons.mic_off : Icons.mic),
                        ),
                  const SizedBox(width: 16),
                  IconButton(
                    tooltip: _pushToTalkMode
                        ? 'Push-to-talk (hold to speak)'
                        : 'Toggle mute',
                    onPressed: _togglePushToTalkMode,
                    icon: Icon(
                      _pushToTalkMode ? Icons.touch_app : Icons.touch_app_outlined,
                      color: _pushToTalkMode
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ],
              ),
              if (_pushToTalkMode)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Hold to talk',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              const SizedBox(height: 32),

              Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text('MIC'),
                      Text('TRACK'),
                    ],
                  ),
                  Slider(
                    value: _mixPosition,
                    onChanged: (value) {
                      setState(() => _mixPosition = value);
                      _engine.crossfade(
                        value < 0.5 ? MixTarget.mic : MixTarget.track,
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),

              ExpansionTile(
                title: const Text('Mic effects'),
                tilePadding: EdgeInsets.zero,
                children: [
                  SwitchListTile(
                    title: const Text('Echo cancellation'),
                    subtitle: !_echoCancellationAvailable
                        ? const Text('Not supported on this device')
                        : null,
                    value: _echoCancellationEnabled,
                    onChanged: !_echoCancellationAvailable
                        ? null
                        : (value) {
                            setState(() => _echoCancellationEnabled = value);
                            _engine.setEchoCancellationEnabled(value);
                          },
                  ),
                  SwitchListTile(
                    title: const Text('Noise suppression'),
                    subtitle: !_noiseSuppressionAvailable
                        ? const Text('Not supported on this device')
                        : null,
                    value: _noiseSuppressionEnabled,
                    onChanged: !_noiseSuppressionAvailable
                        ? null
                        : (value) {
                            setState(() => _noiseSuppressionEnabled = value);
                            _engine.setNoiseSuppressionEnabled(value);
                          },
                  ),
                  SwitchListTile(
                    title: const Text('Auto gain'),
                    subtitle: Text(
                      !_autoGainAvailable
                          ? 'Not supported on this device'
                          : 'Automatically levels mic volume — off by default '
                              'since it can interact with manual gain control',
                    ),
                    value: _autoGainEnabled,
                    onChanged: !_autoGainAvailable
                        ? null
                        : (value) {
                            setState(() => _autoGainEnabled = value);
                            _engine.setAutoGainEnabled(value);
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LevelMeter extends StatelessWidget {
  final String label;
  final double level;

  const _LevelMeter({required this.label, required this.level});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: level.clamp(0.0, 1.0),
            minHeight: 12,
            backgroundColor: Colors.white12,
            color: level > 0.85 ? Colors.redAccent : Colors.greenAccent,
          ),
        ),
      ],
    );
  }
}
