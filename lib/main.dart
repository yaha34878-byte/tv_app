import 'dart:async';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

const appName = 'قنواتي';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const TvApp());
}

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
              decoration: const InputDecoration(hintText: 'https://...'),
            ),
            const SizedBox(height: 16),
            const Text('أو اختر قائمة جاهزة:'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final p in presets)
                ActionChip(label: Text(p.$1), onPressed: () => Navigator.pop(c, p.$2)),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('حفظ')),
      ],
    ),
  );
  if (v != null && v.isNotEmpty) store.setUrl(v);
}

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final groups = store.byGroup.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final recents = store.recentChannels;
    final favs = store.favChannels;

    return ListView(padding: const EdgeInsets.all(12), children: [
      if (recents.isNotEmpty) ...[
        const SectionTitle('شاهدت مؤخرًا'),
        ChannelRow(channels: recents),
      ],
      if (favs.isNotEmpty) ...[
        const SectionTitle('المفضلة'),
        ChannelRow(channels: favs),
      ],
      const SectionTitle('التصنيفات'),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: groups.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2.2),
        itemBuilder: (_, i) {
          final g = groups[i];
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => Scaffold(
                          appBar: AppBar(title: Text(g.key)),
                          body: ChannelsPage(group: g.key),
                        ))),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(colors: [Color(0xFF2A2A36), Color(0xFF1B1B24)]),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Icon(groupIcon(g.key), color: Colors.deepOrange, size: 28),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(g.key, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('${g.value.length} قناة',
                          style: const TextStyle(fontSize: 12, color: Colors.white60)),
                    ])),
              ]),
            ),
          );
        },
      ),
    ]);
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      );
}

class ChannelRow extends StatelessWidget {
  final List<Channel> channels;
  const ChannelRow({super.key, required this.channels});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 110,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: channels.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final c = channels[i];
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => openPlayer(context, channels, i),
              child: Container(
                width: 100,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: const Color(0xFF1B1B24), borderRadius: BorderRadius.circular(14)),
                child: Column(children: [
                  Expanded(child: ChannelLogo(c.logo)),
                  const SizedBox(height: 6),
                  Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ]),
              ),
            );
          },
        ),
      );
}

class ChannelLogo extends StatelessWidget {
  final String url;
  const ChannelLogo(this.url, {super.key});
  @override
  Widget build(BuildContext context) => url.isEmpty
      ? const Icon(Icons.tv, size: 36)
      : CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.contain,
          errorWidget: (_, __, ___) => const Icon(Icons.tv, size: 36),
        );
}

class ChannelsPage extends StatefulWidget {
  final String? group;
  final bool favsOnly;
  const ChannelsPage({super.key, this.group, this.favsOnly = false});
  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  String query = '';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final base = widget.favsOnly
              ? store.favChannels
              : widget.group != null
                  ? (store.byGroup[widget.group] ?? [])
                  : store.all;
          final list = query.isEmpty
              ? base
              : base.where((c) => c.name.toLowerCase().contains(query.toLowerCase())).toList();
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'ابحث عن قناة',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => query = v),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text(widget.favsOnly ? 'لا توجد قنوات مفضلة بعد' : 'لا نتائج'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final c = list[i];
                        final fav = store.favs.contains(c.url);
                        return ListTile(
                          leading: SizedBox(width: 48, height: 48, child: ChannelLogo(c.logo)),
                          title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(c.group, maxLines: 1),
                          trailing: IconButton(
                            icon: Icon(fav ? Icons.star : Icons.star_border,
                                color: fav ? Colors.amber : null),
                            onPressed: () => store.toggleFav(c),
                          ),
                          onTap: () => openPlayer(context, list, i),
                        );
                      },
                    ),
            ),
          ]);
        },
      );
}

void openPlayer(BuildContext context, List<Channel> list, int index) {
  Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerPage(list: list, index: index)));
}

// ------------------------------------------------------------ المشغّل (media_kit)

class PlayerPage extends StatefulWidget {
  final List<Channel> list;
  final int index;
  const PlayerPage({super.key, required this.list, required this.index});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late int index = widget.index;
  late final Player player =
      Player(configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024));
  late final VideoController controller = VideoController(player);
  final List<StreamSubscription> _subs = [];
  Timer? _retryTimer;
  String? _err;
  int _retries = 0;

  final _controls = MaterialVideoControlsThemeData(
    volumeGesture: false,
    brightnessGesture: false,
    seekGesture: false,
  );

  Channel get channel => widget.list[index];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _subs.add(player.stream.error.listen((_) => _onFail()));
    _subs.add(player.stream.completed.listen((done) {
      if (done) _onFail();
    }));
    _subs.add(player.stream.playing.listen((p) {
      if (p) _retries = 0;
    }));
    _open(first: true);
  }

  void _open({bool first = false}) {
    _err = null;
    if (!first && mounted) setState(() {});
    store.addRecent(channel);
    player.open(Media(channel.url, httpHeaders: const {'User-Agent': 'Mozilla/5.0'}));
  }

  void _onFail() {
    if (!mounted) return;
    if (_retries < 3) {
      _retries++;
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) _open();
      });
    } else {
      setState(() => _err = 'تعذّر تشغيل القناة');
    }
  }

  void _go(int delta) {
    final n = index + delta;
    if (n < 0 || n >= widget.list.length) return;
    index = n;
    _retries = 0;
    _retryTimer?.cancel();
    _open();
  }

  String _vLabel(VideoTrack v) {
    if (v.id == 'auto') return 'تلقائي';
    if (v.id == 'no') return 'إيقاف';
    if (v.h != null) return '${v.h}p';
    return v.title ?? v.id;
  }

  String _aLabel(AudioTrack a) {
    if (a.id == 'auto') return 'تلقائي';
    if (a.id == 'no') return 'إيقاف';
    return a.title ?? a.language ?? a.id;
  }

  void _showTracks() {
    final t = player.state.tracks;
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(children: [
          const Padding(
              padding: EdgeInsets.all(12),
              child: Text('الجودة', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final v in t.video)
            ListTile(
              title: Text(_vLabel(v)),
              onTap: () {
                player.setVideoTrack(v);
                Navigator.pop(c);
              },
            ),
          const Padding(
              padding: EdgeInsets.all(12),
              child: Text('الصوت', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final a in t.audio)
            ListTile(
              title: Text(_aLabel(a)),
              onTap: () {
                player.setAudioTrack(a);
                Navigator.pop(c);
              },
            ),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(icon: const Icon(Icons.skip_previous), onPressed: () => _go(-1)),
            IconButton(icon: const Icon(Icons.skip_next), onPressed: () => _go(1)),
            IconButton(icon: const Icon(Icons.tune), onPressed: _showTracks),
          ],
        ),
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -400) _go(1);
            if (v > 400) _go(-1);
          },
          child: MaterialVideoControlsTheme(
            normal: _controls,
            fullscreen: _controls,
            child: Stack(fit: StackFit.expand, children: [
              Video(controller: controller),
              if (_err != null)
                Container(
                  color: Colors.black,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_err!),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: () {
                            _retries = 0;
                            _open();
                          },
                          child: const Text('إعادة المحاولة')),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      );
}
