import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/l10n/l10n.dart';
import '../../data/models/photo_note.dart';
import '../../data/repositories/photos_repository.dart';
import '../../shared/widgets/technical_chip.dart';
import '../../theme/app_colors.dart';

/// Text-entry dialog shared by the pin flow and the list sheet (new note,
/// edit note, photo caption).
Future<String?> showPhotoTextDialog(
  BuildContext context, {
  required String title,
  required String confirm,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.bgDeep,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 18),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 4,
        minLines: 1,
        style: const TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: tr('Write here…', 'Buraya yaz…'),
          hintStyle: const TextStyle(color: AppColors.textMuted),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.accentPrimary),
          ),
        ),
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
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: Text(
            confirm,
            style: const TextStyle(color: AppColors.accentPrimary),
          ),
        ),
      ],
    ),
  );
}

/// Delete confirmation for a photo or note. Resolves to true when confirmed.
Future<bool> confirmDeletePhotoNote(
  BuildContext context, {
  required bool isPhoto,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.bgDeep,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        isPhoto
            ? tr('Delete this photo?', 'Bu fotoğraf silinsin mi?')
            : tr('Delete this note?', 'Bu not silinsin mi?'),
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 18),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(
            tr('Cancel', 'Vazgeç'),
            style: const TextStyle(color: AppColors.textMuted),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            tr('Delete', 'Sil'),
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Bottom sheet listing the photos and notes pinned to a drawing. Adding
/// happens by tapping the drawing in photo mode; this sheet is for browsing,
/// editing captions and deleting. Mutations are persisted immediately and the
/// caller is told via [onChanged] so the pins on the drawing stay in sync.
class PhotoNotesSheet extends StatefulWidget {
  const PhotoNotesSheet({
    super.key,
    required this.fileId,
    required this.notes,
    this.onChanged,
    this.onLocateTap,
  });

  final String fileId;
  final List<PhotoNote> notes;
  final ValueChanged<List<PhotoNote>>? onChanged;

  /// Called with a note when the user wants to see its pin on the drawing;
  /// the sheet closes itself first.
  final ValueChanged<PhotoNote>? onLocateTap;

  @override
  State<PhotoNotesSheet> createState() => _PhotoNotesSheetState();
}

class _PhotoNotesSheetState extends State<PhotoNotesSheet> {
  final PhotosRepository _repo = PhotosRepository();
  late List<PhotoNote> _notes = List.of(widget.notes);

  Future<void> _persist() async {
    await _repo.save(widget.fileId, _notes);
    widget.onChanged?.call(List.of(_notes));
  }

  Future<void> _editNote(PhotoNote note) async {
    final isPhoto = note.path.isNotEmpty;
    final text = await showPhotoTextDialog(
      context,
      title: isPhoto
          ? tr('Photo caption', 'Fotoğraf açıklaması')
          : tr('Edit note', 'Notu düzenle'),
      confirm: tr('Save', 'Kaydet'),
      initial: note.caption,
    );
    if (text == null || !mounted) return;
    setState(() {
      _notes = [
        for (final n in _notes)
          if (n.id == note.id) n.copyWith(caption: text.trim()) else n,
      ];
    });
    await _persist();
  }

  Future<void> _delete(PhotoNote note) async {
    final ok =
        await confirmDeletePhotoNote(context, isPhoto: note.path.isNotEmpty);
    if (!ok || !mounted) return;
    if (note.path.isNotEmpty) await _repo.deleteImageFile(note.path);
    setState(() => _notes = [for (final n in _notes) if (n.id != note.id) n]);
    await _persist();
  }

  void _viewPhoto(PhotoNote note) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(
        note: note,
        onCaptionTap: () => _editNote(note),
        onDeleteTap: () => _delete(note),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final photos = _notes.where((n) => n.path.isNotEmpty).length;
    final texts = _notes.length - photos;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(
                children: [
                  const TechnicalChip(
                      label: 'FOTO & NOT', icon: Icons.photo_camera_outlined),
                  const Spacer(),
                  Text(
                    '$photos ${tr('photo', 'foto')} · $texts ${tr('note', 'not')}',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.border, height: 1),
            Expanded(
              child: _notes.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          tr(
                              'No photos or notes yet. Tap a spot on the '
                                  'drawing to pin one there.',
                              'Henüz foto veya not yok. Çizimde bir yere '
                                  'dokunarak oraya iğnele.'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                              height: 1.5),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                      itemCount: _notes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        // Newest first.
                        final note = _notes[_notes.length - 1 - i];
                        return _NoteTile(
                          note: note,
                          onTap: note.path.isNotEmpty
                              ? () => _viewPhoto(note)
                              : () => _editNote(note),
                          onLocate: widget.onLocateTap == null
                              ? null
                              : () {
                                  Navigator.of(context).pop();
                                  widget.onLocateTap!(note);
                                },
                          onDelete: () => _delete(note),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.note,
    this.onTap,
    this.onLocate,
    this.onDelete,
  });

  final PhotoNote note;
  final VoidCallback? onTap;
  final VoidCallback? onLocate;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final isPhoto = note.path.isNotEmpty;
    final date =
        '${note.createdAt.day.toString().padLeft(2, '0')}.${note.createdAt.month.toString().padLeft(2, '0')}.${note.createdAt.year}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.bgDeep.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            if (isPhoto)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(note.path),
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 56,
                    height: 56,
                    color: AppColors.border,
                    child: const Icon(Icons.broken_image_outlined,
                        color: AppColors.textMuted),
                  ),
                ),
              )
            else
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.accentSecondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.sticky_note_2_outlined,
                    color: AppColors.accentSecondary),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.caption.isNotEmpty
                        ? note.caption
                        : tr('Add a caption…', 'Açıklama ekle…'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: note.caption.isNotEmpty
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    date,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (onLocate != null)
              IconButton(
                onPressed: onLocate,
                tooltip: tr('Show on drawing', 'Çizimde göster'),
                icon: const Icon(Icons.my_location,
                    size: 20, color: AppColors.accentSecondary),
              ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline,
                  size: 20, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen photo view with pinch-zoom, caption edit, share and delete.
class PhotoViewerPage extends StatelessWidget {
  const PhotoViewerPage({
    super.key,
    required this.note,
    this.onCaptionTap,
    this.onDeleteTap,
  });

  final PhotoNote note;
  final VoidCallback? onCaptionTap;
  final VoidCallback? onDeleteTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            onPressed: () => Share.shareXFiles([XFile(note.path)]),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              Navigator.of(context).pop();
              onDeleteTap?.call();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: Image.file(
                  File(note.path),
                  errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: AppColors.textMuted,
                      size: 48),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: InkWell(
              onTap: () {
                Navigator.of(context).pop();
                onCaptionTap?.call();
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text(
                  note.caption.isNotEmpty
                      ? note.caption
                      : tr('Tap to add a caption',
                          'Açıklama eklemek için dokun'),
                  style: TextStyle(
                    color: note.caption.isNotEmpty
                        ? Colors.white
                        : AppColors.textMuted,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
