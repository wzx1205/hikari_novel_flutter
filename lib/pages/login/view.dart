import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/models/page_state.dart';
import 'package:hikari_novel_flutter/service/api_service.dart';
import 'package:hikari_novel_flutter/widgets/state_page.dart';

import 'controller.dart';

/// 原生登录页。
///
/// 不再走 WebView 表单 submit（会打 `login.php?do=submit`，CF 硬 403）。
/// 这里直接用 BrowserClient 打 `do=login`，与 iOS scripting 同款链路。
class LoginPage extends StatelessWidget {
  LoginPage({super.key});

  final controller = Get.put(LoginController());

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final error = controller.pageState.value == PageState.error;
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          leading: CloseButton(onPressed: Get.back),
          title: Text("login".tr),
        ),
        body: error
            ? ErrorMessage(
                msg: controller.errorMsg,
                action: () {
                  controller.pageState.value = PageState.success;
                  controller.errorMsg = "";
                },
                buttonText: "re_login".tr,
              )
            : _LoginForm(controller: controller),
      );
    });
  }
}

class _LoginForm extends StatefulWidget {
  const _LoginForm({required this.controller});

  final LoginController controller;

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // 默认保存 1 年（与 iOS scripting 一致）
  int _useCookieSeconds = 31536000;

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await widget.controller.doProgrammaticLogin(
      _userCtrl.text.trim(),
      _passCtrl.text,
      useCookieSeconds: _useCookieSeconds,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = ApiService.instance.wenku8Node;

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.lock_outline, size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    "login".tr,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    node.label,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _userCtrl,
                    autofillHints: const [AutofillHints.username],
                    decoration: InputDecoration(
                      labelText: "username".tr,
                      prefixIcon: const Icon(Icons.person_outline),
                      border: const OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) => (v == null || v.trim().isEmpty) ? "please_input_username".tr : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _passCtrl,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: "password".tr,
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) => (v == null || v.isEmpty) ? "please_input_password".tr : null,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int>(
                    initialValue: _useCookieSeconds,
                    decoration: InputDecoration(
                      labelText: "keep_login".tr,
                      prefixIcon: const Icon(Icons.schedule),
                      border: const OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text("不保存")),
                      DropdownMenuItem(value: 86400, child: Text("1 天")),
                      DropdownMenuItem(value: 2592000, child: Text("30 天")),
                      DropdownMenuItem(value: 31536000, child: Text("1 年")),
                    ],
                    onChanged: (v) => setState(() => _useCookieSeconds = v ?? 31536000),
                  ),
                  const SizedBox(height: 22),
                  Obx(() {
                    final busy = widget.controller.submitting.value;
                    return SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: busy ? null : _submit,
                        child: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text("login".tr),
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                  Text(
                    "login_via_browser_channel_tip".tr,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
