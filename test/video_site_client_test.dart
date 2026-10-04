import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvplayer/services/video_site_client.dart';

void main() {
  VideoSiteClient clientWith(
    void Function(RequestOptions, RequestInterceptorHandler) respond,
  ) {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: respond));
    return VideoSiteClient(
      dio: dio,
      sites: List.generate(10, (i) => 'https://video$i.example.test'),
    );
  }

  void success(RequestOptions request, RequestInterceptorHandler handler) {
    handler.resolve(
      Response<String>(
        requestOptions: request,
        statusCode: 200,
        data: '<html><body>OK</body></html>',
      ),
    );
  }

  test(
    'tries 0 through 9 and remembers the working site, preserving URL',
    () async {
      final requests = <RequestOptions>[];
      final client = clientWith((request, handler) {
        requests.add(request);
        if (request.uri.host == 'video9.example.test') {
          success(request, handler);
        } else {
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            ),
          );
        }
      });
      await client.getHtml('/search?k=test', queryParameters: {'page': 2});
      expect(
        requests.map((r) => r.uri.host),
        List.generate(10, (i) => 'video$i.example.test'),
      );
      expect(requests.last.uri.path, '/search');
      expect(requests.last.uri.queryParameters, {'k': 'test', 'page': '2'});
      expect(client.activeBaseUrl, 'https://video9.example.test');
      requests.clear();
      await client.getHtml('https://video0.example.test/detail/123.html');
      expect(requests.single.uri.host, 'video9.example.test');
      expect(requests.single.uri.path, '/detail/123.html');
      expect(
        requests.single.headers['Referer'],
        'https://video9.example.test/',
      );
    },
  );

  test('skips HTTP errors, empty pages, and unsolved challenges', () async {
    final seen = <String>[];
    final client = clientWith((request, handler) {
      seen.add(request.uri.host);
      final index = seen.length - 1;
      if (index == 3) {
        success(request, handler);
        return;
      }
      handler.resolve(
        Response<String>(
          requestOptions: request,
          statusCode: index == 0
              ? 503
              : index == 2
              ? 850
              : 200,
          data: index == 1 ? '' : '<html>Protected by cdndefend</html>',
        ),
      );
    });
    await client.getHtml('/');
    expect(seen.length, 4);
    expect(client.activeBaseUrl, 'https://video3.example.test');
  });

  test(
    'all failures produce a readable error and keep the previous site',
    () async {
      var attempts = 0;
      final client = clientWith((request, handler) {
        attempts++;
        handler.reject(
          DioException(
            requestOptions: request,
            type: DioExceptionType.connectionTimeout,
          ),
        );
      });
      await expectLater(
        client.getHtml('/'),
        throwsA(isA<VideoSiteUnavailableException>()),
      );
      expect(attempts, 10);
      expect(client.activeBaseUrl, 'https://video0.example.test');
    },
  );

  test('a previously working site can fail and switch again', () async {
    var workingHost = 'video5.example.test';
    final client = clientWith((request, handler) {
      if (request.uri.host == workingHost) {
        success(request, handler);
        return;
      }
      handler.reject(
        DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        ),
      );
    });
    await client.getHtml('/');
    expect(client.activeBaseUrl, 'https://video5.example.test');
    workingHost = 'video2.example.test';
    await client.getHtml('/');
    expect(client.activeBaseUrl, 'https://video2.example.test');
  });

  test('cancellation does not trigger domain failover', () async {
    var attempts = 0;
    final client = clientWith((request, handler) {
      attempts++;
      handler.reject(
        DioException(requestOptions: request, type: DioExceptionType.cancel),
      );
    });
    await expectLater(client.getHtml('/'), throwsA(isA<DioException>()));
    expect(attempts, 1);
  });
}
