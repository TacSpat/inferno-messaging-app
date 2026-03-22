import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/gif_service.dart';

class GifPicker extends StatefulWidget {
  final void Function(GifResult gif) onSelect;

  const GifPicker({super.key, required this.onSelect});

  @override
  State<GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<GifPicker> {
  final _searchController = TextEditingController();
  final _gifService = GifService();
  List<GifResult> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadTrending();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTrending() async {
    setState(() => _loading = true);
    final results = await _gifService.trending();
    if (mounted) setState(() { _results = results; _loading = false; });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) { _loadTrending(); return; }
    setState(() => _loading = true);
    final results = await _gifService.search(query);
    if (mounted) setState(() { _results = results; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 320,
      decoration: const BoxDecoration(
        color: Color(0xFF16213E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search GIFs...',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: _search,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final gif = _results[index];
                      return InkWell(
                        onTap: () => widget.onSelect(gif),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CachedNetworkImage(
                            imageUrl: gif.previewUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, s) => Container(color: const Color(0xFF1E2A4A)),
                            errorWidget: (_, s, e) => Container(
                              color: const Color(0xFF1E2A4A),
                              child: const Icon(Icons.broken_image, color: Color(0xFF5C6B77)),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const Padding(
            padding: EdgeInsets.all(4),
            child: Text('Powered by Tenor', style: TextStyle(color: Color(0xFF5C6B77), fontSize: 10)),
          ),
        ],
      ),
    );
  }
}
