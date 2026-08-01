import 'dart:io';

import 'package:flutter/material.dart';

import '../services/offline/photo_cache.dart';

/// A polished, tappable photo thumbnail for the line-inspection flow.
///
/// Shows a rounded thumbnail (network or file backed) with a loading spinner
/// while it decodes and a broken-image fallback if it fails, plus a small
/// "zoom" affordance in the corner. Tapping opens a full-screen, pinch-to-zoom
/// viewer with a Hero transition from the thumbnail.
///
/// Replaces the bare `Image.network` / `Image.file` thumbnails that were
/// scattered across the inspection detail and capture form so every photo in
/// the flow looks and behaves the same.
class LiPhotoThumbnail extends StatefulWidget {
  const LiPhotoThumbnail.network(
    this.url, {
    super.key,
    this.size = 120,
    this.borderRadius = 10,
  })  : file = null,
        _isNetwork = true;

  const LiPhotoThumbnail.file(
    this.file, {
    super.key,
    this.size = 120,
    this.borderRadius = 10,
  })  : url = null,
        _isNetwork = false;

  final String? url;
  final File? file;
  final double size;
  final double borderRadius;
  final bool _isNetwork;

  @override
  State<LiPhotoThumbnail> createState() => _LiPhotoThumbnailState();
}

class _LiPhotoThumbnailState extends State<LiPhotoThumbnail> {
  // A stable, unique Hero tag per thumbnail instance — using the image URL
  // directly would collide when the same photo appears more than once on a
  // screen (e.g. an item photo repeated across its defect entries).
  late final Object _heroTag = UniqueKey();

  // Server photos go through [PhotoCache], so one viewed (or pulled down by the
  // offline download) stays viewable with no signal. Photos staged for a queued
  // inspection are already on disk and render straight from the file.
  ImageProvider get _provider => widget._isNetwork
      ? CachedPhotoImage(widget.url!)
      : FileImage(widget.file!) as ImageProvider;

  void _open() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, _, _) => _PhotoViewer(
          provider: _provider,
          heroTag: _heroTag,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: Hero(
        tag: _heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Stack(
            children: [
              Image(
                image: _provider,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return _Placeholder(
                    size: widget.size,
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress.expectedTotalBytes != null
                            ? progress.cumulativeBytesLoaded /
                                progress.expectedTotalBytes!
                            : null,
                      ),
                    ),
                  );
                },
                // A photo that isn't on the device and can't be fetched is an
                // offline gap, not a corrupt file — say so, so the engineer
                // knows it will appear once they have signal rather than
                // reading it as lost evidence.
                errorBuilder: (context, error, stack) => _Placeholder(
                  size: widget.size,
                  child: const Icon(Icons.cloud_off_outlined,
                      color: Colors.grey, size: 22),
                ),
              ),
              // Bottom-right zoom affordance so it reads as tappable.
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.zoom_out_map,
                      size: 13, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        color: Colors.black.withValues(alpha: 0.05),
        alignment: Alignment.center,
        child: child,
      );
}

/// Full-screen, dismissible, pinch-to-zoom viewer for a single photo.
class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.provider, required this.heroTag});
  final ImageProvider provider;
  final Object heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Tap the backdrop to dismiss.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Center(
            child: Hero(
              tag: heroTag,
              child: InteractiveViewer(
                maxScale: 5,
                child: Image(
                  image: provider,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(child: CircularProgressIndicator()),
                  errorBuilder: (context, error, stack) => const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off_outlined,
                            color: Colors.white70, size: 48),
                        SizedBox(height: 12),
                        Text(
                          "This photo isn't saved on the device yet.\n"
                          'It will load when you have signal.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}
