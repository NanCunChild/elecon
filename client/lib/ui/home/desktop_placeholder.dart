import 'package:flutter/material.dart';

/// The short local-storage restore uses the desktop's shape, without a modal
/// progress animation or a second copy of private business data.
class DesktopPlaceholder extends StatelessWidget {
  const DesktopPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget block(double height, {double? width}) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
    );
    return ExcludeSemantics(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              block(32, width: 180),
              const SizedBox(height: 12),
              block(16, width: 100),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(child: block(136)),
                  const SizedBox(width: 16),
                  Expanded(child: block(136)),
                ],
              ),
              const SizedBox(height: 16),
              block(136),
            ],
          ),
        ),
      ),
    );
  }
}
