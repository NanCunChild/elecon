/// Fixed input form for a school source that cannot obtain a required card id.
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

Future<String?> requestCardNumber(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const _CardNumberDialog(isCard: true),
);

Future<String?> requestStudentId(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const _CardNumberDialog(isCard: false),
);

class _CardNumberDialog extends StatefulWidget {
  const _CardNumberDialog({required this.isCard});
  final bool isCard;
  @override
  State<_CardNumberDialog> createState() => _CardNumberDialogState();
}

class _CardNumberDialogState extends State<_CardNumberDialog> {
  final _number = TextEditingController();
  final _form = GlobalKey<FormState>();

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(_number.text.trim());
    }
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        widget.isCard
            ? l10n.cardNumberRequiredTitle
            : l10n.studentIdRequiredTitle,
      ),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.isCard
                  ? l10n.cardNumberRequiredBody
                  : l10n.studentIdRequiredBody,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _number,
              autofocus: true,
              maxLength: 128,
              decoration: InputDecoration(
                labelText: widget.isCard
                    ? l10n.cardNumberLabel
                    : l10n.studentIdLabel,
              ),
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              validator: (value) =>
                  value == null ||
                      value.trim().isEmpty ||
                      value.runes.any((r) => r < 32)
                  ? (widget.isCard
                        ? l10n.cardNumberInvalid
                        : l10n.studentIdInvalid)
                  : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.cardNumberContinue)),
      ],
    );
  }
}
