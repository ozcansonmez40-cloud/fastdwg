import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../core/l10n/l10n.dart';
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
      appBar: AppBar(title: Text(tr('Settings', 'Ayarlar'))),
      body: BlueprintBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            CadPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(tr('Theme mode', 'Tema')),
                  const SizedBox(height: 12),
                  SegmentedButton<ThemeMode>(
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text(tr('Dark', 'Koyu')),
                        icon: const Icon(Icons.dark_mode_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text(tr('System', 'Sistem')),
                        icon: const Icon(Icons.phone_android_outlined),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(tr('Language', 'Dil')),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final (code, label) in const [
                        ('system', null), // label resolved below (localized)
                        ('tr', 'Türkçe'),
                        ('en', 'English'),
                      ])
                        _LanguageChip(
                          label: label ?? tr('System', 'Sistem'),
                          selected: controller.settings.language == code,
                          onTap: () => controller.updateLanguage(code),
                        ),
                    ],
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
                    title: tr('Local storage', 'Yerel depolama'),
                    subtitle: tr(
                        'Space used by previews, parsed scenes and '
                            'cached drawings on this device.',
                        'Önizlemeler, işlenmiş sahneler ve önbellekteki '
                            'çizimlerin bu cihazda kapladığı alan.'),
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
                    title: tr('Clear cache', 'Önbelleği temizle'),
                    subtitle: tr(
                        'Clears generated drawing previews to free space. '
                            'Your drawings are kept.',
                        'Yer açmak için üretilen önizlemeleri siler. '
                            'Çizimlerin korunur.'),
                    trailing: TextButton(
                      onPressed: () async {
                        await controller.clearCache();
                        if (!context.mounted) return;
                        _refreshUsage();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                tr('Cache cleared.', 'Önbellek temizlendi.')),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Text(tr('Clear', 'Temizle')),
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
                    icon: Icons.workspace_premium_outlined,
                    title: 'Premium',
                    subtitle: tr(
                        'Future advanced viewer tools and export options.',
                        'Gelecekte: gelişmiş görüntüleme ve dışa aktarma '
                            'araçları.'),
                    trailing: TechnicalChip(
                        label: tr('PLANNED', 'PLANLI'), compact: true),
                  ),
                  const Divider(color: AppColors.border),
                  _SettingsTile(
                    icon: Icons.privacy_tip_outlined,
                    title: tr('Privacy-first', 'Önce gizlilik'),
                    subtitle: tr(
                        'No login, no cloud sync, no broad storage permission.',
                        'Giriş yok, bulut yok, geniş depolama izni yok.'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                    ),
                  ),
                  const Divider(color: AppColors.border),
                  _SettingsTile(
                    icon: Icons.info_outline,
                    title: tr('About FastDWG', 'FastDWG Hakkında'),
                    subtitle:
                        '${tr('Version', 'Sürüm')} ${AppConstants.appVersion} · '
                        '${tr('open source & licenses', 'açık kaynak ve lisanslar')}',
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

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
