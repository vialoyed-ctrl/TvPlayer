/// Pinyin and Hot Search Matcher for TV app.
/// Maps English letters (pinyin initials) entered via remote control
/// to corresponding Chinese drama and movie titles.
class PinyinMatcher {
  static final List<String> popularKeywords = [
    '狂飙',
    '繁花',
    '庆余年',
    '仙逆',
    '凡人修仙传',
    '边水往事',
    '名侦探柯南',
    '白夜破晓',
    '白夜追凶',
    '唐朝诡事录',
    '歌手2024',
    '奔跑吧',
    '斗破苍穹',
    '斗罗大陆',
    '三体',
    '封神',
    '流浪地球',
    '抓娃娃',
    '默杀',
    '孤注一掷',
    '潜伏',
    '亮剑',
    '琅琊榜',
    '甄嬛传',
    '莲花楼',
    '长相思',
    '完美世界',
    '遮天',
    '吞噬星空',
    '一念永恒',
    '黑白混战',
    '海贼王',
    '火影忍者',
    '进击的巨人',
    '鬼灭之刃',
    '扫黑风暴',
    '人民的名义',
    '无间道',
    '功夫',
    '大话西游',
  ];

  static final Map<String, List<String>> _initialsMap = {
    'KB': ['狂飙', '恐怖游轮', '狂暴巨兽'],
    'FH': ['繁花', '风吹半夏', '复仇者联盟'],
    'QYN': ['庆余年', '庆余年第二季'],
    'QYN2': ['庆余年第二季'],
    'XN': ['仙逆', '修仙纪元'],
    'FR': ['凡人修仙传', '反黑'],
    'FRXXZ': ['凡人修仙传'],
    'BS': ['边水往事', '白色城堡'],
    'BSWS': ['边水往事'],
    'KN': ['名侦探柯南', '柯南'],
    'MNZKN': ['名侦探柯南'],
    'BY': ['白夜追凶', '白夜破晓'],
    'BYZX': ['白夜追凶'],
    'BYPX': ['白夜破晓'],
    'TC': ['唐朝诡事录', '天才基本法'],
    'TCGSL': ['唐朝诡事录'],
    'GS': ['歌手2024', '歌手'],
    'GS2024': ['歌手2024'],
    'BPB': ['奔跑吧', '奔跑吧兄弟'],
    'DP': ['斗破苍穹'],
    'DPCQ': ['斗破苍穹'],
    'DL': ['斗罗大陆'],
    'DLDL': ['斗罗大陆'],
    'ST': ['三体'],
    'FS': ['封神', '封神第一部'],
    'LLDQ': ['流浪地球', '流浪地球2'],
    'ZWW': ['抓娃娃'],
    'MS': ['默杀'],
    'GZYZ': ['孤注一掷'],
    'QF': ['潜伏'],
    'LJ': ['亮剑'],
    'LYB': ['琅琊榜'],
    'ZHC': ['甄嬛传'],
    'LHL': ['莲花楼'],
    'CXS': ['长相思'],
    'WMSJ': ['完美世界'],
    'ZT': ['遮天'],
    'TSXK': ['吞噬星空'],
    'YNYH': ['一念永恒'],
    'HB': ['黑白混战', '黑土无言'],
    'HBDS': ['黑白森林', '黑白大厨'],
    'HTWY': ['黑土无言'],
    'HZW': ['海贼王'],
    'HYRZ': ['火影忍者'],
    'JJDJR': ['进击的巨人'],
    'GMZR': ['鬼灭之刃'],
    'SHFB': ['扫黑风暴'],
    'RMDMY': ['人民的名义'],
    'WJD': ['无间道'],
    'GF': ['功夫'],
    'DHXY': ['大话西游'],
    'BSRN': ['半熟男女'],
    'XSYC': ['血色遗产'],
    'BM': ['一个部门的诞生'],
    'YGBMDDS': ['一个部门的诞生'],
  };

