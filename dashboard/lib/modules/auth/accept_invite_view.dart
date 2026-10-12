import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../widgets/states.dart';

class AcceptInviteController extends GetxController {
  AcceptInviteController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final token = Get.parameters['token'] ?? '';
  final loading = true.obs;
  final error = RxnString();
  final invite = Rxn<Json>();
  final submitting = false.obs;
  final formKey = GlobalKey<FormState>();
  final name = TextEditingController();
  final password = TextEditingController();
  final fieldErrors = <String, String>{}.obs;

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      invite.value = asJson(await api.get('/invitations/$token'));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> accept() async {
    final needsAccount = invite.value?['accountExists'] != true;
    if (needsAccount && !(formKey.currentState?.validate() ?? false)) return;
    submitting.value = true;
    fieldErrors.clear();
    try {
      final res = asJson(
        await api.post(
          '/invitations/accept',
          body: {'token': token, if (needsAccount) 'name': name.text.trim(), if (needsAccount) 'password': password.text},
        ),
      );
      if (res['csrfToken'] is String) api.csrfToken = res['csrfToken'] as String;
      await session.bootstrap();
      if (session.isAuthenticated) {
        await session.selectOrg('${res['orgId']}');
        Get.offAllNamed(Routes.overview);
      } else {
        Get.offAllNamed(Routes.login);
      }
    } on ApiException catch (e) {
      for (final f in e.fieldErrors) {
        fieldErrors[f.path] = f.message;
      }
      error.value = e.isUnauthenticated ? 'Sign in as ${invite.value?['email']} first, then open this link again.' : e.message;
    } finally {
      submitting.value = false;
    }
  }
}

class AcceptInviteView extends StatelessWidget {
  const AcceptInviteView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(AcceptInviteController(Get.find(), Get.find()));
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Obx(() {
                  if (c.loading.value) return const LoadingView();
                  final inv = c.invite.value;
                  if (inv == null) {
                    return ErrorState(message: c.error.value ?? 'Invitation not found', onRetry: c.load);
                  }
                  final exists = inv['accountExists'] == true;
                  return Form(
                    key: c.formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Join ${asJson(inv['organization'])['name'] ?? 'organization'}', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Text('You were invited as ${roleLabel('${inv['role']}')} (${inv['email']}).'),
                        const SizedBox(height: 20),
                        if (c.error.value != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(c.error.value!, style: TextStyle(color: theme.colorScheme.error)),
                          ),
                        if (!exists) ...[
                          TextFormField(
                            controller: c.name,
                            decoration: InputDecoration(labelText: 'Your name', errorText: c.fieldErrors['name']),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: c.password,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: 'Choose a password',
                              helperText: 'At least 12 characters',
                              errorText: c.fieldErrors['password'],
                            ),
                            validator: (v) => (v == null || v.length < 12) ? 'At least 12 characters' : null,
                          ),
                          const SizedBox(height: 20),
                        ] else
                          const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: Text('You already have an account. Make sure you are signed in with the invited email.'),
                          ),
                        FilledButton(
                          onPressed: c.submitting.value ? null : c.accept,
                          child: Text(exists ? 'Accept invitation' : 'Create account and join'),
                        ),
                        if (exists) TextButton(onPressed: () => Get.toNamed(Routes.login), child: const Text('Sign in')),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
