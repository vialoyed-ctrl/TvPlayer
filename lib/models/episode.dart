class Episode {
  final String name;
  final String playPath;
  final int index;

  const Episode({
    required this.name,
    required this.playPath,
    required this.index,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'playPath': playPath,
    'index': index,
  };

  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
    name: json['name'] as String,
    playPath: json['playPath'] as String,
    index: json['index'] as int,
  );
}
