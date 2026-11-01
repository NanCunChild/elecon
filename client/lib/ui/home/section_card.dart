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
    if (preview && presentation?.previewHeight != null) {
      return SizedBox(
        height: presentation!.previewHeight,
        child: Material(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: presentation.onOpen,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        presentation.icon,
                        size: 22,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: DefaultTextStyle(
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      child:
                          summary ??
                          Text(
                            subtitle == null || subtitle.isEmpty
                                ? title
                                : subtitle,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final scale = MediaQuery.textScalerOf(context);
      final valueStyle = theme.textTheme.titleMedium!;
      final detailStyle = DefaultTextStyle.of(context).style;
      final valueLine =
          scale.scale(valueStyle.fontSize!) * (valueStyle.height ?? 1.4);
      final detailLine =
          scale.scale(detailStyle.fontSize ?? 14) * (detailStyle.height ?? 1.4);
      final hasDetail = detail != null && detail!.isNotEmpty;
      var valueLines = 3, detailLines = 3;
      if (constraints.hasBoundedHeight) {
        final available = constraints.maxHeight;
        valueLines =
            ((available - (hasDetail ? detailLine + 4 : 0)) / valueLine)
                .floor()
                .clamp(1, 3);
        detailLines = hasDetail
            ? ((available - valueLines * valueLine - 4) / detailLine)
                  .floor()
                  .clamp(0, 3)
            : 0;
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: valueLines,
            overflow: TextOverflow.ellipsis,
            style: valueStyle,
          ),
          if (hasDetail && detailLines > 0) ...[
            const SizedBox(height: 4),
            Text(
              detail!,
              maxLines: detailLines,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      );
    },
  );
}
