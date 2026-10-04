class Channel {
  final int id;
  final String name;
  final String path;

  const Channel({required this.id, required this.name, required this.path});

  static const List<Channel> defaultChannels = [
    // id 0 走列表页（/show/2--中国大陆---3-{页码}.html），可向下翻页；
    // path 仅作说明用，实际 URL 由 VideoSiteScraper.buildListPath 生成。
    Channel(id: 0, name: '首页', path: '/show/2--中国大陆---3-1.html'),
    Channel(id: 1, name: '电影', path: '/channel/1.html'),
    Channel(id: 2, name: '连续剧', path: '/channel/2.html'),
    Channel(id: 3, name: '动漫', path: '/channel/3.html'),
    Channel(id: 4, name: '综艺', path: '/channel/4.html'),
    Channel(id: 6, name: '短剧', path: '/channel/6.html'),
  ];
}
