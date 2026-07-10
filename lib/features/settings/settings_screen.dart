import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../features/app/app_controller.dart';
import 'about_screen.dart';
import 'privacy_screen.dart';
import '../../shared/widgets/blueprint_background.dart';
import '../../shared/widgets/cad_panel.dart';
import '../../shared/widgets/technical_chip.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radii.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Real bytes on disk (previews + parsed scenes + cached drawings).
  // Recomputed when the screen opens and after Clear cache.
  Future<int>? _usageBytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _usageBytes ??=
        context.read<AppController>().computeStorageUsageBytes();
  }

  void _refreshUsage() {
    setState(() {
      _usageBytes =
          context.read<AppController>().computeStorageUsageBytes();
    });
  }

  String _mb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();

    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(title: const Text('Settings')),
      body: BlueprintBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            CadPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle('Theme mode'),
                  const SizedBox(height: 12),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.phone_android_outlined),
                      ),
                    ],
                    // Light is removed (the screens are dark-only, so it had no
                    // visible effect). Map any previously-saved Light selection
                    // to Dark so the button always has a valid selection.
                    selected: {
                      controller.settings.themeMode == ThemeMode.light
                          ? ThemeMode.dark
                          : controller.settings.themeMode
                    },
                    onSelectionChanged: (selection) {
                      controller.updateThemeMode(selection.first);
                    },
                    style: ButtonStyle(
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        return states.contains(WidgetState.selected)
                            ? AppColors.bgDeep
                            : AppColors.textSecondary;
                      }),
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        return states.contains(WidgetState.selected)
                            ? AppColors.accentPrimary
                            : AppColors.surface1;
                      }),
                      side: WidgetStateProperty.all(
                        const BorderSide(color: AppColors.border),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            CadPanel(
              child: Column(
                children: [
                  _SettingsTile(
                    icon: Icons.storage_outlined,
                    title: 'Local storage',
                    subtitle: 'Space used by previews, parsed scenes and '
                        'cached drawings on this device.',
                    trailing: FutureBuilder<int>(
                      future: _usageBytes,
                      builder: (context, snap) => TechnicalChip(
                        label: snap.hasData ? _mb(snap.data!) : '…',
                        compact: true,
                      ),
                    ),
                  ),
                  const Divider(color: AppColors.border),
                  _SettingsTile(
                    icon: Icons.cleaning_services_outlined,
                    title: 'Clear cache',
                    subtitle: 'Clears generated drawing previews to free space. '
                        'Your drawings are kept.',
                    trailing: TextButton(
                      onPressed: () async {
                        await controller.clearCache();
                        if (!context.mounted) return;
                        _refreshUsage();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Cache cleared.'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: const Text('Clear'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            CadPanel(
              child: Column(
                children: [
                  const _SettingsTile(
                    icon: Icons.workspace_premium_outlined,
                    title: 'Premium',
                    subtitle: 'Future advanced viewer tools and export options.',
                    trailing: TechnicalChip(label: 'PLANNED', compact: true),
                  ),
                  const Divider(color: AppColors.border),
                  _SettingsTile(
                    icon: Icons.privacy_tip_outlined,
                    title: 'Privacy-first',
                    subtitle:
                        'No login, no cloud sync, no broad storage permission.',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                    ),
                  ),
                  const Divider(color: AppColors.border),
                  _SettingsTile(
                    icon: Icons.info_outline,
                    title: 'About FastDWG',
                    subtitle: 'Version ${AppConstants.appVersion} · '
                        'open source & licenses',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AboutScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.bgMain,
              borderRadius: BorderRadius.circular(AppRadii.chip),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(icon, color: AppColors.accentSecondary, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
          if (onTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right,
                color: AppColors.textMuted, size: 20),
          ],
        ],
      ),
    );
    if (onTap == null) return tile;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: tile,
    );
  }
}
