import 'dart:async';

import 'package:html/parser.dart' as html_parser;
import 'package:flutter/foundation.dart';

import '../models/vod_item.dart';
import '../models/vod_detail.dart';
import '../models/play_source.dart';
import 'video_site_client.dart';

/// 播放页探测结果。
///
/// 为什么需要三态而不是 `String?`：`resolvePlayM3u8` 把「网络异常」和
/// 「页面里没有 m3u8」都收敛成了 `null`。用它来判定死线路的话，一次网络抖动
/// 就会让整批线路被误判成死源。这里把两种情况分开，只对**确证**没源的线路动手。
enum PlayProbe {
  /// 页面拿到了，且解析出可用的 m3u8 地址。
  ok,

  /// 页面拿到了，但站点写的是 `src: ""` —— 该线路确实没有配源。
  /// 实测站点对未配置线路就是这个写法：HTTP 200、页面长度与正常页几乎一致，
  /// 但整页不含任何 `.m3u8` 子串，且函数名从 `gogogo()` 变成 `initVideoPlayer()`。
  emptySource,

  /// 页面结构不认识，或者页面根本没拿到（超时/断网）。
  /// **一律按「保留该线路」处理**，绝不让探测本身的故障删掉用户的线路。
  unknown,
}

class VideoSiteScraper {
  final VideoSiteClient _client = VideoSiteClient.instance;

  String? _cachedSearchToken;
  List<String> _cachedHotWords = const [];

  /// 拉首页，同时刷新「搜索令牌」和「热搜词」—— 一次请求拿两样。
  ///
  /// 关于令牌：站点会轮换它，而**失效的令牌会让 /search 返回 0 条**
  /// （实测：旧代码里硬编码的兜底值 `dcaNleslFqDSH+JLs1J08Q==` 现在正是这个表现，
  /// 所以这里不再用硬编码兜底）。首页拿不到时退回搜索页自己的表单再取一次；
  /// 仍然拿不到就交给 [searchPage] 在「0 条」时强制刷新重试。
  Future<void> _refreshSearchMeta({bool force = false}) async {
    if (!force && _cachedSearchToken != null && _cachedHotWords.isNotEmpty) {
      return;
    }

    final homeHtml = await _client.getHtml('/');
    _cachedSearchToken = _extractSearchToken(homeHtml);
    final hot = _extractHotWords(homeHtml);
    if (hot.isNotEmpty) _cachedHotWords = hot;

    if (_cachedSearchToken == null) {
      // 首页结构万一变了，搜索页的表单里还有一份。
      final probe = Uri.encodeComponent(
        _cachedHotWords.isNotEmpty ? _cachedHotWords.first : '热门',
      );
      final searchHtml = await _client.getHtml('/search?k=$probe');
      _cachedSearchToken = _extractSearchToken(searchHtml);
      if (_cachedHotWords.isEmpty) {
        _cachedHotWords = _extractHotWords(searchHtml);
      }
    }
  }

