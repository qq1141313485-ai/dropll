import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> installUpdate(Uri? pageUri) async {
  if (Platform.isAndroid) {
    final file = File('${(await getTemporaryDirectory()).path}/qiu-jing-update.apk');
    final response = await http.Client().send(http.Request(
      'GET',
      Uri.parse('https://cclloo.com/downloads/jingqiujing-1.0.1.apk'),
    ));
    if (response.statusCode != 200) throw const HttpException('下载失败');
    await response.stream.pipe(file.openWrite());
    await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    return;
  }
  if (pageUri != null) await launchUrl(pageUri);
}
