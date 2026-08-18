import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';

/// [НОВОЕ v4 — самый критичный недостающий экран во всём приложении]
/// До этого файла в приложении НЕ БЫЛО ни одного экрана входа/регистрации —
/// главный экран открывался сразу поверх пустого `ApiClient()` без токена
/// (см. подробный разбор в services/api_client.dart). Это единственная
/// причина, по которой баланс/ключи/покупка/рефералка не могли
/// синхронизироваться, несмотря на то что backend был готов их отдавать.
///
/// Механизм — 1:1 с реальным сайтом vpnonline.su (проверено напрямую, не
/// придумано): вход по email+паролю, регистрация с подтверждением кода на
/// почту, сброс пароля тоже по коду на почту.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.onAuthenticated});
  final VoidCallback onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Mode { login, register, registerConfirm, resetRequest, resetConfirm }

class _AuthScreenState extends State<AuthScreen> {
  final _api = ApiClient.instance;

  _Mode _mode = _Mode.login;
  final _emailCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();

  bool _loading = false;
  String? _error;
  String? _info;

  Future<void> _run(Future<void> Function() action, {String? successInfo, _Mode? nextMode}) async {
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await action();
      if (mounted) {
        setState(() {
          _loading = false;
          if (successInfo != null) _info = successInfo;
          if (nextMode != null) _mode = nextMode;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.message; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Не удалось выполнить запрос: $e'; });
    }
  }

  Future<void> _login() => _run(() async {
        await _api.login(email: _emailCtrl.text.trim(), password: _passwordCtrl.text);
        widget.onAuthenticated();
      });

  // [ИСПРАВЛЕНО] Реальный /auth/register/send-code принимает только email —
  // пароль и имя пользователя реальный сервер запрашивает позже, вместе с
  // кодом, одним вызовом /auth/register. Раньше здесь передавались
  // username/password на этом шаге — эндпоинта с такими параметрами на
  // сервере нет, это был вызов в никуда (сгенерированный под придуманный
  // контракт API, а не проверенный по реальному коду).
  Future<void> _registerRequestCode() => _run(
        () => _api.registerSendCode(_emailCtrl.text.trim()),
        successInfo: 'Код отправлен на почту (если такой email ещё не зарегистрирован)',
        nextMode: _Mode.registerConfirm,
      );

  Future<void> _registerConfirm() => _run(() async {
        await _api.register(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
          code: _codeCtrl.text.trim(),
          username: _usernameCtrl.text.trim().isEmpty ? null : _usernameCtrl.text.trim(),
        );
        widget.onAuthenticated();
      });

  Future<void> _resetRequestCode() => _run(
        () => _api.resetPasswordSendCode(_emailCtrl.text.trim()),
        successInfo: 'Если аккаунт с таким email существует — код отправлен на почту',
        nextMode: _Mode.resetConfirm,
      );

  Future<void> _resetConfirm() => _run(
        () => _api.resetPasswordConfirm(
          email: _emailCtrl.text.trim(),
          code: _codeCtrl.text.trim(),
          newPassword: _newPasswordCtrl.text,
        ),
        successInfo: 'Пароль обновлён — теперь можно войти',
        nextMode: _Mode.login,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.violet2, width: 2),
                        boxShadow: AppColors.glow(AppColors.violet2, blur: 16, alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 12),
                    RichText(
                      text: TextSpan(
                        style: orbitron(fontSize: 20, fontWeight: FontWeight.w700),
                        children: [
                          const TextSpan(text: 'VPN'),
                          TextSpan(text: 'onLine', style: orbitron(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.violet2)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Text(_title(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Text(_subtitle(), style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
              const SizedBox(height: 18),
              NeonCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _fields())),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
              ],
              if (_info != null) ...[
                const SizedBox(height: 10),
                Text(_info!, style: const TextStyle(color: AppColors.success, fontSize: 12)),
              ],
              const SizedBox(height: 18),
              _loading
                  ? const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
                  : ElevatedButton(onPressed: _primaryAction(), child: Text(_primaryLabel())),
              const SizedBox(height: 14),
              _secondaryActions(),
            ],
          ),
        ),
      ),
    );
  }

