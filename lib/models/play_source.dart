import 'episode.dart';
export 'episode.dart';

class PlaySource {
  /// 线路名，取自站点 `span.source-item-label`，例如「超清2」「4K」「蓝光1」。
  ///
  /// 这个字段同时承担三个职责，所以**必须是干净的线路名**，不能是拼接串：
  /// 1. UI 上直接显示（详情页线路 pill、播放器换源抽屉）；
  /// 2. 历史记录的线路身份（`HistoryItem.sourceName` 按此匹配回上一次的线路）；
  /// 3. `SourceSpeedTester.isHeavySource` 的判据。
  ///
  /// 早期版本这里存的是 `a.source-item` 的整段文本，即
  /// 「超清2 秒播/4K 152」。后果是**每一条线路都含子串 "4K"**，
  /// 于是 `isHeavySource` 对所有线路都返回 true，
  /// 「默认选一条非 2K/4K 线路」的逻辑彻底失效（永远找不到非 heavy 的线路）。
  final String name;

  /// 副标签，取自站点 `span.source-item-sublabel`，例如「秒播/4K」「香港加速」。
  /// 仅用于展示，不参与任何身份匹配或判据。
  final String sublabel;

  final String sourceId;
  final List<Episode> episodes;

  const PlaySource({
    required this.name,
    this.sublabel = '',
    required this.sourceId,
    required this.episodes,
  });

  /// 站点原始的完整展示串，例如「超清2 秒播/4K 152」。
  /// 需要复现站点/旧版本观感时才用它；默认 UI 用 [name]。
  String get displayName {
    final parts = <String>[
      name,
      if (sublabel.isNotEmpty) sublabel,
      if (episodes.isNotEmpty) '${episodes.length}',
    ];
    return parts.join(' ');
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'sublabel': sublabel,
    'sourceId': sourceId,
    'episodes': episodes.map((e) => e.toJson()).toList(),
  };

  factory PlaySource.fromJson(Map<String, dynamic> json) => PlaySource(
    name: json['name'] as String,
    sublabel: json['sublabel'] as String? ?? '',
    sourceId: json['sourceId'] as String,
    episodes: (json['episodes'] as List)
        .map((e) => Episode.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
