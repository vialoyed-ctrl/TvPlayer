class HistoryItem {
  final String vodId;
  final String title;
  final String cover;
  final String sourceName;
  final String episodeName;
  final String playPath;
  final int positionMs;
  final int durationMs;
  final int updatedAt;

  const HistoryItem({
    required this.vodId,
    required this.title,
    required this.cover,
    required this.sourceName,
    required this.episodeName,
    required this.playPath,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'vodId': vodId,
    'title': title,
    'cover': cover,
    'sourceName': sourceName,
    'episodeName': episodeName,
    'playPath': playPath,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt,
  };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
    vodId: json['vodId'] as String,
    title: json['title'] as String,
    cover: json['cover'] as String,
    sourceName: json['sourceName'] as String,
    episodeName: json['episodeName'] as String,
    playPath: json['playPath'] as String,
    positionMs: json['positionMs'] as int? ?? 0,
    durationMs: json['durationMs'] as int? ?? 0,
    updatedAt: json['updatedAt'] as int? ?? 0,
  );
}
