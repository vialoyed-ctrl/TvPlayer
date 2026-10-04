import 'package:flutter_test/flutter_test.dart';
import 'package:tvplayer/services/video_site_scraper.dart';
import 'package:tvplayer/services/pinyin_matcher.dart';

void main() {
  test('PinyinMatcher matches pinyin initials correctly', () {
    expect(PinyinMatcher.matchSuggestions('KB'), contains('狂飙'));
    expect(PinyinMatcher.matchSuggestions('kb'), contains('狂飙'));
    expect(PinyinMatcher.matchSuggestions('FH'), contains('繁花'));
    expect(PinyinMatcher.matchSuggestions('QYN'), contains('庆余年'));
    expect(PinyinMatcher.matchSuggestions('XN'), contains('仙逆'));
    expect(PinyinMatcher.matchSuggestions('FR'), contains('凡人修仙传'));
    expect(PinyinMatcher.matchSuggestions('KN'), contains('名侦探柯南'));
    expect(PinyinMatcher.matchSuggestions('BY'), contains('白夜破晓'));
    expect(PinyinMatcher.matchSuggestions('TC'), contains('唐朝诡事录'));
  });

  test(
    'cleanTitle removes mathematical bold characters and domain watermarks',
    () {
      const rawWatermark =
          '𝕜𝕜𝕪𝕤𝟘𝟙.𝕔𝕠𝕞 名侦探柯南30号杀人事件 𝕜𝕜𝕪𝕤𝟘𝟙.𝕔𝕠𝕞';
      final cleaned = VideoSiteScraper.cleanTitle(rawWatermark);
      expect(cleaned, equals('名侦探柯南30号杀人事件'));

      const rawListTitle = '可可影视-kekys.com 一个烂赌的传说';
      expect(VideoSiteScraper.cleanTitle(rawListTitle), equals('一个烂赌的传说'));
    },
  );
}
