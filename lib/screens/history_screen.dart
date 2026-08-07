import 'package:flutter/material.dart';
import '../services/broadcast_history_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _history = BroadcastHistoryService();
  List<BroadcastSession> _sessions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await _history.loadHistory();
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _isLoading = false;
      });
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
            'This removes all recorded broadcast sessions. This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _history.clearHistory();
      _load();
    }
  }

  String _formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final isToday =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (isToday) return 'Today, $time';
    return '${dt.month}/${dt.day}/${dt.year}, $time';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Broadcast History'),
        actions: [
          if (_sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear history',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No broadcasts yet. Your session history will appear here after you go live.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    return ListTile(
                      leading: const Icon(Icons.podcasts),
                      title: Text(_formatDate(session.startedAt)),
                      subtitle: Text(
                        'Duration: ${_formatDuration(session.durationSeconds)}',
                      ),
                    );
                  },
                ),
    );
  }
}
