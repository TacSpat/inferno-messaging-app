import 'dart:io';
import 'package:flutter/material.dart';

class FileUploadPreview extends StatelessWidget {
  final List<File> files;
  final void Function(int index) onRemove;
  final VoidCallback onSend;
  final bool uploading;

  const FileUploadPreview({
    super.key,
    required this.files,
    required this.onRemove,
    required this.onSend,
    this.uploading = false,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF16213E),
        border: Border(top: BorderSide(color: Color(0xFF2A3A5C))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Attachments', style: TextStyle(color: Color(0xFF8899A6), fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                final isImage = _isImage(file.path);
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E2A4A),
                          borderRadius: BorderRadius.circular(8),
                          image: isImage
                              ? DecorationImage(image: FileImage(file), fit: BoxFit.cover)
                              : null,
                        ),
                        child: !isImage
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.insert_drive_file, color: Color(0xFF8899A6), size: 24),
                                    const SizedBox(height: 4),
                                    Text(
                                      file.path.split('/').last,
                                      style: const TextStyle(color: Color(0xFF8899A6), fontSize: 9),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              )
                            : null,
                      ),
                      Positioned(
                        top: -4,
                        right: -4,
                        child: IconButton(
                          icon: const Icon(Icons.cancel, size: 20, color: Color(0xFFFF4D4D)),
                          onPressed: () => onRemove(index),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: uploading ? null : onSend,
              icon: uploading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.upload, size: 18),
              label: Text(uploading ? 'Uploading...' : 'Send ${files.length} file${files.length > 1 ? 's' : ''}'),
            ),
          ),
        ],
      ),
    );
  }

  bool _isImage(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif'].contains(ext);
  }
}
