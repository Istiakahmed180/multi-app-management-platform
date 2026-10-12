import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Confirmation for consequential actions. When [typeToConfirm] is set the
/// user must type that text before the destructive button is enabled.
Future<bool> confirmAction({
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
  String? typeToConfirm,
}) async {
  final result = await Get.dialog<bool>(
    _ConfirmDialog(title: title, message: message, confirmLabel: confirmLabel, destructive: destructive, typeToConfirm: typeToConfirm),
  );
  return result ?? false;
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.destructive,
    this.typeToConfirm,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;
  final String? typeToConfirm;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.typeToConfirm == null || _controller.text.trim() == widget.typeToConfirm;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            if (widget.typeToConfirm != null) ...[
              const SizedBox(height: 16),
              Text('Type "${widget.typeToConfirm}" to confirm'),
              const SizedBox(height: 8),
              TextField(controller: _controller, autofocus: true, onChanged: (_) => setState(() {})),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Get.back(result: false), child: const Text('Cancel')),
        FilledButton(
          style: widget.destructive ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError) : null,
          onPressed: enabled ? () => Get.back(result: true) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
