import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/broadcast_engine.dart';

class CartSlot {
  final String label;
  final String? filePath;

  const CartSlot({required this.label, this.filePath});

  Map<String, dynamic> toJson() => {'label': label, 'filePath': filePath};

  factory CartSlot.fromJson(Map<String, dynamic> json) => CartSlot(
        label: json['label'] as String,
        filePath: json['filePath'] as String?,
      );
}

/// Grid of instant-play sound buttons (jingles, stingers, effects). Tapping
/// a filled slot fires it into the live mix immediately via playCart();
/// long-pressing any slot lets you assign or replace its file. Slot
/// assignments persist locally between sessions.
class CartWallScreen extends StatefulWidget {
  const CartWallScreen({super.key});

  @override
  State<CartWallScreen> createState() => _CartWallScreenState();
}

class _CartWallScreenState extends State<CartWallScreen> {
  static const _prefsKey = 'cart_wall_slots';
  static const _slotCount = 16; // medium grid, per earlier sizing decision

  final _engine = BroadcastEngine.instance;
  List<CartSlot> _slots = List.generate(
    _slotCount,
    (i) => CartSlot(label: 'Cart ${i + 1}'),
  );
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSlots();
  }

  Future<void> _loadSlots() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored) as List;
        final loaded = decoded
            .map((e) => CartSlot.fromJson(e as Map<String, dynamic>))
            .toList();
        if (loaded.length == _slotCount) {
          setState(() => _slots = loaded);
        }
      } catch (_) {
        // Corrupt or outdated stored format — fall back to the default
        // empty slots rather than crash the screen.
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveSlots() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_slots.map((s) => s.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  Future<void> _assignSlot(int index) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );
    if (result == null || result.files.single.path == null) return;

    final path = result.files.single.path!;
    final fileName = result.files.single.name;
    // Strip extension for a cleaner default label
    final label = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;

    setState(() {
      _slots[index] = CartSlot(label: label, filePath: path);
    });
    await _saveSlots();
  }

  Future<void> _clearSlot(int index) async {
    setState(() {
      _slots[index] = CartSlot(label: 'Cart ${index + 1}');
    });
    await _saveSlots();
  }

  void _fireCart(CartSlot slot) {
    if (slot.filePath == null) return;
    _engine.playCart(slot.filePath!);
  }

  Future<void> _showSlotOptions(int index) async {
    final slot = _slots[index];
    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(slot.filePath == null
                  ? 'Assign a sound'
                  : 'Replace sound'),
              onTap: () {
                Navigator.pop(context);
                _assignSlot(index);
              },
            ),
            if (slot.filePath != null)
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('Clear slot'),
                onTap: () {
                  Navigator.pop(context);
                  _clearSlot(index);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Cart Wall')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: _slots.length,
          itemBuilder: (context, index) {
            final slot = _slots[index];
            final isAssigned = slot.filePath != null;

            return Material(
              color: isAssigned
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _fireCart(slot),
                onLongPress: () => _showSlotOptions(index),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isAssigned ? Icons.play_circle_fill : Icons.add,
                        size: 28,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        slot.label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
