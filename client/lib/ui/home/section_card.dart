import 'package:flutter/material.dart';

import '../theme/liquid_glass.dart';

/// ADR-004 §2.1: the client owns card layout; metadata is optional.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle?.trim();
    return LiquidGlassSurface(
      margin: const EdgeInsets.only(bottom: 12),
      borderRadius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
