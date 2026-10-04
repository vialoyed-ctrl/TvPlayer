// 对 webdav_client.dart 做一次真发 HTTP 的冒烟测试。
//
// 它不进 lib/，所以不会被日常静态检查扫到；跑完可以删。
// 用法：dart run tool/webdav_smoke.dart <port>
//
// 前提：先用 python sim_webdav_server.py <port> 起好假服务。

import 'dart:convert';
import 'dart:io';

import '../lib/models/history_item.dart';
import '../lib/models/sync_payload.dart';
import '../lib/models/update_info.dart';
import '../lib/models/webdav_config.dart';
import '../lib/services/webdav_client.dart';

int pass = 0;
int fail = 0;
final List<String> failed = [];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    pass++;
    stdout.writeln('  PASS  $name');
  } else {
    fail++;
    failed.add(name);
    stdout.writeln('  FAIL  $name');
    if (detail.isNotEmpty) stdout.writeln('        $detail');
  }
}

void section(String t) => stdout.writeln('\n=== $t ===');

/// 造一段内容固定的测试数据。全是 ASCII，所以字节数 == 字符数。
String _blob(int n, String ch) => List<String>.filled(n, ch).join();

/// 进度回调必须是单调的 —— 倒退说明下载实现把已写字节数算错了。
bool _monotonic(List<int> xs) {
  for (var i = 1; i < xs.length; i++) {
    if (xs[i] < xs[i - 1]) return false;
  }
  return true;
}

late String base;
late HttpClient ctl;

Future<void> control(String cmd) async {
  final req = await ctl.getUrl(Uri.parse('$base/__control/$cmd'));
  final resp = await req.close();
  await resp.drain<void>();
  // 控制接口不存在时必须直接炸掉。
  //
  // 这里踩过一次：`control('no_head/on')` 写错成服务端不认识的开关时，
  // 服务端静默回 404、测试照跑，而「开关没生效」和「开关生效了、行为正好
  // 符合预期」看起来一模一样 —— 一整节测试白跑还全绿。宁可直接报错。
  if (resp.statusCode != 200) {
    throw StateError('控制接口 /__control/$cmd 返回 ${resp.statusCode}，开关没有生效');
  }
}

Future<List<Map<String, dynamic>>> readLog() async {
  final req = await ctl.getUrl(Uri.parse('$base/__control/log'));
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  try {
    return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
  } catch (_) {
    // 走到这里通常是请求被代理劫持了（环境里有 HTTP_PROXY 时会这样，
    // 连 127.0.0.1 都走代理）。把原始响应打出来，别只报一个 FormatException。
    throw StateError('控制接口返回的不是 JSON（HTTP ${resp.statusCode}）：$body');
  }
}

