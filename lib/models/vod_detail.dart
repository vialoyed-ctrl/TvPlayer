import 'play_source.dart';

class VodDetail {
  final String id;
  final String title;
  final String cover;
  final String remark;
  final String type;
  final String area;
  final String year;
  final String director;
  final String actor;
  final String desc;
  final List<PlaySource> sources;

  const VodDetail({
    required this.id,
    required this.title,
    required this.cover,
    required this.remark,
    required this.type,
    required this.area,
    required this.year,
    required this.director,
    required this.actor,
    required this.desc,
    required this.sources,
  });

  /// 只用于把详情页拿到、过滤后的线路列表替换回去。
  /// 其余字段一律原样保留，避免顺手改到不该动的东西。
  VodDetail copyWith({List<PlaySource>? sources}) => VodDetail(
    id: id,
    title: title,
    cover: cover,
    remark: remark,
    type: type,
    area: area,
    year: year,
    director: director,
    actor: actor,
    desc: desc,
    sources: sources ?? this.sources,
  );
}
