import 'package:flutter/material.dart';
import '../services/broadcast_engine.dart';
import '../services/settings_service.dart';

/// Broadcast server configuration screen — maps directly to the fields shown
/// in Zeno.fm's "Broadcast settings" (or any standard Icecast2 source panel):
/// server address, port, mount point, username, password, format, bitrate.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  final _formKey = GlobalKey<FormState>();

  final _serverController = TextEditingController();
  final _portController = TextEditingController(text: '80');
  final _mountController = TextEditingController();
  final _usernameController = TextEditingController(text: 'source');
  final _passwordController = TextEditingController();
  final _stationNameController =
      TextEditingController(text: 'BroadcastNG — Live');

  String _format = 'aac';
  int _bitrateKbps = 128;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final config = await _settings.loadConfig();
    if (config != null && mounted) {
      _serverController.text = config.serverAddress;
      _portController.text = config.port.toString();
      // Strip leading slash for editing — SettingsService/IcecastConfig
      // re-adds it when needed, so the field just shows the raw mount name.
      _mountController.text = config.mountPoint.startsWith('/')
          ? config.mountPoint.substring(1)
          : config.mountPoint;
      _usernameController.text = config.username;
      _passwordController.text = config.password;
      _stationNameController.text = config.stationName;
      _format = config.format;
      _bitrateKbps = config.bitrateKbps;
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final config = IcecastConfig(
      serverAddress: _serverController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 80,
      mountPoint: _mountController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      format: _format,
      bitrateKbps: _bitrateKbps,
      stationName: _stationNameController.text.trim().isEmpty
          ? 'BroadcastNG — Live'
          : _stationNameController.text.trim(),
    );

    await _settings.saveConfig(config);

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Broadcast settings saved')),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _portController.dispose();
    _mountController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _stationNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Broadcast Settings'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionLabel('Stream Encoder Settings (Icecast)'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'link.zeno.fm',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '80',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '');
                if (n == null || n <= 0) return 'Enter a valid port';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _mountController,
              decoration: const InputDecoration(
                labelText: 'Mount point',
                hintText: '1s82py3dtwzuv/source',
                helperText: 'Leading "/" is added automatically',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                hintText: 'source',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Mount password',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 24),
            _SectionLabel('Encoding'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _format,
              decoration: const InputDecoration(
                labelText: 'Output format',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'aac', child: Text('AAC')),
                DropdownMenuItem(
                  value: 'mp3',
                  child: Text('MP3 (not yet supported by the app)'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                if (v == 'mp3') {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'MP3 encoding isn\'t built yet — sticking with AAC for now',
                      ),
                    ),
                  );
                  return;
                }
                setState(() => _format = v);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _bitrateKbps,
              decoration: const InputDecoration(
                labelText: 'Bitrate',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 64, child: Text('64 kbps')),
                DropdownMenuItem(value: 96, child: Text('96 kbps')),
                DropdownMenuItem(value: 128, child: Text('128 kbps')),
                DropdownMenuItem(value: 192, child: Text('192 kbps')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _bitrateKbps = v);
              },
            ),
            const SizedBox(height: 24),
            _SectionLabel('Station'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _stationNameController,
              decoration: const InputDecoration(
                labelText: 'Station name',
                helperText: 'Shown as "now playing" when no track is active',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _isSaving ? null : _save,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    );
  }
}
