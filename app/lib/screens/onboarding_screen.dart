import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';

/// [НОВОЕ] Раньше приложение открывалось сразу на боевом экране без единого
/// слова о том, что это, зачем платить и чем протокол лучше конкурентов —
/// прямой удар по конверсии в первую покупку. Показывается один раз,
/// флаг хранится в SharedPreferences (переживает перезапуск приложения).
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  static const _prefsKey = 'onboarding_seen_v1';

  static Future<bool> shouldShow() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_prefsKey) ?? false);
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _slides = [
    (
      icon: Icons.shield_rounded,
      title: 'Приватность без компромиссов',
      body: 'VLESS · Reality — протокол, который маскирует VPN-трафик под обычный HTTPS. Никаких логов активности.',
    ),
    (
      icon: Icons.bolt_rounded,
      title: 'Без просадки скорости',
      body: 'Автобалансировка между локациями подбирает самый быстрый сервер для тебя прямо сейчас.',
    ),
    (
      icon: Icons.group_rounded,
      title: 'Приглашай — экономь',
      body: 'Реферальная программа начисляет бонус на баланс за каждого друга, который оформит платный тариф.',
    ),
  ];

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OnboardingScreen._prefsKey, true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text('Пропустить', style: TextStyle(color: AppColors.textDim)),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final s = _slides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(s.icon, size: 72, color: AppColors.violet2),
                        const SizedBox(height: 24),
                        Text(s.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Text(s.body,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.textDim, fontSize: 14)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _slides.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _page == i ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _page == i ? AppColors.violet2 : AppColors.textDim,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    if (_page < _slides.length - 1) {
                      _controller.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
                    } else {
                      _finish();
                    }
                  },
                  child: Text(_page < _slides.length - 1 ? 'Далее' : 'Начать'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
