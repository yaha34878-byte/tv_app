import 'dart:async';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const appName = 'قنواتي';

void main() => runApp(const TvApp());

class Channel {
  final String name, url, logo, group;
  Channel(this.name, this.url, this.logo, this.group);
}

List<Channel> parseM3u(String body) {
  final out = <Channel>[];
  String? name, logo, group;
  for (final raw in body.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF')) {
      logo = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      group = RegExp(r'group-title="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      final i = line.lastIndexOf(',');
      name = i >= 0 ? line.substring(i + 1).trim() : 'قناة';
    } else if (line.isNotEmpty && !line.startsWith('#') && name != null) {
      out.add(Channel(name, line, logo ?? '', (group ?? '').isEmpty ? 'عام' : group!));
      name = null;
    }
  }
  return out;
}

class Store extends ChangeNotifier {
  List<Channel> all = [];
  Map<String, Channel> _byUrl = {};
  Set<String> favs = {};
  List<String> recents = [];
  String? playlistUrl, error;
  bool loading = false;

  List<Channel> get favChannels => [for (final u in favs) if (_byUrl[u] != null) _byUrl[u]!];
  List<Channel> get recentChannels => [for (final u in recents) if (_byUrl[u] != null) _byUrl[u]!];

  Map<String, List<Channel>> get byGroup {
    final m = <String, List<Channel>>{};
    for (final c in all) {
      m.putIfAbsent(c.group, () => []).add(c);
    }
    return m;
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    favs = (p.getStringList('favs') ?? []).toSet();
    recents = p.getStringList('recents') ?? [];
    playlistUrl = p.getString('playlist');
    notifyListeners();
    if (playlistUrl != null) await load();
  }

  Future<void> setUrl(String url) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('playlist', url);
    playlistUrl = url;
    await load();
  }

  Future<void> load() async {
    if (playlistUrl == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final r = await http.get(Uri.parse(playlistUrl!)).timeout(const Duration(seconds: 90));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final text = utf8.decode(r.bodyBytes, allowMalformed: true);
      all = await compute(parseM3u, text);
      _byUrl = {for (final c in all) c.url: c};
      if (all.isEmpty) error = 'لم يتم العثور على قنوات في القائمة';
    } catch (e) {
      error = 'تعذّر تحميل القائمة: $e';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> toggleFav(Channel c) async {
    favs.contains(c.url) ? favs.remove(c.url) : favs.add(c.url);
    final p = await SharedPreferences.getInstance();
    await p.setStringList('favs', favs.toList());
    notifyListeners();
  }

  Future<void> addRecent(Channel c) async {
    recents.remove(c.url);
    recents.insert(0, c.url);
    if (recents.length > 20) recents = recents.sublist(0, 20);
    final p = await SharedPreferences.getInstance();
    await p.setStringList('recents', recents);
    notifyListeners();
  }
}

final store = Store();

IconData groupIcon(String g) {
  final s = g.toLowerCase();
  if (s.contains('sport') || s.contains('رياض')) return Icons.sports_soccer;
  if (s.contains('news') || s.contains('خبار')) return Icons.newspaper;
  if (s.contains('movie') || s.contains('film') || s.contains('فلام')) return Icons.movie;
  if (s.contains('kid') || s.contains('child') || s.contains('طفال')) return Icons.child_care;
  if (s.contains('music') || s.contains('موسيق')) return Icons.music_note;
  if (s.contains('doc') || s.contains('وثائق')) return Icons.public;
  if (s.contains('relig') || s.contains('islam') || s.contains('دين')) return Icons.mosque;
  return Icons.tv;
}

class TvApp extends StatelessWidget {
  const TvApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.deepOrange,
          scaffoldBackgroundColor: const Color(0xFF0E0E12),
        ),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const SplashPage(),
      );
}

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    store.init();
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Shell()));
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.live_tv_rounded, size: 88, color: Colors.deepOrange),
            SizedBox(height: 16),
            Text(appName, style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
          ]),
        ),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (store.playlistUrl == null) askUrl(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const HomeTab(), const ChannelsPage(), const ChannelsPage(favsOnly: true)];
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: store.load),
          IconButton(icon: const Icon(Icons.settings), onPressed: () => askUrl(context)),
        ],
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          if (store.loading) return const Center(child: CircularProgressIndicator());
          if (store.error != null) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(store.error!, textAlign: TextAlign.center)));
          }
          if (store.all.isEmpty) {
            return const Center(child: Text('أضف رابط القائمة من زر الإعدادات'));
          }
          return pages[tab];
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'الرئيسية'),
          NavigationDestination(icon: Icon(Icons.live_tv_outlined), selectedIcon: Icon(Icons.live_tv), label: 'القنوات'),
          NavigationDestination(icon: Icon(Icons.star_border), selectedIcon: Icon(Icons.star), label: 'المفضلة'),
        ],
      ),
    );
  }
}

const presets = [
  ('عربية', 'https://iptv-org.github.io/iptv/languages/ara.m3u'),
  ('الجزائر', 'https://iptv-org.github.io/iptv/countries/dz.m3u'),
  ('رياضة', 'https://iptv-org.github.io/iptv/categories/sports.m3u'),
  ('أخبار', 'https://iptv-org.github.io/iptv/categories/news.m3u'),
  ('أفلام', 'https://iptv-org.github.io/iptv/categories/movies.m3u'),
  ('أطفال', 'https://iptv-org.github.io/iptv/categories/kids.m3u'),
  ('كل العالم', 'https://iptv-org.github.io/iptv/index.m3u'),
];

Future<void> askUrl(BuildContext context) async {
  final ctrl = TextEditingController(text: store.playlistUrl ?? '');
  final v = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('رابط قائمة M3U'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              textDirection: TextDirection.ltr,
