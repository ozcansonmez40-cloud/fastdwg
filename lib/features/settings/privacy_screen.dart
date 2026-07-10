import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../shared/widgets/blueprint_background.dart';
import '../../shared/widgets/cad_panel.dart';
import '../../theme/app_colors.dart';

/// In-app privacy statement. FastDWG is fully offline, so the policy is
/// short and verifiable: nothing leaves the device.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(title: Text(tr('Privacy', 'Gizlilik'))),
      body: BlueprintBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            CadPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PrivacyItem(
                    icon: Icons.smartphone_outlined,
                    title: tr('Everything stays on your device',
                        'Her şey cihazında kalır'),
                    body: tr(
                        'Drawings, previews, measurements and settings are '
                            'stored only in this app\'s private storage. '
                            'Nothing is uploaded anywhere.',
                        'Çizimler, önizlemeler, ölçümler ve ayarlar yalnızca '
                            'bu uygulamanın özel depolamasında tutulur. '
                            'Hiçbir yere yüklenmez.'),
                  ),
                  _PrivacyItem(
                    icon: Icons.person_off_outlined,
                    title: tr('No account, no tracking', 'Hesap yok, takip yok'),
                    body: tr(
                        'No login, no analytics, no advertising ID. The app '
                            'works entirely offline.',
                        'Giriş yok, analitik yok, reklam kimliği yok. '
                            'Uygulama tamamen çevrimdışı çalışır.'),
                  ),
                  _PrivacyItem(
                    icon: Icons.folder_open_outlined,
                    title: tr('Minimal file access', 'Asgari dosya erişimi'),
                    body: tr(
                        'FastDWG only reads the files you explicitly pick or '
                            'share into it. It does not request broad storage '
                            'permission and cannot browse your files on its '
                            'own.',
                        'FastDWG yalnızca senin seçtiğin veya paylaştığın '
                            'dosyaları okur. Geniş depolama izni istemez, '
                            'dosyalarında kendi başına gezinemez.'),
                  ),
                  _PrivacyItem(
                    icon: Icons.delete_outline,
                    title: tr('Your data, your control', 'Veri senin, kontrol sende'),
                    body: tr(
                        'Removing a drawing from Recents or clearing the '
                            'cache deletes the app\'s local copies. '
                            'Uninstalling the app removes everything.',
                        'Bir çizimi listeden silmek veya önbelleği '
                            'temizlemek yerel kopyaları siler. Uygulamayı '
                            'kaldırmak her şeyi kaldırır.'),
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

class _PrivacyItem extends StatelessWidget {
  const _PrivacyItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.accentSecondary, size: 22),
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
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