  /// Dynamically index a title into the pinyin dictionary
  static void registerTitle(String title) {
    if (title.isEmpty) return;
    final initials = getInitials(title);
    if (initials.isNotEmpty) {
      final list = _initialsMap.putIfAbsent(initials, () => []);
      if (!list.contains(title)) {
        list.add(title);
      }
    }
  }

  /// Finds suggested Chinese keywords for a pinyin initial query (e.g. "kb" -> ["狂飙"])
  static List<String> matchSuggestions(String input) {
    final clean = input.trim().toUpperCase();
    if (clean.isEmpty) return [];

    final results = <String>{};

    // 1. Exact match in initials map
    if (_initialsMap.containsKey(clean)) {
      results.addAll(_initialsMap[clean]!);
    }

    // 2. Prefix match in initials map
    for (final entry in _initialsMap.entries) {
      if (entry.key.startsWith(clean)) {
        results.addAll(entry.value);
        if (results.length >= 10) break;
      }
    }

    // 3. Fallback: match popular keywords by generated initials
    for (final kw in popularKeywords) {
      final inits = getInitials(kw);
      if (inits.startsWith(clean)) {
        results.add(kw);
      }
      if (results.length >= 10) break;
    }

    return results.toList();
  }

  /// Calculates pinyin initials for common Chinese characters
  static String getInitials(String chinese) {
    final sb = StringBuffer();
    for (int i = 0; i < chinese.length; i++) {
      final charCode = chinese.codeUnitAt(i);
      // Digits & ASCII letters
      if ((charCode >= 48 && charCode <= 57) ||
          (charCode >= 65 && charCode <= 90)) {
        sb.writeCharCode(charCode);
      } else if (charCode >= 97 && charCode <= 122) {
        sb.writeCharCode(charCode - 32);
      } else if (charCode >= 0x4E00 && charCode <= 0x9FA5) {
        final initial = _charToPinyinInitial(charCode);
        if (initial != null) {
          sb.write(initial);
        }
      }
    }
    return sb.toString();
  }

