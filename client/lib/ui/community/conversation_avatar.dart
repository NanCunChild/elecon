import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/messages/avatar.dart';

class ConversationAvatar extends StatelessWidget {
  const ConversationAvatar({super.key, required this.kind, this.images});

  final String kind;
  final List<String>? images;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget fallback() => ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          kind == 'group' ? Icons.group_outlined : Icons.person_outline,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final tiles = [
      for (final value in (images ?? const <String>[]).take(4))
        if (conversationAvatarBytes(value) case final bytes?)
          _AvatarTile(key: ValueKey(value), bytes: bytes, fallback: fallback),
    ];
    Widget pair(List<Widget> children) => Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children)
            Expanded(
              child: Padding(padding: const EdgeInsets.all(0.5), child: child),
            ),
        ],
      ),
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 40,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: tiles.isEmpty
              ? fallback()
              : tiles.length == 1
              ? tiles.single
              : Column(
                  children: [
                    pair(tiles.take(2).toList()),
                    if (tiles.length > 2) pair(tiles.skip(2).toList()),
                  ],
                ),
        ),
      ),
    );
  }
}

// Decode directly so private thumbnails never enter Flutter's global ImageCache.
class _AvatarTile extends StatefulWidget {
  const _AvatarTile({super.key, required this.bytes, required this.fallback});
  final Uint8List bytes;
  final Widget Function() fallback;
  @override
  State<_AvatarTile> createState() => _AvatarTileState();
}

class _AvatarTileState extends State<_AvatarTile> {
  ui.Image? _image;
  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(
        widget.bytes,
        targetWidth: 120,
        targetHeight: 120,
      );
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      // Malformed raster data leaves the default icon visible.
    } finally {
      codec?.dispose();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _image == null
      ? widget.fallback()
      : RawImage(image: _image, fit: BoxFit.cover);
}
