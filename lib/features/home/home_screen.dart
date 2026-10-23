import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../features/app/app_controller.dart';
import '../../features/recent_files/recent_drawings_panel.dart';
import '../../features/recent_files/recents_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/viewer/viewer_screen.dart';
import '../../shared/widgets/blueprint_background.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radii.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  // Anchors the Recent Drawings panel so the "Recents" bottom-nav tab can scroll
  // it into view.
  final GlobalKey _recentsKey = GlobalKey();
  String _query = '';
  AppController? _controller;

  @override
  void initState() {
    super.initState();
    // Listen so a drawing shared/opened while the app is ALREADY running (warm
    // start → onNewIntent → notifyListeners) auto-opens too — not just the cold
    // start handled by the post-frame call below.
    _controller = context.read<AppController>()..addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingIncomingFile());
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_controller?.pendingIncomingFile == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingIncomingFile());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingIncomingFile());
  }

  Future<void> _openPendingIncomingFile() async {
    if (!mounted) return;
    final controller = context.read<AppController>();
    final file = controller.pendingIncomingFile;
    if (file == null) return;
    await controller.consumePendingIncomingFile();
    if (!mounted) return;
    // Any file opened (incl. from WhatsApp / share) lands in Recent Drawings.
    controller.addOrRefreshRecentFile(file);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ViewerScreen(file: file)),
    );
  }

  Future<void> _openFile() async {
    final controller = context.read<AppController>();
    final file = await controller.pickDwgFile();
    if (!mounted) return;
    if (file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Could not open the file. Please choose a .dwg file.',
              'Dosya açılamadı. Lütfen bir .dwg dosyası seçin.')),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    controller.addOrRefreshRecentFile(file);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ViewerScreen(file: file)),
    );
  }

  void _onBottomNavTap(int index) {
    switch (index) {
      case 0: // Files → open the system file picker directly. The big "Open
        // DWG File" button does the same, but from the bottom bar it works
        // without scrolling back up — and the tab isn't a dead duplicate.
        setState(() => _selectedIndex = 0);
        _openFile();
      case 1: // Recents → full-screen list with sorting and a pinned group
        setState(() => _selectedIndex = 1);
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const RecentsScreen()),
        );
      case 2: // Settings → open the settings screen (tab highlight unchanged)
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild the WHOLE screen on controller changes — the language setting
    // loads asynchronously, and without this only the Consumer subtree picked
    // up the new language, leaving the header/nav half in the old one.
    context.watch<AppController>();
    return Scaffold(
      extendBody: true,
      body: ColoredBox(
        color: AppColors.bgDeep,
        child: BlueprintBackground(
          child: SafeArea(
            child: Column(
              children: [
                const _TopBar(),
                // The call-to-action and search stay PINNED; only the drawings
                // list below scrolls (long lists used to push them off-screen).
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                  child: Column(
                    children: [
                      _OpenDwgButton(onTap: _openFile),
                      const SizedBox(height: 16),
                      _SearchBar(
                        controller: _searchController,
                        onChanged: (value) => setState(() => _query = value),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 100),
                    children: [
                      KeyedSubtree(
                        key: _recentsKey,
                        child: Consumer<AppController>(
                          builder: (context, controller, _) {
                            final q = _query.trim().toLowerCase();
                            final files = q.isEmpty
                                ? controller.recentFiles
                                : controller.recentFiles
                                    .where((f) => f.name.toLowerCase().contains(q))
                                    .toList();
                            return RecentDrawingsPanel(
                              files: files,
                              onOpen: (file) {
                                // Open the viewer immediately; refreshing the
                                // recents list is fire-and-forget so the tap feels
                                // instant instead of waiting on a disk write.
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ViewerScreen(file: file),
                                  ),
                                );
                                controller.addOrRefreshRecentFile(file);
                              },
                              onPin: controller.togglePinned,
                              onRemove: controller.removeRecentFile,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _TechnicalBottomNav(
        selectedIndex: _selectedIndex,
        onTap: _onBottomNavTap,
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Just the app title: Open lives in the big body button, Settings in the
      // bottom nav. A serif face + soft cyan glow gives the premium CAD wordmark.
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 10),
      child: Text(
        AppConstants.appName,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontFamily: 'serif',
          fontSize: 34,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          shadows: [
            Shadow(
              color: AppColors.accentPrimary.withValues(alpha: 0.5),
              blurRadius: 20,
            ),
            Shadow(
              color: AppColors.accentGlow.withValues(alpha: 0.3),
              blurRadius: 38,
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadii.input),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, color: AppColors.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              cursorColor: AppColors.accentPrimary,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: tr('Search drawings', 'Çizim ara'),
                hintStyle: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: const Icon(Icons.close, color: AppColors.textSecondary, size: 20),
            ),
        ],
      ),
    );
  }
}

/// The primary call-to-action on the home screen: a glowing cyan card that
/// launches the system file picker. Mirrors AutoCAD's "open drawing" affordance
/// and gives a fresh install an obvious first step.
class _OpenDwgButton extends StatelessWidget {
  const _OpenDwgButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.panel),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.panel),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3FC9D6), Color(0xFF1E8A97)],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.accentPrimary.withValues(alpha: 0.35),
                blurRadius: 24,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.folder_open_outlined,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('Open DWG File', 'DWG Dosyası Aç'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tr('Browse files from your device',
                        'Cihazındaki dosyalara göz at'),
                    style: const TextStyle(
                      color: Color(0xFFE6FBFF),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TechnicalBottomNav extends StatelessWidget {
  const _TechnicalBottomNav({
    required this.selectedIndex,
    required this.onTap,
  });

  final int selectedIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.folder_outlined, tr('Files', 'Dosyalar')),
      (Icons.history, tr('Recents', 'Son Açılanlar')),
      (Icons.settings_outlined, tr('Settings', 'Ayarlar')),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgMain,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 72,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: items.indexed.map((entry) {
              final active = entry.$1 == selectedIndex;
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(entry.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      boxShadow: active
                          ? [
                              BoxShadow(
                                color: AppColors.accentPrimary.withValues(alpha: 0.12),
                                blurRadius: 16,
                              ),
                            ]
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          entry.$2.$1,
                          color: active ? AppColors.accentPrimary : AppColors.textSecondary,
                          size: 22,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          entry.$2.$2,
                          style: TextStyle(
                            color: active ? AppColors.accentPrimary : AppColors.textSecondary,
                            fontSize: 11,
                            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