  /// Common Chinese character first letter heuristic
  static String? _charToPinyinInitial(int code) {
    // Exact overrides for hot words
    switch (code) {
      case 0x72c2:
        return 'K'; // 狂
      case 0x98d9:
        return 'B'; // 飙
      case 0x7e41:
        return 'F'; // 繁
      case 0x82b1:
        return 'H'; // 花
      case 0x5e86:
        return 'Q'; // 庆
      case 0x4f59:
        return 'Y'; // 余
      case 0x5e74:
        return 'N'; // 年
      case 0x4ed9:
        return 'X'; // 仙
      case 0x9006:
        return 'N'; // 逆
      case 0x51e1:
        return 'F'; // 凡
      case 0x4eba:
        return 'R'; // 人
      case 0x4fee:
        return 'X'; // 修
      case 0x4f20:
        return 'Z'; // 传
      case 0x8fb9:
        return 'B'; // 边
      case 0x6c34:
        return 'S'; // 水
      case 0x5f80:
        return 'W'; // 往
      case 0x4e8b:
        return 'S'; // 事
      case 0x540d:
        return 'M'; // 名
      case 0x4fa6:
        return 'Z'; // 侦
      case 0x63a2:
        return 'T'; // 探
      case 0x67ef:
        return 'K'; // 柯
      case 0x5357:
        return 'N'; // 南
      case 0x767d:
        return 'B'; // 白
      case 0x591c:
        return 'Y'; // 夜
      case 0x7834:
        return 'P'; // 破
      case 0x6653:
        return 'X'; // 晓
      case 0x8ffd:
        return 'Z'; // 追
      case 0x51f6:
        return 'X'; // 凶
      case 0x5510:
        return 'T'; // 唐
      case 0x671d:
        return 'C'; // 朝
      case 0x8be1:
        return 'G'; // 诡
      case 0x5f55:
        return 'L'; // 录
      case 0x6b4c:
        return 'G'; // 歌
      case 0x624b:
        return 'S'; // 手
      case 0x5954:
        return 'B'; // 奔
      case 0x8dd1:
        return 'P'; // 跑
      case 0x5427:
        return 'B'; // 吧
      case 0x6597:
        return 'D'; // 斗
      case 0x7f57:
        return 'L'; // 罗
      case 0x7a79:
        return 'Q'; // 穹
      case 0x4e09:
        return 'S'; // 三
      case 0x4f53:
        return 'T'; // 体
      case 0x5c01:
        return 'F'; // 封
      case 0x795e:
        return 'S'; // 神
      case 0x6d41:
        return 'L'; // 流
      case 0x6d6a:
        return 'L'; // 浪
      case 0x5730:
        return 'D'; // 地
      case 0x7403:
        return 'Q'; // 球
      case 0x6293:
        return 'Z'; // 抓
      case 0x5a03:
        return 'W'; // 娃
      case 0x9ed8:
        return 'M'; // 默
      case 0x6740:
        return 'S'; // 杀
      case 0x5b64:
        return 'G'; // 孤
      case 0x6ce8:
        return 'Z'; // 注
      case 0x4e00:
        return 'Y'; // 一
      case 0x63b7:
        return 'Z'; // 掷
      case 0x6f5c:
        return 'Q'; // 潜
      case 0x4f0f:
        return 'F'; // 伏
      case 0x4eae:
        return 'L'; // 亮
      case 0x5251:
        return 'J'; // 剑
      case 0x7405:
        return 'L'; // 琅
      case 0x740a:
        return 'Y'; // 琊
      case 0x699c:
        return 'B'; // 榜
      case 0x7504:
        return 'Z'; // 甄
      case 0x5acc:
        return 'H'; // 嬛
      case 0x83b2:
        return 'L'; // 莲
      case 0x697c:
        return 'L'; // 楼
      case 0x906e:
        return 'Z'; // 遮
      case 0x5929:
        return 'T'; // 天
      case 0x541e:
        return 'T'; // 吞
      case 0x566c:
        return 'S'; // 噬
      case 0x661f:
        return 'X'; // 星
      case 0x7a7a:
        return 'K'; // 空
      case 0x5ff5:
        return 'Y'; // 念
      case 0x6c38:
        return 'Y'; // 永
      case 0x6052:
        return 'H'; // 恒
      case 0x9ed1:
        return 'H'; // 黑
      case 0x6d77:
        return 'H'; // 海
      case 0x8d3c:
        return 'Z'; // 贼
      case 0x738b:
        return 'W'; // 王
      case 0x706b:
        return 'H'; // 火
      case 0x5f71:
        return 'Y'; // 影
      case 0x529f:
        return 'G'; // 功
      case 0x592b:
        return 'F'; // 夫
      case 0x5927:
        return 'D'; // 大
      case 0x8bdd:
        return 'H'; // 话
      case 0x897f:
        return 'X'; // 西
      case 0x6e38:
        return 'Y'; // 游
      case 0x65e0:
        return 'W'; // 无
      case 0x95f4:
        return 'J'; // 间
      case 0x9053:
        return 'D'; // 道
      default:
        // Unicode phonetic block estimate
        if (code >= 0x4e00 && code <= 0x5000) return 'A';
        if (code <= 0x5600) return 'B';
        if (code <= 0x5c00) return 'C';
        if (code <= 0x6200) return 'D';
        if (code <= 0x6800) return 'F';
        if (code <= 0x6e00) return 'G';
        if (code <= 0x7400) return 'H';
        if (code <= 0x7a00) return 'J';
        if (code <= 0x8000) return 'K';
        if (code <= 0x8600) return 'L';
        if (code <= 0x8c00) return 'M';
        if (code <= 0x9200) return 'P';
        return 'S';
    }
  }
}
