import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/l10n/l10n.dart';
import '../../data/models/recent_file.dart';
import '../../data/repositories/photos_repository.dart';
import '../../features/app/app_controller.dart';
import '../../services/sample_drawing_service.dart';
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
    this.title,
  });

  final List<RecentFile> files;
  final ValueChanged<RecentFile> onOpen;
  final ValueChanged<RecentFile> onPin;
  final ValueChanged<RecentFile>? onRemove;
  final String? title;

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
              Expanded(
                child: Text(
                  title ?? tr('Recent Drawings', 'Son Çizimler'),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
              TechnicalChip(
                  label: '${files.length} ${tr('files', 'dosya')}',
                  compact: true),
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
      child: Row(
        children: [
          const Icon(Icons.folder_open_outlined,
              color: AppColors.accentSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tr('Open a DWG file to start building your local recent list.',
                  'Son açılanlar listeni oluşturmak için bir DWG dosyası aç.'),
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
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
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
          ),
          child: Row(
            children: [
              _FileTypeBadge(extension: file.fileExtension),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Meta line: full date on the left, size pinned to the
                    // right edge — classic file-manager layout.
                    Row(
                      children: [
                        Text(
                          _dateText(file),
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
                        ),
                        if (file.isPinned) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.push_pin,
                              color: AppColors.accentPrimary, size: 13),
                        ],
                        const Spacer(),
                        Text(
                          _sizeText(file) ?? '',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // The bundled sample ships with the app: no "⋯" menu at all, so
              // it can never be renamed, removed or deleted.
              if (file.id == SampleDrawingService.sampleId)
                const SizedBox(width: 34, height: 34)
              else
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _showActionsSheet(context),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.border, width: 1.2),
                    ),
                    child: const Icon(Icons.more_horiz,
                        color: AppColors.textSecondary, size: 18),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Full-width action menu for the row (the file manager's "⋯" menu): every
  /// entry is a working command, styled in the app palette.
  Future<void> _showActionsSheet(BuildContext context) async {
    final items = <(String, String)>[
      ('open', tr('Open drawing', 'Çizimi aç')),
      ('rename', tr('Rename drawing', 'Yeniden adlandır')),
      ('send', tr('Send drawing', 'Çizimi gönder')),
      (
        'export',
        tr('Share drawing & photo notes', 'Çizimi ve fotoğraf notlarını paylaş'),
      ),
      ('location', tr('Show file location', 'Dosya konumunu göster')),
      (
        'removeList',
        tr('Remove from list (does not delete drawing)',
            'Listeden kaldır (çizimi silmez)'),
      ),
      ('delete', tr('Delete drawing', 'Çizimi sil')),
    ];

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgMain,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Accent strip along the top, echoing the classic menu header bar.
            Container(
              height: 3,
              margin: const EdgeInsets.only(bottom: 4),
              decoration: const BoxDecoration(
                color: AppColors.accentPrimary,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
            ),
            for (final (i, item) in items.indexed) ...[
              if (i > 0)
                const Divider(
                    height: 1, thickness: 0.5, color: AppColors.border),
              InkWell(
                onTap: () => Navigator.of(sheetContext).pop(item.$1),
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
                  child: Text(
                    item.$2,
                    style: TextStyle(
                      color: item.$1 == 'delete'
                          ? const Color(0xFFE58B8B)
                          : AppColors.textPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'open':
        onOpen?.call();
      case 'rename':
        await _rename(context);
      case 'send':
        await _share(context, withPhotos: false);
      case 'export':
        await _share(context, withPhotos: true);
      case 'location':
        await _showLocation(context);
      case 'removeList':
        onRemove?.call();
      case 'delete':
        final confirmed = await _confirmDelete(context, file.name);
        if (confirmed == true && context.mounted) {
          await context.read<AppController>().deleteRecentFile(file);
        }
    }
  }

  /// Plain local path behind [file.uri]; null for content:// sources or
  /// files that no longer exist on disk.
  String? _localPath() {
    var p = file.uri;
    if (p.startsWith('content://')) return null;
    if (p.startsWith('file://')) p = Uri.parse(p).toFilePath();
    try {
      return File(p).existsSync() ? p : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _rename(BuildContext context) async {
    final ext = '.${file.fileExtension}';
    final base = file.name.toLowerCase().endsWith(ext.toLowerCase())
        ? file.name.substring(0, file.name.length - ext.length)
        : file.name;
    final textController = TextEditingController(text: base);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.bgDeep,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          tr('Rename drawing', 'Yeniden adlandır'),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 18),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
          cursorColor: AppColors.accentPrimary,
          decoration: InputDecoration(
            suffixText: ext,
            suffixStyle:
                const TextStyle(color: AppColors.textMuted, fontSize: 14),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.border),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accentPrimary),
            ),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              tr('Cancel', 'Vazgeç'),
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(textController.text),
            child: Text(
              tr('Rename', 'Adlandır'),
              style: const TextStyle(color: AppColors.accentPrimary),
            ),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty || !context.mounted) return;
    await context.read<AppController>().renameRecentFile(file, newName);
  }

  /// Shares the DWG itself; with [withPhotos] the photo notes attached to the
  /// drawing ride along in the same share sheet.
  Future<void> _share(BuildContext context, {required bool withPhotos}) async {
    final path = _localPath();
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('This file cannot be shared from here.',
              'Bu dosya buradan paylaşılamıyor.')),
        ),
      );
      return;
    }
    final ext = '.${file.fileExtension}';
    final shareName =
        file.name.toLowerCase().endsWith(ext) ? file.name : '${file.name}$ext';

    // The drawing itself is shared through our own Kotlin path, NOT
    // share_plus: messaging apps must receive it typed application/octet-
    // stream. WhatsApp only re-opens document types it recognises — DWG isn't
    // one, but octet-stream (stored as ".bin") is — and share_plus overrides
    // whatever mime we pass with a CAD one WhatsApp then refuses to open.
    if (!withPhotos) {
      try {
        await const MethodChannel('fastdwg/dwg_renderer')
            .invokeMethod('shareDrawing', {'path': path, 'name': shareName});
        return;
      } catch (_) {
        // Fall through to the share_plus sheet below.
      }
    }

    final files = [XFile(path, name: shareName)];
    if (withPhotos) {
      final notes = await PhotosRepository().load(file.id);
      files.addAll(notes
          .map((n) => n.path)
          .where((p) => p.isNotEmpty && File(p).existsSync())
          .map(XFile.new));
    }
    await Share.shareXFiles(files);
  }

  Future<void> _showLocation(BuildContext context) async {
    final path = _localPath() ?? file.uri;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.bgDeep,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          tr('File location', 'Dosya konumu'),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              path,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Text(
              tr(
                  'Opened drawings are kept in the app\'s own storage, so file '
                      'managers cannot browse this folder.',
                  'Açılan çizimler uygulamanın kendi depolama alanında '
                      'saklanır; dosya yöneticileri bu klasörü göremez.'),
              style:
                  const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: Text(
              tr('Copy path', 'Yolu kopyala'),
              style: const TextStyle(color: AppColors.accentPrimary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              tr('Close', 'Kapat'),
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  /// Asks the user to confirm deleting [name] — the file itself, not just the
  /// list entry. Returns true only on an explicit "Delete" tap.
  Future<bool?> _confirmDelete(BuildContext context, String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgDeep,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          tr('Delete file?', 'Dosya silinsin mi?'),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 18),
        ),
        content: Text(
          tr('"$name" will be deleted from the device.',
              '"$name" cihazdan silinecek.'),
          style: const TextStyle(color: AppColors.textMuted, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              tr('Cancel', 'Vazgeç'),
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              tr('Delete', 'Sil'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// "26.03M" / "412K" file-manager style; null when the size is unknown.
  String? _sizeText(RecentFile file) {
    final bytes = file.fileSizeBytes;
    if (bytes == null || bytes <= 0) return null;
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}K';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)}M';
  }

  /// "2026-02-14 19:23" — absolute timestamp of the last open.
  String _dateText(RecentFile file) {
    final t = file.lastOpenedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// Leading glyph for a file row: a document sheet with a folded corner and the
/// extension (DWG/DXF/PDF) written on it, tinted per type from the app palette.
class _FileTypeBadge extends StatelessWidget {
  const _FileTypeBadge({required this.extension});

  final String extension;

  @override
  Widget build(BuildContext context) {
    final ext = extension.toUpperCase();
    final color = switch (ext) {
      'PDF' => const Color(0xFFE58B8B),
      'DXF' => AppColors.accentSecondary,
      _ => const Color(0xFF3FC9D6),
    };
    return SizedBox(
      width: 32,
      height: 40,
      child: Stack(
        children: [
          // Document sheet with a clipped (folded) top-right corner.
          Positioned.fill(
            child: CustomPaint(painter: _DocSheetPainter(color: color)),
          ),
          Align(
            alignment: const Alignment(0, 0.55),
            child: Text(
              ext.length > 3 ? ext.substring(0, 3) : ext,
              style: TextStyle(
                color: color,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the outlined document-with-folded-corner shape behind the extension
/// label. Fill stays on the app's dark surface so only the outline carries the
/// type colour.
class _DocSheetPainter extends CustomPainter {
  const _DocSheetPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const fold = 9.0;
    const r = 3.0;
    final w = size.width;
    final h = size.height;

    final sheet = Path()
      ..moveTo(r, 0)
      ..lineTo(w - fold, 0)
      ..lineTo(w, fold)
      ..lineTo(w, h - r)
      ..quadraticBezierTo(w, h, w - r, h)
      ..lineTo(r, h)
      ..quadraticBezierTo(0, h, 0, h - r)
      ..lineTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..close();

    canvas.drawPath(
      sheet,
      Paint()
        ..color = AppColors.surface1
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      sheet,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    // Fold flap: small triangle over the clipped corner.
    final flap = Path()
      ..moveTo(w - fold, 0)
      ..lineTo(w - fold, fold)
      ..lineTo(w, fold)
      ..close();
    canvas.drawPath(
      flap,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_DocSheetPainter oldDelegate) =>
      oldDelegate.color != color;
}
