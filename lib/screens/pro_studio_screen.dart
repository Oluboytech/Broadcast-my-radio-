import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/studio_models.dart';
import '../services/broadcast_engine.dart';
import '../services/studio_management_service.dart';
import 'playlist_screen.dart';
import 'podcast_studio_screen.dart';

class ProStudioScreen extends StatefulWidget {
  const ProStudioScreen({super.key});

  @override
  State<ProStudioScreen> createState() => _ProStudioScreenState();
}

class _ProStudioScreenState extends State<ProStudioScreen>
    with SingleTickerProviderStateMixin {
  final _svc = StudioManagementService();
  final _engine = BroadcastEngine.instance;

  late final TabController _tabs;
  List<BroadcastChannel> _channels = [];
  List<StationAd> _ads = [];
  List<PodcastShow> _shows = [];
  List<PodcastHost> _hosts = [];
  AutoDjSettings _dj = AutoDjSettings();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _load();
  }

  Future<void> _load() async {
    _channels = await _svc.loadChannels();
    _ads = await _svc.loadAds();
    _shows = await _svc.loadShows();
    _hosts = await _svc.loadHosts();
    _dj = await _svc.loadAutoDj();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickAd() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = result?.files.single.path;
    if (path == null) return;

    final file = result!.files.single;
    _ads.add(
      StationAd(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: file.name,
        filePath: path,
      ),
    );

    await _svc.saveAds(_ads);
    if (mounted) setState(() {});
  }

  Future<void> _addShow() async {
    final controller = TextEditingController();
    final ok = await _simpleDialog('New show', 'Show name', controller);
    if (!ok || controller.text.trim().isEmpty) return;

    _shows.add(
      PodcastShow(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: controller.text.trim(),
      ),
    );

    await _svc.saveShows(_shows);
    if (mounted) setState(() {});
  }

  Future<void> _addHost() async {
    final controller = TextEditingController();
    final ok = await _simpleDialog('New host', 'Host name', controller);
    if (!ok || controller.text.trim().isEmpty) return;

    _hosts.add(
      PodcastHost(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: controller.text.trim(),
      ),
    );

    await _svc.saveHosts(_hosts);
    if (mounted) setState(() {});
  }

  Future<bool> _simpleDialog(
    String title,
    String label,
    TextEditingController controller,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: label),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    return result == true;
  }

  Future<void> _saveDj() async {
    await _svc.saveAutoDj(_dj);
    _engine.setShuffle(_dj.shuffle);
    _engine.setRepeatProtectionEnabled(_dj.repeatProtection);
    _engine.setArtistSeparationEnabled(_dj.artistSeparation);
    _engine.setCategoryRotationEnabled(_dj.categoryRotation);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Professional Studio'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Mixer'),
            Tab(text: 'Auto DJ'),
            Tab(text: 'Ads'),
            Tab(text: 'Network'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _mixer(),
          _autoDj(),
          _adsView(),
          _showsView(),
        ],
      ),
    );
  }

  Widget _mixer() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Broadcast Mixer',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('Control the live microphone and station mix.'),
        const SizedBox(height: 16),
        if (_channels.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No mixer channels configured yet.'),
            ),
          )
        else
          ..._channels.map(
            (channel) => Card(
              child: ListTile(
                title: Text(channel.name),
                subtitle: Text('Gain ${channel.gain.toStringAsFixed(2)} • Pan ${channel.pan.toStringAsFixed(2)}'),
                trailing: Icon(channel.muted ? Icons.volume_off : Icons.volume_up),
              ),
            ),
          ),
      ],
    );
  }

  Widget _autoDj() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Auto DJ',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Enable Auto DJ'),
          value: _dj.enabled,
          onChanged: (value) {
            setState(() => _dj.enabled = value);
            _saveDj();
          },
        ),
        SwitchListTile(
          title: const Text('Shuffle'),
          value: _dj.shuffle,
          onChanged: (value) {
            setState(() => _dj.shuffle = value);
            _saveDj();
          },
        ),
        SwitchListTile(
          title: const Text('Repeat protection'),
          value: _dj.repeatProtection,
          onChanged: (value) {
            setState(() => _dj.repeatProtection = value);
            _saveDj();
          },
        ),
        SwitchListTile(
          title: const Text('Artist separation'),
          value: _dj.artistSeparation,
          onChanged: (value) {
            setState(() => _dj.artistSeparation = value);
            _saveDj();
          },
        ),
        SwitchListTile(
          title: const Text('Category rotation'),
          value: _dj.categoryRotation,
          onChanged: (value) {
            setState(() => _dj.categoryRotation = value);
            _saveDj();
          },
        ),
      ],
    );
  }

  Widget _adsView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Ad Library',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
            FilledButton.icon(
              onPressed: _pickAd,
              icon: const Icon(Icons.add),
              label: const Text('Add ad'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_ads.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No ad files added yet.'),
            ),
          )
        else
          ..._ads.map(
            (ad) => Card(
              child: ListTile(
                leading: const Icon(Icons.radio),
                title: Text(ad.name),
                subtitle: Text(ad.filePath),
              ),
            ),
          ),
      ],
    );
  }

  Widget _showsView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Podcast Network',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              onPressed: _addHost,
              icon: const Icon(Icons.person_add),
            ),
            IconButton(
              onPressed: _addShow,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_shows.isEmpty && _hosts.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No podcast hosts or shows yet.'),
            ),
          )
        else ...[
          if (_hosts.isNotEmpty)
            ..._hosts.map(
              (host) => Card(
                child: ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(host.name),
                ),
              ),
            ),
          if (_shows.isNotEmpty)
            ..._shows.map(
              (show) => Card(
                child: ListTile(
                  leading: const Icon(Icons.podcasts),
                  title: Text(show.name),
                ),
              ),
            ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }
}
