class VodItem {
  final String id;
  final String title;
  final String cover;
  final String remark;
  final String detailPath;
  final String? score;
  final String? category;
  final String? actor;

  const VodItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.remark,
    required this.detailPath,
    this.score,
    this.category,
    this.actor,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'remark': remark,
    'detailPath': detailPath,
    'score': score,
    'category': category,
    'actor': actor,
  };

  factory VodItem.fromJson(Map<String, dynamic> json) => VodItem(
    id: json['id'] as String,
    title: json['title'] as String,
    cover: json['cover'] as String,
    remark: json['remark'] as String? ?? '',
    detailPath: json['detailPath'] as String,
    score: json['score'] as String?,
    category: json['category'] as String?,
    actor: json['actor'] as String?,
  );
}
