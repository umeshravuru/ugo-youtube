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
