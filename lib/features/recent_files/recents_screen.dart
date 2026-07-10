import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/recent_file.dart';
import '../../shared/widgets/blueprint_background.dart';
import '../../theme/app_colors.dart';
import '../app/app_controller.dart';
import '../viewer/viewer_screen.dart';
import 'recent_drawings_panel.dart';

/// Full-screen recents: everything the home panel shows, plus sorting and a
/// separate "Pinned" group so favourites stay on top regardless of sort.
class RecentsScreen extends StatefulWidget {
  const RecentsScreen({super.key});

  @override
  State<RecentsScreen> createState() => _RecentsScreenState();
}

enum _SortBy { lastOpened, name, size }

class _RecentsScreenState extends State<RecentsScreen> {
  _SortBy _sortBy = _SortBy.lastOpened;

  List<RecentFile> _sorted(List<RecentFile> files) {
    final list = [...files];
    switch (_sortBy) {
      case _SortBy.lastOpened:
        list.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
      case _SortBy.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _SortBy.size:
        list.sort((a, b) =>
            (b.fileSizeBytes ?? 0).compareTo(a.fileSizeBytes ?? 0));
    }
    return list;
  }

  void _open(BuildContext context, RecentFile file) {
    final controller = context.read<AppController>();
    controller.addOrRefreshRecentFile(file);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ViewerScreen(file: file)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final pinned = _sorted(
        controller.recentFiles.where((f) => f.isPinned).toList());
    final others = _sorted(
        controller.recentFiles.where((f) => !f.isPinned).toList());

    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(title: const Text('Recents')),
      body: BlueprintBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              children: [
                const Text(
                  'Sort by',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
                const SizedBox(width: 10),
                _SortChip(
                  label: 'Recent',
                  selected: _sortBy == _SortBy.lastOpened,
                  onTap: () => setState(() => _sortBy = _SortBy.lastOpened),
                ),
                const SizedBox(width: 8),
                _SortChip(
                  label: 'Name',
                  selected: _sortBy == _SortBy.name,
                  onTap: () => setState(() => _sortBy = _SortBy.name),
                ),
                const SizedBox(width: 8),
                _SortChip(
                  label: 'Size',
                  selected: _sortBy == _SortBy.size,
                  onTap: () => setState(() => _sortBy = _SortBy.size),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (pinned.isNotEmpty) ...[
              RecentDrawingsPanel(
                title: 'Pinned',
                files: pinned,
                onOpen: (f) => _open(context, f),
                onPin: controller.togglePinned,
                onRemove: controller.removeRecentFile,
              ),
              const SizedBox(height: 14),
            ],
            RecentDrawingsPanel(
              title: pinned.isEmpty ? 'All drawings' : 'Others',
              files: others,
              onOpen: (f) => _open(context, f),
              onPin: controller.togglePinned,
              onRemove: controller.removeRecentFile,
            ),
          ],
        ),
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentPrimary : AppColors.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accentPrimary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.bgDeep : AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
