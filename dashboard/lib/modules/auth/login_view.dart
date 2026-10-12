import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_exception.dart';
import '../../core/env.dart';
import '../../core/services/session_service.dart';

class LoginController extends GetxController {
  LoginController(this.session);
  final SessionService session;

  final formKey = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  final submitting = false.obs;
  final error = RxnString();
  final obscure = true.obs;

  Future<void> submit() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    submitting.value = true;
    error.value = null;
    try {
      await session.login(email.text.trim(), password.text);
      final redirect = Get.parameters['redirect'];
      Get.offAllNamed(redirect != null && redirect.startsWith('/') && !redirect.startsWith('//') ? redirect : Routes.overview);
    } on ApiException catch (e) {
      error.value = e.status == 429 || e.code == 'account_locked' ? e.message : (e.isNetwork ? e.message : 'Invalid email or password.');
    } finally {
      submitting.value = false;
    }
  }

  @override
  void onClose() {
    email.dispose();
    password.dispose();
    super.onClose();
  }
}

class LoginView extends StatelessWidget {
  const LoginView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(LoginController(Get.find()));
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: AutofillGroup(
                  child: Form(
                    key: c.formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(Icons.hub_outlined, size: 40, color: theme.colorScheme.primary),
                        const SizedBox(height: 12),
                        Text(
                          Env.appName,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text('Sign in to manage your apps', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 28),
                        Obx(
                          () => c.error.value == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.errorContainer,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(c.error.value!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                                    ),
                                  ),
                                ),
                        ),
                        TextFormField(
                          key: const Key('login-email'),
                          controller: c.email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.username, AutofillHints.email],
                          decoration: const InputDecoration(labelText: 'Email'),
                          textInputAction: TextInputAction.next,
                          validator: (v) =>
                              (v == null || !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) ? 'Enter a valid email' : null,
                        ),
                        const SizedBox(height: 16),
                        Obx(
                          () => TextFormField(
                            key: const Key('login-password'),
                            controller: c.password,
                            obscureText: c.obscure.value,
                            autofillHints: const [AutofillHints.password],
                            decoration: InputDecoration(
                              labelText: 'Password',
                              suffixIcon: IconButton(
                                tooltip: c.obscure.value ? 'Show password' : 'Hide password',
                                icon: Icon(c.obscure.value ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                                onPressed: c.obscure.toggle,
                              ),
                            ),
                            onFieldSubmitted: (_) => c.submit(),
                            validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Obx(
                          () => FilledButton(
                            key: const Key('login-submit'),
                            onPressed: c.submitting.value ? null : c.submit,
                            child: c.submitting.value
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text('Sign in'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
