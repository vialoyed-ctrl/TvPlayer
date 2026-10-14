import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../services/video_site_client.dart';

/// 封面下载失败时依次尝试镜像，不把错误页长期缓存为海报。
class PosterImage extends StatefulWidget {
  const PosterImage({
    super.key,
    required this.imageUrl,
    this.fit,
    this.placeholder,
    this.errorWidget,
  });
  final String imageUrl;
  final BoxFit? fit;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, dynamic)? errorWidget;
  @override
  State<PosterImage> createState() => _PosterImageState();
}

class _PosterImageState extends State<PosterImage> {
  static String? _workingHost;
  late List<String> _urls;
  int _index = 0;
  bool _scheduled = false;
  int _generation = 0;

  void _reset() {
    _urls = VideoSiteClient.imageCandidates(widget.imageUrl);
    if (kDebugMode) {
      debugPrint(
        '[PosterImage] URL=${widget.imageUrl}, candidates=${_urls.length}',
      );
    }
    if (_workingHost != null) {
      final preferred = _urls
          .where((url) => Uri.parse(url).host == _workingHost)
          .toList();
      _urls = [...preferred, ..._urls.where((url) => !preferred.contains(url))];
    }
    _index = 0;
    _scheduled = false;
    _generation++;
  }

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant PosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _reset();
  }

  Widget _error(BuildContext context, String url, dynamic error) {
    if (kDebugMode) debugPrint('[PosterImage] failed $url: $error');
    if (_index + 1 < _urls.length) {
      if (!_scheduled) {
        _scheduled = true;
        final generation = _generation;
        debugPrint('[PosterImage] 封面加载失败，切换镜像：$error');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) {
            setState(() {
              _index++;
              _scheduled = false;
            });
          }
        });
      }
      return widget.placeholder?.call(context, url) ??
          const Center(
            child: Icon(Icons.movie_outlined, color: Colors.white24),
          );
    }
    return widget.errorWidget?.call(context, url, error) ??
        const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.white24),
        );
  }

  @override
  Widget build(BuildContext context) {
    if (_urls.isEmpty) return _error(context, '', '没有封面地址');
    final url = _urls[_index];
    return CachedNetworkImage(
      key: ValueKey(url),
      imageUrl: url,
      fit: widget.fit,
      cacheKey: 'tvplayer-poster-v3:$url',
      httpHeaders: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Accept': 'image/avif,image/webp,image/*,*/*;q=0.8',
      },
      placeholder: widget.placeholder,
      errorWidget: _error,
      imageBuilder: (context, provider) {
        _workingHost = Uri.parse(url).host;
        return Image(image: provider, fit: widget.fit);
      },
    );
  }
}