  /// 取 `<form action='/search'>` 里的隐藏令牌。
  static String? _extractSearchToken(String html) {
    final m = RegExp(r'''name=["']t["']\s+value=["']([^"']+)["']''')
        .firstMatch(html);
    final v = m?.group(1);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 站点搜索框下拉里的那批热搜词。
  ///
  /// 首页和搜索页都带（`a[href*="/search?k="]`，实测两页同一批、顺序也一致）。
  /// App 以前用的是本地写死的列表，和站点对不上 —— 用户截图里的就是这批。
  static List<String> _extractHotWords(String html) {
    final doc = html_parser.parse(html);
    final out = <String>[];
    for (final a in doc.querySelectorAll('a[href*="/search?k="]')) {
      final href = a.attributes['href'] ?? '';
      final m = RegExp(r'[?&]k=([^&]+)').firstMatch(href);
      if (m == null) continue;
      String word;
      try {
        word = Uri.decodeComponent(m.group(1)!);
      } catch (_) {
        continue;
      }
      if (word.isEmpty || out.contains(word)) continue;
      out.add(word);
    }
    return out;
  }

  /// 站点实时热搜词。拿不到就返回空列表，由调用方决定用什么兜底。
  Future<List<String>> getHotSearchWords() async {
    try {
      await _refreshSearchMeta();
    } catch (e) {
      debugPrint('[VideoSiteScraper] hot search words failed: $e');
    }
    return _cachedHotWords;
  }

  /// Searches for movies/shows by keyword (first page).
  Future<List<VodItem>> search(String keyword) => searchPage(keyword);

  /// 搜索第 [page] 页。
  ///
  /// 分页参数与站点自己的「下一页」链接完全一致：
  ///   /search?k=<关键词>&page=2&t=<令牌>
  /// 每页 [listPageSize] 条，页码超出范围时站点返回 0 条。
  Future<List<VodItem>> searchPage(String keyword, {int page = 1}) async {
    await _refreshSearchMeta();
    var items = await _fetchSearchPage(keyword, _cachedSearchToken, page);

    // 令牌失效的表现就是「0 条」。第一页没结果时强制换一次令牌再试一遍，
    // 免得偶发的令牌过期直接变成「搜不到」。
    if (items.isEmpty && page == 1) {
      await _refreshSearchMeta(force: true);
      items = await _fetchSearchPage(keyword, _cachedSearchToken, page);
    }
    return items;
  }

  Future<List<VodItem>> _fetchSearchPage(
    String keyword,
    String? token,
    int page,
  ) async {
    final encKw = Uri.encodeComponent(keyword);
    final encTok = Uri.encodeComponent(token ?? '');
    final path = page <= 1
        ? '/search?k=$encKw&t=$encTok'
        : '/search?k=$encKw&page=$page&t=$encTok';
    final html = await _client.getHtml(path);
    return _parseVodItems(html);
  }

  /// Fetches the home page featured items (banner & hot rows)
  Future<List<VodItem>> getHomeFeatured() async {
    final html = await _client.getHtml('/');
    return _parseVodItems(html);
  }

  /// 站点列表页每页条数（实测 18 条/页）。
  static const int listPageSize = 18;

  /// 首页（channel id 0）对应的列表页筛选条件：
  /// 类型 2 = 电视剧，地区 = 中国大陆，排序 3 = 最热。
  /// 字段顺序固定为 类型-题材-地区-语言-年份-排序-页码。
  static const int homeChannelId = 2;
  static const String homeArea = '中国大陆';

  /// 按站点规则拼列表页 URL：
  ///   /show/{类型}-{题材}-{地区}-{语言}-{年份}-{排序}-{页码}.html
  /// 空字段留空，所以「电视剧 / 中国大陆 / 最热 / 第 1 页」就是
  ///   /show/2--中国大陆---3-1.html
  /// 非 ASCII 字段按站点自己的写法做百分号编码，避免 Dio 发出裸 UTF-8 路径。
  static String buildListPath({
    required int channelId,
    String genre = '',
    String area = '',
    String language = '',
    String year = '',
    String sort = '3',
    required int page,
  }) {
    String enc(String v) => Uri.encodeComponent(v.trim());
    return '/show/${enc('$channelId')}-${enc(genre)}-${enc(area)}'
        '-${enc(language)}-${enc(year)}-${enc(sort)}-$page.html';
  }

  /// Fetches items for a channel (1: Movie, 2: Drama, 3: Anime, 4: Variety, 6: Short)
  ///
  /// 每一页都走 /show/... 列表页，保证页码连续、页间不重复。
  /// 旧的 '/show/$channelId--------$page---.html' 字段数是错的（多了 5 个空字段），
  /// 站点不认，所以翻页永远返回空 —— 首页往下翻不出第二页就是这个原因。
  Future<List<VodItem>> getChannelItems(int channelId, {int page = 1}) async {
    final path = buildListPath(channelId: channelId, page: page);
    final html = await _client.getHtml(path);
    return _parseVodItems(html);
  }

  /// 首页列表（电视剧 / 中国大陆 / 最热），支持向下翻页。
  Future<List<VodItem>> getHomeList({int page = 1}) async {
    final path = buildListPath(
      channelId: homeChannelId,
      area: homeArea,
      page: page,
    );
    final html = await _client.getHtml(path);
    return _parseVodItems(html);
  }

  static String cleanTitle(String rawTitle) {
    // 1. Remove unicode mathematical alphanumeric symbols (U+1D400 to U+1D7FF)
    final buffer = StringBuffer();
    for (final rune in rawTitle.runes) {
      if (rune >= 0x1D400 && rune <= 0x1D7FF) {
        continue; // skip fake math symbols like 𝕜𝕜𝕪𝕤𝟘𝟙
      }
      buffer.writeCharCode(rune);
    }
    var title = buffer.toString();

    // 2. Remove watermark texts & domains
    title = title
        .replaceAll(RegExp(r'可可影视[-_\s]*', caseSensitive: false), '')
        .replaceAll(RegExp(r'𝕜𝕜𝕪𝕤[0-9]*\.[a-z]+', caseSensitive: false), '')
        .replaceAll(RegExp(r'kekys[0-9]*\.[a-z]+', caseSensitive: false), '')
        .replaceAll(RegExp(r'kkys[0-9]*\.[a-z]+', caseSensitive: false), '')
        .replaceAll(
          RegExp(
            r'[a-zA-Z0-9_-]+\.(?:com|net|org|tv|cn)\b',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(r'www\.[a-zA-Z0-9\._-]+\.[a-z]+', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\.[a-zA-Z]{2,4}\b'), '')
        .replaceAll(RegExp(r'^\s*[-_./•·]+\s*'), '')
        .replaceAll(RegExp(r'\s*[-_./•·]+\s*$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return title;
  }

  /// Parses movie detail page, including synopsis, actors, and all play sources/episodes
  Future<VodDetail?> getVodDetail(String detailPath) async {
    final html = await _client.getHtml(detailPath);
    final doc = html_parser.parse(html);

    // Extract title: check .detail-title children to avoid fake watermarks
    String title = '';
    final detailTitleEle = doc.querySelector('.detail-title');
    if (detailTitleEle != null) {
      for (final child in detailTitleEle.children) {
        final style = child.attributes['style'] ?? '';
        if (style.contains('display: none') || style.contains('display:none')) {
          continue;
        }
        final text = child.text.trim();
        final lower = text.toLowerCase();
        if (lower.contains('kekys') ||
            lower.contains('kkys') ||
            VideoSiteClient.siteUrls.any(
              (site) =>
                  lower.contains(Uri.parse(site).host.replaceFirst('www.', '')),
            ) ||
            text.contains('可可影视')) {
          continue;
        }
        final cleaned = cleanTitle(text);
        if (cleaned.isNotEmpty) {
          title = cleaned;
          break;
        }
      }
    }
    if (title.isEmpty) {
      final titleEle = doc.querySelector('.detail-title, .title, h1');
      title = cleanTitle(titleEle?.text.trim() ?? '未知影片');
    }

    // Extract cover: find first non-placeholder img
    String rawCover = '';
    for (final img in doc.querySelectorAll(
      '.detail-pic img, .cover img, .detail-thumb img, #itemCoverImg img, .vod-img img',
    )) {
      if (img.attributes['id'] == 'noneCoverImg') continue;
      final orig =
          img.attributes['data-original'] ??
          img.attributes['data-src'] ??
          img.attributes['src'] ??
          '';
      if (orig.isEmpty ||
          orig.contains('placeholder') ||
          orig.contains('logo') ||
          orig.contains('empty-box') ||
          orig.contains('avatar') ||
          orig.contains('douban') ||
          orig.contains('douyin')) {
        continue;
      }
      rawCover = orig;
      break;
    }
    final cover = VideoSiteClient.fixImageUrl(rawCover);

    // Metadata
    //
    // 真实站点的结构（列表页与详情页）：
    //   <div class="detail-tags"><a class="detail-tags-item">2026</a>
    //                            <a class="detail-tags-item">中国大陆</a>
    //                            <a class="detail-tags-item">剧情 / 爱情 / 古装</a></div>
    //   <div class="detail-desc"><p>简介第一段</p><p>简介第二段</p></div>
    //   <div class="detail-info-row"><div class="detail-info-row-side">演员:</div>
    //                                <div class="detail-info-row-main"><a>谭松韵</a>...</div></div>
    //
    // 注意：站点用的是「演员:」而不是「主演：」，简介的容器是 .detail-desc
    // 而不是 .desc —— 旧选择器一个都没命中，所以详情页的简介和演员一直是空的。
    String remark = '';
    String type = '';
    String area = '';
    String year = '';
    String director = '';
    String actor = '';
    String desc = '';

    // 1) 年份 / 地区 / 题材：从标签链接的 URL 字段里取，比按文字猜更准。
    //    链接形如 /show/2-剧情 / 爱情 / 古装-----.html
    //    字段顺序固定为：类型-题材-地区-语言-年份-排序-页码
    for (final tag in doc.querySelectorAll('.detail-tags-item')) {
      final href = tag.attributes['href'] ?? '';
      if (!href.contains('/show/')) continue;
      try {
        final seg = href
            .replaceFirst(RegExp(r'^.*?/show/'), '')
            .replaceFirst(RegExp(r'\.html.*$'), '');
        final fields = Uri.decodeComponent(seg).split('-');
        if (fields.length < 5) continue;
        if (type.isEmpty && fields[1].trim().isNotEmpty) {
          type = fields[1].trim();
        }
        if (area.isEmpty && fields[2].trim().isNotEmpty) {
          area = fields[2].trim();
        }
        if (year.isEmpty && fields[4].trim().isNotEmpty) {
          year = fields[4].trim();
        }
      } catch (_) {
        // 链接格式异常就跳过，下面还有按文字兜底的分支
      }
    }

    // 兜底：按标签文字猜（老结构 / 站点改版时仍能出内容）
    for (final tag in doc.querySelectorAll('.detail-tags-item')) {
      final t = tag.text.trim();
      if (t.isEmpty) continue;
      if (year.isEmpty &&
          RegExp(r'^(\d{4}|\d{4}_\d{4}|\d{0,4}年代|更早)$').hasMatch(t)) {
        year = t;
      } else if (type.isEmpty && (t.contains('/') || t.contains('、'))) {
        type = t;
      } else if (area.isEmpty && !RegExp(r'^\d').hasMatch(t)) {
        area = t;
      }
    }

    // 2) 导演 / 演员 / 备注：都在 .detail-info-row 里，标签文字在
    //    .detail-info-row-side（「演员:」），内容在 .detail-info-row-main。
    for (final row in doc.querySelectorAll('.detail-info-row')) {
      final sideText =
          row.querySelector('.detail-info-row-side')?.text.trim() ?? '';
      final label = sideText.replaceAll(RegExp(r'[：:]\s*$'), '').trim();
      if (label.isEmpty) continue;

      final mainEle = row.querySelector('.detail-info-row-main');
      if (mainEle == null) continue;
      // 多个人名是多个 <a>，直接取 text 会粘成一串，用 / 连起来
      final parts = mainEle
          .querySelectorAll('a')
          .map((a) => a.text.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final value = parts.isNotEmpty
          ? parts.join(' / ')
          : mainEle.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (value.isEmpty) continue;

      if (label == '导演') {
        director = value;
      } else if (label == '演员' || label == '主演') {
        actor = value;
      } else if (label == '备注') {
        remark = value;
      }
    }

    // 3) 简介：.detail-desc 里是多个 <p>，逐段取并去掉段首全角空格
    final descEle = doc.querySelector('.detail-desc');
    if (descEle != null) {
      final ps = descEle.querySelectorAll('p');
      if (ps.isNotEmpty) {
        desc = ps
            .map((p) => p.text.trim().replaceAll(RegExp(r'^[\s\u3000]+'), ''))
            .where((s) => s.isNotEmpty)
            .join('\n');
      } else {
        desc = descEle.text.trim().replaceAll(RegExp(r'^[\s\u3000]+'), '');
      }
    }
    if (desc.isEmpty) {
      final fallbackDesc = doc.querySelector(
        '.desc, .detail-sketch, .content-desc, .detail-intro',
      );
      desc = fallbackDesc?.text.trim() ?? '';
    }
    if (desc.isEmpty) {
      // 最后兜底：<meta name="description"> 里就是剧情简介
      desc =
          doc
              .querySelector('meta[name="description"]')
              ?.attributes['content']
              ?.trim() ??
          '';
    }

    // 4) 旧结构兜底（站点若改回 .detail-info-item 仍能出内容）
    if (type.isEmpty ||
        area.isEmpty ||
        year.isEmpty ||
        director.isEmpty ||
        actor.isEmpty) {
      for (final info in doc.querySelectorAll(
        '.detail-info-item, .info-item, .data',
      )) {
        final text = info.text.trim();
        if (type.isEmpty && (text.contains('类型：') || text.contains('类型:'))) {
          type = text.replaceAll(RegExp(r'类型[：:]'), '').trim();
        } else if (area.isEmpty &&
            (text.contains('地区：') || text.contains('地区:'))) {
          area = text.replaceAll(RegExp(r'地区[：:]'), '').trim();
        } else if (year.isEmpty &&
            (text.contains('年份：') || text.contains('年份:'))) {
          year = text.replaceAll(RegExp(r'年份[：:]'), '').trim();
        } else if (director.isEmpty &&
            (text.contains('导演：') || text.contains('导演:'))) {
          director = text.replaceAll(RegExp(r'导演[：:]'), '').trim();
        } else if (actor.isEmpty &&
            (text.contains('主演：') || text.contains('主演:'))) {
          actor = text.replaceAll(RegExp(r'主演[：:]'), '').trim();
        }
      }
    }

    // Extract Sources and Episodes
    final sources = <PlaySource>[];

    // Source tabs
    final sourceTabs = doc.querySelectorAll(
      '.source-item, .play-source-item, .source-list-box-main a',
    );
    final episodeLists = doc.querySelectorAll(
      '.episode-list, .play-list, .playlist',
    );

    if (sourceTabs.isNotEmpty && episodeLists.isNotEmpty) {
      for (int i = 0; i < sourceTabs.length && i < episodeLists.length; i++) {
        final tab = sourceTabs[i];
        // 站点把线路名 / 副标签 / 集数拆成三个子元素：
        //   <span class="source-item-label">超清2</span>
        //   <span class="source-item-sublabel">秒播/4K</span>
        //   <i class="source-item-num">152</i>
        //
        // 早期版本直接取 `tab.text`，把三者拼成了「超清2 秒播/4K 152」。
        // 后果不只是难看：每条线路名里都含 "4K" 子串，于是
        // SourceSpeedTester.isHeavySource() 对**所有**线路都返回 true，
        // 「默认避开 2K/4K 线路」的两处逻辑（DetailProvider 默认选源、
        // PlayerProvider 开播前换源）全部永远找不到非 heavy 的线路而失效。
        final labelEle = tab.querySelector('.source-item-label');
        final sublabelEle = tab.querySelector('.source-item-sublabel');
        final sourceName = (labelEle?.text ?? tab.text).trim().replaceAll(
          RegExp(r'\s+'),
          ' ',
        );
        final sourceSublabel = (sublabelEle?.text ?? '').trim().replaceAll(
          RegExp(r'\s+'),
          ' ',
        );
        final epListEle = episodeLists[i];

        final episodes = <Episode>[];
        final epLinks = epListEle.querySelectorAll('a[href*="/play/"]');
        for (int j = 0; j < epLinks.length; j++) {
          final epA = epLinks[j];
          final epName = epA.text.trim().isEmpty
              ? '第${j + 1}集'
              : epA.text.trim();
          final playPath = epA.attributes['href'] ?? '';
          episodes.add(Episode(name: epName, playPath: playPath, index: j));
        }

        if (episodes.isNotEmpty) {
          sources.add(
            PlaySource(
              name: sourceName.isEmpty ? '线路 ${i + 1}' : sourceName,
              sublabel: sourceSublabel,
              sourceId: 'src_$i',
              episodes: episodes,
            ),
          );
        }
      }
    } else {
      // Fallback: collect all play links
      final allPlayLinks = doc.querySelectorAll('a[href*="/play/"]');
      final episodes = <Episode>[];
      for (int j = 0; j < allPlayLinks.length; j++) {
        final epA = allPlayLinks[j];
        final epName = epA.text.trim().isEmpty ? '第${j + 1}集' : epA.text.trim();
        final playPath = epA.attributes['href'] ?? '';
        episodes.add(Episode(name: epName, playPath: playPath, index: j));
      }
      if (episodes.isNotEmpty) {
        sources.add(
          PlaySource(name: '默认线路', sourceId: 'src_default', episodes: episodes),
        );
      }
    }

    final vodId =
        RegExp(r'/detail/(\d+)\.html').firstMatch(detailPath)?.group(1) ?? '0';

    return VodDetail(
      id: vodId,
      title: title,
      cover: cover,
      remark: remark,
      type: type,
      area: area,
      year: year,
      director: director,
      actor: actor,
      desc: desc,
      sources: sources,
    );
  }

  /// Resolves the actual m3u8 stream URL from play page HTML
  Future<String?> resolvePlayM3u8(String playPath) async {
    try {
      final html = await _client.getHtml(playPath);
      // Find `src: "https://..."` in javascript
      final match = RegExp(r'''src:\s*["'](https?://[^"']+\.m3u8[^"']*)["']''')
          .firstMatch(html);
      if (match != null) {
        return match.group(1);
      }

      // Try player_aaaa / player config
      final playerMatch = RegExp(r'''"url"\s*:\s*["'](https?://[^"']+)["']''')
          .firstMatch(html);
      if (playerMatch != null) {
        return playerMatch.group(1);
      }
    } catch (e) {
      debugPrint('[VideoSiteScraper] resolvePlayM3u8 error for $playPath: $e');
    }
    return null;
  }

  /// 探测某个播放页到底有没有源（区分「站点没配」与「网络没拿到」）。
  ///
  /// 详情页的线路标签里**没有任何**「不可用」标记 —— 实测死线路与正常线路的
  /// `a.source-item` 结构、class 列表、`i.source-item-num` 完全一致，
  /// 唯一区别只有播放页里那一句 `src: ""`。所以只能靠这一趟请求判定。
  Future<PlayProbe> probePlayPath(String playPath) async {
    try {
      final html = await _client.getHtml(playPath);
      if (RegExp(r'''src:\s*["'](https?://[^"']+\.m3u8[^"']*)["']''')
          .hasMatch(html)) {
        return PlayProbe.ok;
      }
      // 站点对未配置线路的写法（实测）：`src: ""` / `src:''`
      if (RegExp(r'''src:\s*["']\s*["']''').hasMatch(html)) {
        return PlayProbe.emptySource;
      }
      return PlayProbe.unknown;
    } catch (e) {
      debugPrint('[VideoSiteScraper] probePlayPath failed for $playPath: $e');
      return PlayProbe.unknown;
    }
  }

  List<VodItem> _parseVodItems(String html) {
    final doc = html_parser.parse(html);
    final items = <VodItem>[];
    final seenIds = <String>{};

    for (final a in doc.querySelectorAll('a[href*="/detail/"]')) {
      final href = a.attributes['href'] ?? '';
      final idMatch = RegExp(r'/detail/(\d+)\.html').firstMatch(href);
      if (idMatch == null) continue;
      final id = idMatch.group(1)!;
      if (seenIds.contains(id)) continue;

      // Cover parsing: pick the first real image (not noneCoverImg, not placeholder)
      String rawCover = '';
      for (final img in a.querySelectorAll('img')) {
        if (img.attributes['id'] == 'noneCoverImg') continue;
        final orig =
            img.attributes['data-original'] ??
            img.attributes['data-src'] ??
            img.attributes['src'] ??
            '';
        if (orig.isEmpty ||
            orig.contains('placeholder') ||
            orig.contains('empty-box') ||
            orig.contains('logo_horizontal') ||
            orig.contains('user-avatar') ||
            orig.contains('avatar') ||
            orig.contains('douban') ||
            orig.contains('douyin')) {
          continue;
        }
        rawCover = orig;
        break;
      }
      if (rawCover.isEmpty) {
        final anyImg = a.querySelector('img');
        rawCover =
            anyImg?.attributes['data-original'] ??
            anyImg?.attributes['src'] ??
            '';
      }

      // Title parsing: look for visible, non-watermark title element
      String title = '';
      for (final el in a.querySelectorAll(
        '.v-item-title, .carousel-item-title, .module-item-title, .item-title, .title, .name, h4, h3, h2, h1',
      )) {
        final style = el.attributes['style'] ?? '';
        if (style.contains('display: none') || style.contains('display:none')) {
          continue;
        }
        final t = el.text.trim();
        if (t.isEmpty) continue;
        // Check if text contains watermark
        final lower = t.toLowerCase();
        if (lower.contains('kekys') ||
            lower.contains('kkys') ||
            VideoSiteClient.siteUrls.any(
              (site) =>
                  lower.contains(Uri.parse(site).host.replaceFirst('www.', '')),
            ) ||
            t.contains('可可影视')) {
          continue;
        }
        final cleaned = cleanTitle(t);
        if (cleaned.isNotEmpty &&
            !cleaned.startsWith('更新至') &&
            !cleaned.startsWith('全') &&
            cleaned != 'HD') {
          title = cleaned;
          break;
        }
      }

      if (title.isEmpty) {
        final titleAttr = a.attributes['title'] ?? '';
        final cleaned = cleanTitle(titleAttr);
        if (cleaned.isNotEmpty &&
            !cleaned.startsWith('更新至') &&
            !cleaned.startsWith('全')) {
          title = cleaned;
        }
      }

      if (title.isEmpty) {
        for (final img in a.querySelectorAll('img')) {
          final alt = img.attributes['alt'] ?? '';
          final cleaned = cleanTitle(alt);
          if (cleaned.isNotEmpty &&
              !cleaned.contains('可可') &&
              !cleaned.contains('kekys') &&
              !cleaned.contains('kkys')) {
            title = cleaned;
            break;
          }
        }
      }

      if (title.length > 50) {
        title = title.substring(0, 50);
      }
      if (title.isEmpty) continue;

      // 「更新至第34集」这类角标在 .v-item-bottom 里，旧的 .tag/.state 等
      // 选择器在真实站点上一个都命中不了，所以卡片上的更新进度一直是空的。
      final remark =
          a
              .querySelector(
                '.v-item-bottom, .tag, .remarks, .note, .state, .text-right, .carousel-item-tags',
              )
              ?.text
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ') ??
          '';

      seenIds.add(id);
      items.add(
        VodItem(
          id: id,
          title: title,
          cover: VideoSiteClient.fixImageUrl(rawCover),
          remark: remark,
          detailPath: href,
        ),
      );
    }

    return items;
  }
}
