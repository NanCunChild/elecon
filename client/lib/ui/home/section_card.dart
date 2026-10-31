import 'package:flutter/material.dart';

import 'card_layout.dart';

/// A single business surface: a half-width summary opens the same mounted card.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.summary,
  });
  final String title;
  final String? subtitle;
  final Widget? summary;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = HomeCardPresentation.maybeOf(context);
    final preview = HomeCardPresentation.isPreview(context);
    final subtitle = this.subtitle?.trim();
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: preview ? presentation?.onOpen : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Icon(
                    presentation!.icon,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                title,
                style: preview
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.titleLarge,
              ),
              if (!preview && subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              if (preview)
                DefaultTextStyle(
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  child:
                      summary ??
                      Text(
                        subtitle == null || subtitle.isEmpty ? title : subtitle,
                      ),
                )
              else
                child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Key value plus context for a finite summary; no controls are hidden in it.
class CardSummary extends StatelessWidget {
  const CardSummary(this.value, {super.key, this.detail});
  final String value;
  final String? detail;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (detail != null && detail!.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(detail!, maxLines: 3, overflow: TextOverflow.ellipsis),
      ],
    ],
  );
}
