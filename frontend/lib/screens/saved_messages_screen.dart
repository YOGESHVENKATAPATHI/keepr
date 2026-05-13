import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../utils/storage_helper.dart';

class SavedMessagesScreen extends StatefulWidget {
  final ApiService api;

  const SavedMessagesScreen({super.key, required this.api});

  @override
  State<SavedMessagesScreen> createState() => _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends State<SavedMessagesScreen> {
  final _storage = const FlutterSecureStorage();
  final _messageController = TextEditingController();

  bool _loading = false;
  String? _token;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final secureToken = await _storage.read(key: 'auth_token');
    final fallback = await getLocalStorageValue('auth_token');
    _token = secureToken ?? fallback;
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_token == null) {
      _showSnack('Please login again', isError: true);
      return;
    }

    setState(() => _loading = true);
    try {
      final data = await widget.api.listSavedMessages(_token!);
      if (!mounted) return;
      setState(() {
        _items = data;
      });
    } catch (e) {
      _showSnack('Failed to load messages: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addMessage() async {
    if (_token == null) return;

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() => _loading = true);
    try {
      await widget.api.createSavedMessage(_token!, text);
      _messageController.clear();
      await _refresh();
      _showSnack('Message saved');
    } catch (e) {
      _showSnack('Failed to save message: $e', isError: true);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteMessage(int id) async {
    if (_token == null) return;

    try {
      await widget.api.deleteSavedMessage(_token!, id);
      await _refresh();
      _showSnack('Message deleted');
    } catch (e) {
      _showSnack('Delete failed: $e', isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.redAccent : const Color(0xFF1D4ED8),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Saved Messages', style: GoogleFonts.inter()),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          )
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Type text you want to save...',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _loading ? null : _addMessage,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                )
              ],
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else
            const SizedBox(height: 2),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Text(
                      'No saved messages yet',
                      style: GoogleFonts.inter(color: Colors.white70),
                    ),
                  )
                : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final id = (item['id'] as num?)?.toInt() ?? 0;
                      final text = item['message_text']?.toString() ?? '';
                      final created = item['created_at']?.toString() ?? '';

                      return ListTile(
                        title: Text(text, style: GoogleFonts.inter()),
                        subtitle: Text(created, style: GoogleFonts.inter(fontSize: 12)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                          onPressed: id <= 0 ? null : () => _deleteMessage(id),
                        ),
                      );
                    },
                  ),
          )
        ],
      ),
    );
  }
}