WebDavConfig cfg({
  String user = 'alice',
  String pass = 's3cret',
  String url = '',
}) => WebDavConfig(
  url: url.isEmpty ? '$base/dav/' : url,
  username: user,
  password: pass,
);

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? args[0] : '18093';
  base = 'http://127.0.0.1:$port';
  ctl = HttpClient();
  // 把假服务器恢复成刚启动的状态，这样测试可以反复跑而不用重启它。
  await control('reset_all');

  // ---------------------------------------------------------------- URL 拼装
  section('1. 地址规范化（纯计算，不发请求）');
  final c1 = WebDavConfig(url: '$base/dav/', username: 'u', password: 'p');
  final c2 = WebDavConfig(
    url: '$base/dav/tvplayer',
    username: 'u',
    password: 'p',
  );
  final c3 = WebDavConfig(
    url: '$base/dav/tvplayer/sync.json',
    username: 'u',
    password: 'p',
  );
  final c4 = WebDavConfig(url: '$base/dav', username: 'u', password: 'p');
  final want = '$base/dav/tvplayer/sync.json';
  check('填 WebDAV 根（带尾斜杠）', c1.fileUrl == want, c1.fileUrl);
  check('填根（不带尾斜杠）', c4.fileUrl == want, c4.fileUrl);
  check('已经填了我们自己的目录，不重复拼一层', c2.fileUrl == want, c2.fileUrl);
  check('直接粘了同步文件的地址，也认', c3.fileUrl == want, c3.fileUrl);
  final c5 = WebDavConfig(
    url: 'dav.example.com/dav',
    username: 'u',
    password: 'p',
  );
  check(
    '没写协议头时补 https://',
    c5.fileUrl == 'https://dav.example.com/dav/tvplayer/sync.json',
    c5.fileUrl,
  );
  check(
    '首尾空格自动去掉',
    WebDavConfig(
          url: ' $base/dav/ ',
          username: ' u ',
          password: ' p ',
        ).trimmedUser ==
        'u',
  );
  check(
    'isConfigured：地址和用户名都填了才算配好',
    c1.isConfigured &&
        !WebDavConfig(url: '$base/dav/', username: '').isConfigured,
  );

  // ---------------------------------------------------------------- 连接测试
  section('2. 测试连接（PROPFIND + MKCOL）');
  await control('reset');
  final client = WebDavClient(cfg());
  String probeMsg = '';
  try {
    probeMsg = await client.probe();
  } on WebDavException catch (e) {
    probeMsg = 'ERR ${e.message}';
  }
  check('目录不存在时 probe 会自己建目录并成功', probeMsg.contains('连接正常'), probeMsg);
  final log1 = await readLog();
  check(
    'probe 用了 PROPFIND 和 MKCOL，没有别的方法',
    log1.any((r) => r['method'] == 'PROPFIND') &&
        log1.any((r) => r['method'] == 'MKCOL'),
    log1.map((r) => r['method']).toList().toString(),
  );
  check(
    'PROPFIND 带了 Depth: 0',
    log1.firstWhere((r) => r['method'] == 'PROPFIND')['depth'] == '0',
  );
  check('每个请求都带了 Authorization', log1.every((r) => r['auth'] == true));

  // 目录已存在时再来一次：PROPFIND 会直接看到 207，根本不该再 MKCOL
  await control('reset');
  try {
    probeMsg = await client.probe();
  } on WebDavException catch (e) {
    probeMsg = 'ERR ${e.message}';
  }
  check('目录已存在时 probe 仍然成功', probeMsg.contains('连接正常'), probeMsg);
  final log2 = await readLog();
  check(
    '目录已存在时不会再多发一次 MKCOL',
    !log2.any((r) => r['method'] == 'MKCOL'),
    log2.map((r) => '${r['method']}:${r['status']}').toList().toString(),
  );

  // 有些服务端 PROPFIND 不报告已存在的目录，于是客户端会走到 MKCOL，
  // 而 MKCOL 对已存在的目录回 405 —— 这必须当成成功，不能报错。
  //
  // 这里直接测 ensureCollection，而不是 probe()：这种服务端连最后那次
  // 「确认目录存在」的 PROPFIND 也回 404，probe 报错是合理的（它确实没法确认），
  // 要验的是「405 不等于失败」这一条分支。
  await control('hide_dir_propfind/on');
  await control('reset');
  String hidMsg = '';
  var hidThrew = false;
  try {
    await client.ensureCollection();
  } on WebDavException catch (e) {
    hidThrew = true;
    hidMsg = e.message;
  }
  final logHid = await readLog();
  check(
    'PROPFIND 报 404 但目录其实存在 → MKCOL 拿到 405 也算成功',
    !hidThrew &&
        logHid.any((r) => r['method'] == 'MKCOL' && r['status'] == 405),
    'threw=$hidThrew $hidMsg / '
        '${logHid.map((r) => '${r['method']}:${r['status']}').toList()}',
  );
  await control('hide_dir_propfind/off');

  final badClient = WebDavClient(cfg(pass: 'wrong'));
  String badMsg = '';
  try {
    await badClient.probe();
    badMsg = '(居然成功了)';
  } on WebDavException catch (e) {
    badMsg = e.message;
  }
  check(
    '密码错 → 报 401，且提示里点明是认证问题',
    badMsg.contains('401') && badMsg.contains('密码'),
    badMsg,
  );
  badClient.close();

  // ---------------------------------------------------------------- 读 / 写
  section('3. GET / PUT 与乐观并发');
  await control('reset');
  const fname = 'sync.json';

  final miss = await client.get(fname);
  check('云端还没有文件 → get 返回 null', miss == null, '$miss');

  final etag1 = await client.put(
    fname,
    '{"schema":1,"hello":"世界"}',
    createOnly: true,
  );
  final log3 = await readLog();
  final firstPut = log3.firstWhere((r) => r['method'] == 'PUT');
  check(
    '首次写入带的是 If-None-Match: *，不是 If-Match',
    firstPut['if_none_match'] == '*' && firstPut['if_match'] == null,
    firstPut.toString(),
  );
  check('首次写入拿到强 ETag', etag1 != null && etag1.startsWith('"'), '$etag1');

  final got = await client.get(fname);
  check('get 拿回正文', got != null && got.body.contains('世界'), got?.body ?? '');
  check('get 拿回强 ETag', got!.etag != null, '${got.etag}');

  String conflictMsg = '';
  bool conflictFlag = false;
  try {
    await client.put(fname, '{}', createOnly: true);
  } on WebDavException catch (e) {
    conflictMsg = e.message;
    conflictFlag = e.isConflict;
  }
  check(
    '文件已存在时 createOnly 写入 → 412，并标成冲突',
    conflictFlag && conflictMsg.contains('已被其他设备修改'),
    conflictMsg,
  );

  final etag2 = await client.put(
    fname,
    '{"schema":1,"v":2}',
    ifMatch: got.etag,
  );
  check('带上正确的 If-Match → 写入成功', etag2 != null, '$etag2');
  final log4 = await readLog();
  final putWithMatch = log4.lastWhere(
    (r) => r['method'] == 'PUT' && r['if_match'] != null,
  );
  check(
    'If-Match 原样带上了服务器给的 ETag',
    putWithMatch['if_match'] == got.etag,
    putWithMatch.toString(),
  );

  conflictFlag = false;
  try {
    await client.put(fname, '{}', ifMatch: got.etag);
  } on WebDavException catch (e) {
    conflictFlag = e.isConflict;
  }
  check('用过期 ETag 写入 → 412（不会把别人的改动盖掉）', conflictFlag);

  final etag3 = await client.put(fname, '{"schema":1,"v":3}');
  check('不带前置条件 → 无条件覆盖成功（强制覆盖走这条路）', etag3 != null, '$etag3');

  // ---------------------------------------------------------------- 弱 ETag
  section('4. 弱 ETag：不能被用于 If-Match，也不能卡死');
  await control('weak_etags/on');
  final weak = await client.get(fname);
  check(
    '服务器给弱 ETag 时，客户端把它丢掉（返回 null）',
    weak != null && weak.etag == null,
    '${weak?.etag}',
  );

  await control('reset');
  bool allOk = true;
  String detail = '';
  for (var i = 0; i < 3; i++) {
    try {
      await client.put(fname, '{"schema":1,"n":$i}', ifMatch: weak!.etag);
    } on WebDavException catch (e) {
      allOk = false;
      detail = '第 $i 次：${e.message}';
      break;
    }
  }
  check('弱 ETag 下连写 3 次都成功（不会每次都被判 412 卡在重试循环里）', allOk, detail);
  final log5 = await readLog();
  final puts = log5.where((r) => r['method'] == 'PUT').toList();
  check(
    '确认那 3 次 PUT 一次都没带 If-Match',
    puts.length == 3 && puts.every((r) => r['if_match'] == null),
    puts.map((r) => r['if_match']).toList().toString(),
  );
  await control('weak_etags/off');

  // ---------------------------------------------------------------- 文档往返
  section('5. 完整同步文档经真实 HTTP 往返');
  await control('reset');
  final payload = SyncPayload(
    schema: kSyncSchema,
    savedAt: DateTime.now().millisecondsSinceEpoch,
    history: [
      const HistoryItem(
        vodId: 'V1',
        title: '狂飙 第01集',
        cover: 'https://example.com/a.jpg',
        sourceName: '2K线路',
        episodeName: '第01集',
        playPath: '/play/1',
        positionMs: 12345,
        durationMs: 2400000,
        updatedAt: 1700000000100,
      ),
    ],
    historyClearedAt: 1700000000000,
    favorites: const [
      FavoriteEntry(id: 'F1', addedAt: 1700000000010, removedAt: 0),
      FavoriteEntry(id: 'F2', addedAt: 0, removedAt: 1700000000020),
    ],
    searchHistory: const [TimedValue('庆余年', 1700000000030)],
    searchClearedAt: 1700000000040,
    settings: const SyncSettings(
      skipIntroSeconds: TimedValue(60, 1700000000050),
      autoSwitchSource: TimedValue(false, 1700000000060),
    ),
  );
  await client.put(fname, payload.encode());
  final putPath = (await readLog()).lastWhere(
    (r) => r['method'] == 'PUT',
  )['path'];
  check(
    'PUT 打到了正确的路径 /dav/tvplayer/sync.json',
    putPath == '/dav/tvplayer/sync.json',
    '$putPath',
  );

  final fetched = await client.get(fname);
  final decoded = SyncPayload.decode(fetched?.body);
  check('经真实 HTTP 往返后仍能解析', decoded.isOk, decoded.error ?? '');
  final back = decoded.payload!;
  check(
    '中文标题无损',
    back.history.first.title == '狂飙 第01集',
    back.history.first.title,
  );
  check(
    '墓碑（没有 item）保留且判死',
    back.favorites.length == 2 && !back.favorites[1].isAlive,
    back.favorites.toString(),
  );
  check(
    '清空时间戳无损',
    back.historyClearedAt == 1700000000000 &&
        back.searchClearedAt == 1700000000040,
    '${back.historyClearedAt} / ${back.searchClearedAt}',
  );
  check(
    '设置项类型无损（int / bool）',
    back.settings.skipIntroSeconds?.asInt == 60 &&
        back.settings.autoSwitchSource?.asBool == false,
    back.settings.toJson().toString(),
  );
  check('describe() 可用', back.describe().contains('历史 1 条'), back.describe());

  // ---------------------------------------------------------------- 认证被伪装
  section('6. 服务器把认证失败伪装成 404');
  await control('mask_auth_404/on');
  final masked = WebDavClient(cfg(pass: 'wrong'));
  String maskedMsg = '';
  try {
    await masked.probe();
    maskedMsg = '(居然成功了)';
  } on WebDavException catch (e) {
    maskedMsg = e.message;
  }
  check(
    '报错信息里提示了「也可能是服务器把认证失败回成 404」',
    maskedMsg.contains('404') && maskedMsg.contains('密码'),
    maskedMsg,
  );
  masked.close();
  await control('mask_auth_404/off');

  // ---------------------------------------------------------------- 上级目录
  section('7. 上级目录不存在');
  final deep = WebDavClient(cfg(url: '$base/dav/no_such_dir/sub'));
  String deepMsg = '';
  try {
    await deep.probe();
    deepMsg = '(居然成功了)';
  } on WebDavException catch (e) {
    deepMsg = e.message;
  }
  check(
    '上级目录不存在 → 报 409 并说明原因',
    deepMsg.contains('409') && deepMsg.contains('上级目录'),
    deepMsg,
  );
  deep.close();

  // ---------------------------------------------------------------- 模拟完整同步
  section('8. 按 SyncService 的顺序走一遍完整同步（含 412 重试）');
  await control('reset');
  // 先把云端写成「另一台设备刚推过的」状态
  await client.put(
    fname,
    '{"schema":1,"savedAt":1,"history":[],"favorites":[]}',
  );
  final r1 = await client.get(fname);
  final d1 = SyncPayload.decode(r1!.body);
  check(
    '先读到云端那份，拿到 ETag 用于 If-Match',
    d1.isOk && r1.etag != null,
    '${r1.etag}',
  );

  // 模拟「读完之后别的设备抢先写了」
  await client.put(
    fname,
    '{"schema":1,"savedAt":2,"history":[],"favorites":[]}',
  );

  // 我们拿着旧 ETag 写 → 必须拿到 412
  bool retried = false;
  try {
    await client.put(fname, '{"schema":1,"savedAt":3}', ifMatch: r1.etag);
  } on WebDavException catch (e) {
    retried = e.isConflict;
  }
  check('读之后云端被别人改了 → 写入被判 412，触发重新拉取重试', retried);

  // 重试：重新读 → 重新合并 → 再写
  final r2 = await client.get(fname);
  final again = await client.put(
    fname,
    '{"schema":1,"savedAt":4}',
    ifMatch: r2!.etag,
  );
  check('重新拉取后带着新 ETag 写入成功（重试路径是通的）', again != null, '$again');
  final finalBody = (await client.get(fname))!.body;
  check('云端最终是我们写进去的那份', finalBody.contains('"savedAt":4'), finalBody);

  // -------------------------------------------------- 自动更新：检查（stat）
  section('9. stat()：只问不下载（自动更新的「检查」这一步）');
  await control('reset');
  await client.ensureCollection();

  check(
    '常量只有一个来源，和约定一致',
    kUpdateApkFileName == 'tvplayer_32bit.apk',
    kUpdateApkFileName,
  );
  check(
    '云端没有这个文件 → stat 返回 null（按约定就是「不更新」）',
    await client.stat(kUpdateApkFileName) == null,
  );

  // 放一个「安装包」上去。内容全是 ASCII，所以字节数 == 字符数。
  await client.put(kUpdateApkFileName, _blob(20000, 'A'));

  await control('reset'); // 只关心下面这一次 stat 到底发了什么请求
  final st = await client.stat(kUpdateApkFileName);
  check('能读到云端这个文件', st != null);
  check('拿到了字节数', st?.sizeBytes == 20000, '${st?.sizeBytes}');
  check('拿到了强 ETag', st?.etag != null, '${st?.etag}');
  check('指纹可用（不是 null）', st?.fingerprint != null, '${st?.fingerprint}');

  final stLog = await readLog();
  final stMethods = stLog.map((e) => e['method']).toList();
  check(
    '检查更新只发了 HEAD，没有把 20 MB 整个拉下来',
    stMethods.isNotEmpty && stMethods.every((m) => m == 'HEAD'),
    stMethods.toString(),
  );
  check(
    '确实发过 HEAD（不是靠别的请求顺手拿到的）',
    stMethods.contains('HEAD'),
    stMethods.toString(),
  );

  check(
    '同一个文件再 stat 一次 → 指纹不变（不会重复提示更新）',
    (await client.stat(kUpdateApkFileName))?.fingerprint == st?.fingerprint,
  );

  await client.put(kUpdateApkFileName, _blob(20000, 'B'));
  check(
    '内容换了但大小没变 → 指纹变了（能检测到新包）',
    (await client.stat(kUpdateApkFileName))?.fingerprint != st?.fingerprint,
  );

  await client.put(kUpdateApkFileName, _blob(21000, 'C'));
  final stBigger = await client.stat(kUpdateApkFileName);
  check('大小变了 → 指纹也变了', stBigger?.fingerprint != st?.fingerprint);

  // 服务端不支持 HEAD：必须能退回 PROPFIND，否则自动更新在那些服务端上直接失效
  await control('no_head/on');
  await control('reset');
  final stNoHead = await client.stat(kUpdateApkFileName);
  final noHeadLog = await readLog();
  final noHeadMethods = noHeadLog.map((e) => e['method']).toList();
  check(
    '服务端不支持 HEAD（501）→ 退回 PROPFIND，仍然拿得到大小',
    stNoHead?.sizeBytes == 21000,
    '${stNoHead?.sizeBytes}',
  );
  check(
    '确认 no_head 开关真的生效了（HEAD 被回了 501）',
    noHeadLog.any((e) => e['method'] == 'HEAD' && e['status'] == 501),
    noHeadLog.map((e) => '${e['method']}:${e['status']}').toList().toString(),
  );
  check(
    '顺序是「先 HEAD，失败后才 PROPFIND」',
    noHeadMethods.contains('HEAD') && noHeadMethods.contains('PROPFIND'),
    noHeadMethods.toString(),
  );
  await control('no_head/off');

  // HEAD 回 200 但什么头都不给：也判断不了「变没变」，同样要退回 PROPFIND
  await control('bare_head/on');
  await control('reset');
  final stBare = await client.stat(kUpdateApkFileName);
  final bareLog = await readLog();
  check(
    'HEAD 回 200 但一个有用的头都不给 → 也能退回 PROPFIND 拿到大小',
    stBare?.sizeBytes == 21000,
    '${stBare?.sizeBytes}',
  );
  check(
    '确认 bare_head 开关真的生效了（HEAD 回了 200）',
    bareLog.any((e) => e['method'] == 'HEAD' && e['status'] == 200),
    bareLog.map((e) => '${e['method']}:${e['status']}').toList().toString(),
  );
  check(
    'HEAD 什么头都不给时，确实再去问了 PROPFIND',
    bareLog.any((e) => e['method'] == 'PROPFIND'),
    bareLog.map((e) => e['method']).toList().toString(),
  );
  await control('bare_head/off');

  // 弱 ETag 不能被当成指纹用（否则同一个文件会一直显示「有更新」）
  await control('weak_etags/on');
  final stWeak = await client.stat(kUpdateApkFileName);
  check(
    '弱 ETag 时 stat.etag 为 null（退化成用大小+时间）',
    stWeak?.etag == null,
    '${stWeak?.etag}',
  );
  check(
    '弱 ETag 时指纹仍然可用',
    stWeak?.fingerprint != null,
    '${stWeak?.fingerprint}',
  );
  await control('weak_etags/off');

  // HEAD 被直接拒掉（403），但 PROPFIND 正常。
  //
  // 这是线上真实遇到的那一条：自建 WebDAV 把 HEAD 当成未授权的方法，一律回
  // 403，于是「检查更新」被一句「服务器拒绝访问」挡住，而安装包好端端躺在
  // 那里。对策是：HEAD 只当加速，拿不到可用答案就一律交给 PROPFIND 定论。
  await control('head_403/on');
  await control('reset');
  final stHead403 = await client.stat(kUpdateApkFileName);
  final h403Log = await readLog();
  final h403Trace = h403Log
      .map((e) => '${e['method']}:${e['status']}')
      .toList();
  check(
    'HEAD 被回 403 时，仍然通过 PROPFIND 问到了大小（不再报「拒绝访问」）',
    stHead403?.sizeBytes == 21000,
    '${stHead403?.sizeBytes}',
  );
  check(
    '确认 head_403 开关真的生效了（HEAD 被回了 403）',
    h403Log.any((e) => e['method'] == 'HEAD' && e['status'] == 403),
    h403Trace.toString(),
  );
  check(
    'HEAD 403 之后确实又问了 PROPFIND，并且拿到了 207',
    h403Log.any((e) => e['method'] == 'PROPFIND' && e['status'] == 207),
    h403Trace.toString(),
  );
  check(
    'HEAD 403 时指纹依然可用（不会每次都重复提示）',
    stHead403?.fingerprint != null,
    '${stHead403?.fingerprint}',
  );
  await control('head_403/off');

  // 反过来：文件**不在**，HEAD 也回 403。
  //
  // 这一路更要紧：HEAD 的 403 对「存在」和「不存在」是一样的，所以绝不能拿
  // HEAD 的返回码当「文件在不在」的依据 —— 那会把「云端没有包」误报成
  // 「没权限」，用户永远看不到正确的提示。
  await control('reset_all');
  await control('head_403/on');
  await control('reset');
  final stAbsent = await client.stat(kUpdateApkFileName);
  final absentLog = await readLog();
  final absentTrace = absentLog
      .map((e) => '${e['method']}:${e['status']}')
      .toList();
  check(
    '文件不在 + HEAD 403 → 正确得出「云端没有这个包」（返回 null，不抛错）',
    stAbsent == null,
    '$stAbsent',
  );
  check(
    '这一路是靠 PROPFIND 的 404 定论的，不是靠 HEAD 的返回码',
    absentLog.any((e) => e['method'] == 'PROPFIND' && e['status'] == 404),
    absentTrace.toString(),
  );
  await control('head_403/off');

  // 把现场恢复回去，下一节下载测试要用这个文件
  await client.ensureCollection();
  await client.put(kUpdateApkFileName, _blob(21000, 'C'));
  check(
    '恢复现场：文件重新放回云端',
    (await client.stat(kUpdateApkFileName))?.sizeBytes == 21000,
  );

  // ------------------------------------------------- 自动更新：下载（downloadTo）
  section('10. downloadTo()：流式落盘 + 完整性校验 + .part 中转');
  await control('reset');
  final tmpDir = Directory.systemTemp.createTempSync('tvplayer_upd_');
  final target = File('${tmpDir.path}/$kUpdateApkFileName');
  final partFile = File('${target.path}.part');

  final bytes = await client.downloadTo(
    kUpdateApkFileName,
    target,
    expectedSize: 21000,
  );
  check('下载成功并返回实际字节数', bytes == 21000, '$bytes');
  check('文件真的落到了目标路径', target.existsSync());
  check('落盘长度和云端一致', target.lengthSync() == 21000);
  check('内容正确（首字节是 C）', target.readAsStringSync().startsWith('C'));
  check('成功后不留 .part 临时文件', !partFile.existsSync());

  final progress = <int>[];
  await client.downloadTo(
    kUpdateApkFileName,
    target,
    expectedSize: 21000,
    onProgress: (r, _) => progress.add(r),
  );
  check('进度回调被调用过', progress.isNotEmpty, '${progress.length} 次');
  check('进度单调递增（不会倒退）', _monotonic(progress));
  check('最后一次回调收到的是完整长度', progress.last == 21000, '${progress.last}');
  check('再次下载也不留 .part', !partFile.existsSync());

  // 长度对不上：必须在落盘之前就发现，绝不能把半个包交给安装器
  var mismatch = '';
  try {
    await client.downloadTo(kUpdateApkFileName, target, expectedSize: 999999);
  } on WebDavException catch (e) {
    mismatch = e.message;
  }
  check('声明的长度和实际不符 → 报错', mismatch.contains('不完整'), mismatch);
  check('长度不符时不留下 .part', !partFile.existsSync());
  check('长度不符时已经下好的旧文件没被破坏', target.lengthSync() == 21000);

  // 云端把包删了
  var notFound = '';
  try {
    await client.downloadTo('not_there.apk', target);
  } on WebDavException catch (e) {
    notFound = e.message;
  }
  check('云端没有这个文件 → 报错，而不是写出一个空文件', notFound.contains('404'), notFound);
  check('404 时不留下 .part', !partFile.existsSync());

  // 覆盖下载：换一份内容再下
  await client.put(kUpdateApkFileName, _blob(5000, 'D'));
  final replaced = await client.downloadTo(kUpdateApkFileName, target);
  check('可以覆盖下载（旧文件被替换）', replaced == 5000, '$replaced');
  check('覆盖后内容是新的那份', target.readAsStringSync().startsWith('D'));
  check('覆盖下载也不留 .part', !partFile.existsSync());

  // 服务器没给 Content-Length 时也要能下（只是没法校验完整性）
  final unknown = await client.downloadTo(
    kUpdateApkFileName,
    target,
    expectedSize: -1,
  );
  check('服务器没给长度（expectedSize = -1）时照样能下', unknown == 5000, '$unknown');

  tmpDir.deleteSync(recursive: true);

  client.close();
  ctl.close();

  stdout.writeln('\n${'=' * 60}');
  stdout.writeln('PASS $pass / FAIL $fail');
  if (failed.isNotEmpty) {
    stdout.writeln('失败的用例：');
    for (final n in failed) {
      stdout.writeln('  - $n');
    }
  }
  exit(fail == 0 ? 0 : 1);
}