  String _title() {
    switch (_mode) {
      case _Mode.login: return 'Вход в кабинет';
      case _Mode.register: return 'Создать аккаунт';
      case _Mode.registerConfirm: return 'Подтверждение почты';
      case _Mode.resetRequest: return 'Сброс пароля';
      case _Mode.resetConfirm: return 'Новый пароль';
    }
  }

  String _subtitle() {
    switch (_mode) {
      case _Mode.login: return 'Тот же аккаунт, что на сайте и в Telegram-боте';
      case _Mode.register: return 'Один аккаунт — сайт, бот и приложение';
      case _Mode.registerConfirm: return 'Введи код из письма (проверь папку «Спам»)';
      case _Mode.resetRequest: return 'Введи email — пришлём код для восстановления';
      case _Mode.resetConfirm: return 'Код из письма и новый пароль (минимум 6 символов)';
    }
  }

  List<Widget> _fields() {
    switch (_mode) {
      case _Mode.login:
        return [
          _field(_emailCtrl, 'Email адрес', keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 10),
          _field(_passwordCtrl, 'Пароль', obscure: true),
        ];
      case _Mode.register:
        return [
          _field(_emailCtrl, 'Email адрес', keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 10),
          _field(_usernameCtrl, 'Имя пользователя (необязательно)'),
          const SizedBox(height: 10),
          _field(_passwordCtrl, 'Пароль', obscure: true),
        ];
      case _Mode.registerConfirm:
        return [_field(_codeCtrl, 'Код из письма', keyboardType: TextInputType.number)];
      case _Mode.resetRequest:
        return [_field(_emailCtrl, 'Email адрес', keyboardType: TextInputType.emailAddress)];
      case _Mode.resetConfirm:
        return [
          _field(_codeCtrl, 'Код из письма', keyboardType: TextInputType.number),
          const SizedBox(height: 10),
          _field(_newPasswordCtrl, 'Новый пароль (минимум 6 символов)', obscure: true),
        ];
    }
  }

  Widget _field(TextEditingController ctrl, String label, {bool obscure = false, TextInputType? keyboardType}) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 13, color: AppColors.text),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12, color: AppColors.textDim),
        filled: true,
        fillColor: const Color(0xFF0A0614),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.violet2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  VoidCallback _primaryAction() {
    switch (_mode) {
      case _Mode.login: return _login;
      case _Mode.register: return _registerRequestCode;
      case _Mode.registerConfirm: return _registerConfirm;
      case _Mode.resetRequest: return _resetRequestCode;
      case _Mode.resetConfirm: return _resetConfirm;
    }
  }

  String _primaryLabel() {
    switch (_mode) {
      case _Mode.login: return 'Войти в аккаунт';
      case _Mode.register: return 'Зарегистрироваться';
      case _Mode.registerConfirm: return 'Подтвердить';
      case _Mode.resetRequest: return 'Получить код';
      case _Mode.resetConfirm: return 'Сбросить пароль';
    }
  }

  Widget _secondaryActions() {
    void switchTo(_Mode m) => setState(() { _mode = m; _error = null; _info = null; });

    switch (_mode) {
      case _Mode.login:
        return Column(
          children: [
            Center(
              child: TextButton(
                onPressed: () => switchTo(_Mode.register),
                child: const Text('Нет аккаунта? Создать аккаунт', style: TextStyle(color: AppColors.violetGlow, fontSize: 12)),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => switchTo(_Mode.resetRequest),
                child: const Text('Забыли пароль?', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
              ),
            ),
          ],
        );
      case _Mode.register:
        return Center(
          child: TextButton(
            onPressed: () => switchTo(_Mode.login),
            child: const Text('Уже есть аккаунт? Войти в кабинет', style: TextStyle(color: AppColors.violetGlow, fontSize: 12)),
          ),
        );
      case _Mode.registerConfirm:
        return Center(
          child: TextButton(
            onPressed: () => switchTo(_Mode.register),
            child: const Text('Отмена', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          ),
        );
      case _Mode.resetRequest:
      case _Mode.resetConfirm:
        return Center(
          child: TextButton(
            onPressed: () => switchTo(_Mode.login),
            child: const Text('Вернуться ко входу', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          ),
        );
    }
  }
}
