import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/recent_file.dart';
import '../../shared/widgets/cad_panel.dart';
import '../../shared/widgets/technical_chip.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radii.dart';

class RecentDrawingsPanel extends StatelessWidget {
  const RecentDrawingsPanel({
    super.key,
    required this.files,
    required this.onOpen,
    required this.onPin,
    this.onRemove,
  });

  final List<RecentFile> files;
  final ValueChanged<RecentFile> onOpen;
  final ValueChanged<RecentFile> onPin;
  final ValueChanged<RecentFile>? onRemove;

  @override
  Widget build(BuildContext context) {
    return CadPanel(
      radius: AppRadii.panel,
      padding: const EdgeInsets.fromLTRB(16, 16, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Recent Drawings',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
              TechnicalChip(label: '${files.length} files', compact: true),
            ],
          ),
          const SizedBox(height: 10),
          if (files.isEmpty)
            const _EmptyRecentState()
          else
            ...files.map((file) {
              return _RecentFileRow(
                file: file,
                onTap: () => onOpen(file),
                onPin: () => onPin(file),
                onOpen: () => onOpen(file),
                onRemove: onRemove == null ? null : () => onRemove!(file),
              );
            }),
        ],
      ),
    );
  }
}

class _EmptyRecentState extends StatelessWidget {
  const _EmptyRecentState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.bgMain,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        children: [
          Icon(Icons.folder_open_outlined, color: AppColors.accentSecondary),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Open a DWG file to start building your local recent list.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentFileRow extends StatelessWidget {
  const _RecentFileRow({
    required this.file,
    required this.onTap,
    required this.onPin,
    this.onOpen,
    this.onRemove,
  });

  final RecentFile file;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
          ),
          child: Row(
            children: [
              _RecentThumbnail(thumbnailPath: file.thumbnailPath),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // Size FIRST and highlighted so it never gets ellipsised
                    // away by a long "last opened" tail.
                    Text.rich(
                      TextSpan(
                        children: [
                          if (_sizeText(file) != null)
                            TextSpan(
                              text: '${_sizeText(file)!} · ',
                              style: const TextStyle(
                                color: AppColors.accentPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          TextSpan(text: _openedText(file)),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: file.isPinned ? 'Unpin' : 'Pin',
                onPressed: onPin,
                icon: Icon(
                  file.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: file.isPinned ? AppColors.accentPrimary : AppColors.textMuted,
                  size: 20,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert, color: AppColors.textMuted, size: 20),
                color: AppColors.bgDeep,
                onSelected: (value) async {
                  switch (value) {
                    case 'open':
                      onOpen?.call();
                    case 'pin':
                      onPin();
                    case 'remove':
                      // Deleting is destructive — always confirm first.
                      final confirmed = await _confirmDelete(context, file.name);
                      if (confirmed == true) onRemove?.call();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'open',
                    child: _MenuRow(icon: Icons.open_in_new, label: 'Open'),
                  ),
                  PopupMenuItem(
                    value: 'pin',
                    child: _MenuRow(
                      icon: file.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                      label: file.isPinned ? 'Unpin' : 'Pin',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: _MenuRow(icon: Icons.delete_outline, label: 'Delete'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Asks the user to confirm deleting [name] from the recents list.
  /// Returns true only on an explicit "Delete" tap.
  Future<bool?> _confirmDelete(BuildContext context, String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgDeep,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete file?',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 18),
        ),
        content: Text(
          '"$name" will be deleted.',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// "4.5 MB" (or "412 KB" below a megabyte); null when the size is unknown.
  String? _sizeText(RecentFile file) {
    final bytes = file.fileSizeBytes;
    if (bytes == null || bytes <= 0) return null;
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _openedText(RecentFile file) {
    final minutes = DateTime.now().difference(file.lastOpenedAt).inMinutes;
    final opened = minutes < 1
        ? 'just now'
        : minutes < 60
            ? '$minutes min ago'
            : '${DateTime.now().difference(file.lastOpenedAt).inHours} h ago';
    return 'Last opened $opened';
  }
}

/// Leading preview for a recent row: the generated drawing thumbnail when one
/// exists on disk, otherwise the default DWG document icon. A slightly wider
/// box (landscape) reads as a plan preview rather than a file glyph.
class _RecentThumbnail extends StatelessWidget {
  const _RecentThumbnail({this.thumbnailPath});

  final String? thumbnailPath;

  @override
  Widget build(BuildContext context) {
    final path = thumbnailPath;
    final hasThumb = path != null && path.isNotEmpty && File(path).existsSync();
    return Container(
      width: 54,
      height: 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.bgMain,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: hasThumb
          ? Image.file(
              File(path),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) =>
                  const _ThumbFallbackIcon(),
            )
          : const _ThumbFallbackIcon(),
    );
  }
}

class _ThumbFallbackIcon extends StatelessWidget {
  const _ThumbFallbackIcon();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(Icons.description_outlined,
          color: AppColors.accentPrimary, size: 22),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.textSecondary, size: 18),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14)),
      ],
    );
  }
}
