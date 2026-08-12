import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'services/downloader.dart';
import 'services/library_store.dart';
import 'services/share_handler.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final baseDir = await _resolveBaseDir();
  final mediaDir = Directory('${baseDir.path}/videos');
  await mediaDir.create(recursive: true);

  _trustExtraCaIfPresent(baseDir);

  final store = LibraryStore(baseDir);
  await store.load();

  final downloader = DownloadManager(store: store, mediaDir: mediaDir);
  await downloader.cleanupStrayParts();

  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  downloader.onMessage = (msg) => messengerKey.currentState
      ?.showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));

  final share = ShareHandler();
  share.shared.listen(downloader.enqueueFromSharedText);
  await share.init();

  runApp(UgoApp(
    store: store,
    downloader: downloader,
    messengerKey: messengerKey,
  ));
}

/// Corporate-network support: if `extra_ca.pem` exists in the app's data
/// dir, trust it in addition to the system roots (never instead of them).
/// Lets the app work behind TLS-inspecting proxies like Zscaler.
void _trustExtraCaIfPresent(Directory baseDir) {
  try {
    final pem = File('${baseDir.path}/extra_ca.pem');
    if (!pem.existsSync()) return;
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(pem.path);
    HttpOverrides.global = _ExtraCaHttpOverrides(context);
  } catch (_) {}
}

class _ExtraCaHttpOverrides extends HttpOverrides {
  _ExtraCaHttpOverrides(this._context);

  final SecurityContext _context;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context ?? _context);
}

/// App-specific external storage on Android (no permissions needed, more
/// room), internal documents dir elsewhere / as fallback.
Future<Directory> _resolveBaseDir() async {
  if (Platform.isAndroid) {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    } catch (_) {}
  }
  return getApplicationDocumentsDirectory();
}

class UgoApp extends StatelessWidget {
  const UgoApp({
    super.key,
    required this.store,
    required this.downloader,
    required this.messengerKey,
  });

  final LibraryStore store;
  final DownloadManager downloader;
  final GlobalKey<ScaffoldMessengerState> messengerKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ugo-yt',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE53935),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: LibraryScreen(store: store, downloader: downloader),
    );
  }
}
