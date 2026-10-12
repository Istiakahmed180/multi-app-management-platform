import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/api/api_exception.dart';

void _show(String message, {required bool error}) {
  final context = Get.context;
  if (context == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final scheme = Theme.of(context).colorScheme;
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? scheme.error : null,
        showCloseIcon: true,
        duration: Duration(seconds: error ? 6 : 3),
      ),
    );
}

void notifySuccess(String message) => _show(message, error: false);

void notifyError(Object error) {
  if (error is ApiException) {
    final ref = error.requestId != null ? ' (ref ${error.requestId!.substring(0, error.requestId!.length.clamp(0, 8))})' : '';
    _show('${error.message}$ref', error: true);
  } else {
    _show('Unexpected error: $error', error: true);
  }
}
