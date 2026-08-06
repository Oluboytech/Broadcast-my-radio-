import 'package:flutter/material.dart';
import '../services/broadcast_engine.dart';
import '../services/settings_service.dart';
import 'settings_screen.dart';

class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  final _engine = BroadcastEngine.instance;
  final _settings = SettingsService();

  StreamStatus _status = StreamStatus.idle;
  bool _micMuted = false;
  double _micLevel = 0.0;
  double _trackLevel = 0.0;
  double _mixPosition = 0.5;

  @override
  void initState() {
    super.initState();
    _engine.statusStream.listen((status) {
      if (mounted) setState(() => _status = status);
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
  }

  Future<void> _toggleLive() async {
    if (_status == StreamStatus.live || _status == StreamStatus.connecting) {
      await _engine.stopStream();
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

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
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
  Widget build(BuildContext context) {
    final isLive = _status == StreamStatus.live;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Studio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
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
              const SizedBox(height: 32),
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
              const SizedBox(height: 32),
              IconButton.filledTonal(
                iconSize: 32,
                onPressed: () {
                  setState(() => _micMuted = !_micMuted);
                  _engine.setMicMuted(_micMuted);
                },
                icon: Icon(_micMuted ? Icons.mic_off : Icons.mic),
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
