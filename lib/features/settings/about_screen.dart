import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../shared/widgets/blueprint_background.dart';
import '../../shared/widgets/cad_panel.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radii.dart';

/// About page: what the app is, version, and the open-source licenses —
/// including the LibreDWG GPL notice that redistribution requires.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(title: Text(tr('About', 'Hakkında'))),
      body: BlueprintBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            CadPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppColors.bgMain,
                          borderRadius: BorderRadius.circular(AppRadii.chip),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: const Icon(Icons.architecture,
                            color: AppColors.accentPrimary, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            AppConstants.appName,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${tr('Version', 'Sürüm')} ${AppConstants.appVersion}',
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 13),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    tr(
                        'A fast, offline DWG viewer. Open AutoCAD drawings, '
                            'browse layers, measure in the drawing\'s own '
                            'units and export — everything stays on your '
                            'device.',
                        'Hızlı, çevrimdışı bir DWG görüntüleyici. AutoCAD '
                            'çizimlerini aç, katmanları incele, çizimin kendi '
                            'biriminde ölç ve dışa aktar — her şey cihazında '
                            'kalır.'),
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13.5,
                        height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            CadPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Open source', 'Açık kaynak'),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                        'DWG parsing is powered by GNU LibreDWG (GPLv3). '
                            'FastDWG ships with complete corresponding source; '
                            'the combined work is distributed under '
                            'GPL-compatible terms.',
                        'DWG çözümleme GNU LibreDWG (GPLv3) ile yapılır. '
                            'FastDWG, karşılık gelen kaynak koduyla birlikte '
                            'dağıtılır; birleşik çalışma GPL uyumlu koşullarla '
                            'sunulur.'),
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        height: 1.5),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: AppConstants.appName,
                        applicationVersion: AppConstants.appVersion,
                      ),
                      icon: const Icon(Icons.description_outlined, size: 18),
                      label: Text(tr(
                          'Third-party licenses', 'Üçüncü taraf lisansları')),
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
