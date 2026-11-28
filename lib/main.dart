import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

late SharedPreferences prefs;
final ValueNotifier<int> appEpoch = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('seed_user_v1') != true) {
    final hasData = _bkKeys.any((k) => prefs.getString(k) != null);
    if (!hasData) {
      final d = parseBackup(_seedBackup);
      if (d != null) await writeBackupToPrefs(d);
    }
    await prefs.setBool('seed_user_v1', true);
  }
  try {
    await initNotifications();
    await rescheduleAll();
  } catch (_) {}
  runApp(const App());
}

// ---------- Yardımcılar ----------
typedef Rec = Map<String, dynamic>;

List<Rec> loadList(String key) {
  final s = prefs.getString(key);
  if (s == null) return [];
  return (jsonDecode(s) as List).map((e) => Rec.from(e as Map)).toList();
}

Future<void> saveList(String key, List<Rec> l) =>
    prefs.setString(key, jsonEncode(l));

String newId() => DateTime.now().microsecondsSinceEpoch.toString();
String two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${two(d.day)}.${two(d.month)}.${d.year}';
String ym(DateTime d) => '${d.year}-${two(d.month)}';

DateTime parseDate(dynamic s) {
  final p = (s ?? '').toString().split('.');
  if (p.length == 3) {
    final d = int.tryParse(p[0]), m = int.tryParse(p[1]), y = int.tryParse(p[2]);
    if (d != null && m != null && y != null) return DateTime(y, m, d);
  }
  return DateTime(2000);
}

double toNum(dynamic s) =>
    double.tryParse((s ?? '').toString().replaceAll(',', '.')) ?? 0;

String money(num v) => '${v.toStringAsFixed(2)} ₺';

Future<bool> confirmDelete(BuildContext c, [String? msg]) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: const Text('Silinsin mi?'),
      content: msg == null ? null : Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
      ],
    ),
  );
  return r ?? false;
}

// ---------- Bildirimler ----------
final FlutterLocalNotificationsPlugin notifPlugin = FlutterLocalNotificationsPlugin();

const NotificationDetails _notifDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'hatirlatma',
    'Hatırlatmalar',
    channelDescription: 'Kişisel hatırlatmalar',
    importance: Importance.max,
    priority: Priority.high,
  ),
);

Future<void> initNotifications() async {
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));
  const init = InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher'));
  await notifPlugin.initialize(init);
  final a = notifPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  try {
    await a?.requestNotificationsPermission();
    final ok = await a?.canScheduleExactNotifications();
    if (ok == false) await a?.requestExactAlarmsPermission();
  } catch (_) {}
}

DateTime? parseAt(String date, String time) {
  final d = parseDate(date);
  final p = time.split(':');
  if (p.length != 2) return null;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  if (h == null || m == null) return null;
  return DateTime(d.year, d.month, d.day, h, m);
}

int newNid() => 1000000000 + DateTime.now().microsecondsSinceEpoch % 900000000;

Future<void> scheduleReminder(Rec r) async {
  if (r['at'] == null || r['nid'] == null) return;
  final when = tz.TZDateTime.from(DateTime.parse('${r['at']}'), tz.local);
  if (when.isBefore(tz.TZDateTime.now(tz.local))) return;
  final id = r['nid'] as int;
  final head = '${r['ntitle'] ?? 'Hatırlatma'}';
  final body = '${r['body'] ?? r['title']}';
  try {
    await notifPlugin.zonedSchedule(id, head, body, when, _notifDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
  } catch (_) {
    try {
      await notifPlugin.zonedSchedule(id, head, body, when, _notifDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
    } catch (_) {}
  }
}

Future<void> rescheduleAll() async {
  for (final r in loadList('reminders')) {
    if (r['done'] != true) await scheduleReminder(r);
  }
  for (final r in loadList('vehicle_entries')) {
    if (r['kind'] == 'tax') await scheduleReminder(r);
  }
  for (final r in loadList('payments')) {
    await scheduleReminder(r);
  }
  for (final r in loadList('tasks')) {
    await scheduleReminder(r);
  }
  for (final r in loadRecurring()) {
    await scheduleRecurring(r);
  }
}

Future<void> scheduleRecurring(Rec r) async {
  if (r['nid'] == null) return;
  final t = '${r['time'] ?? ''}'.split(':');
  final h = t.length == 2 ? (int.tryParse(t[0]) ?? 9) : 9;
  final m = t.length == 2 ? (int.tryParse(t[1]) ?? 0) : 0;
  final base = (r['nid'] as int) * 10;
  for (final wd in (r['days'] as List)) {
    final w = wd as int;
    final now = tz.TZDateTime.now(tz.local);
    var when = tz.TZDateTime(tz.local, now.year, now.month, now.day, h, m);
    for (var i = 0; i < 9 && (when.weekday != w || !when.isAfter(now)); i++) {
      when = when.add(const Duration(days: 1));
    }
    try {
      await notifPlugin.zonedSchedule(base + w, 'Hatırlatma', '${r['title']}', when, _notifDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime);
    } catch (_) {
      try {
        await notifPlugin.zonedSchedule(base + w, 'Hatırlatma', '${r['title']}', when, _notifDetails,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime);
      } catch (_) {}
    }
  }
}

Future<void> cancelRecurring(Rec r) async {
  if (r['nid'] == null) return;
  for (var w = 1; w <= 7; w++) {
    try {
      await notifPlugin.cancel((r['nid'] as int) * 10 + w);
    } catch (_) {}
  }
}

Future<void> cancelReminder(Rec r) async {
  try {
    await notifPlugin.cancel(r['nid'] as int);
  } catch (_) {}
}

class F {
  final String key, label, init;
  final bool number, date, time;
  final List<String> options;
  const F(this.key, this.label,
      {this.number = false, this.date = false, this.time = false, this.init = '', this.options = const []});
}

Future<Map<String, String>?> inputDialog(BuildContext context, String title, List<F> fields) {
  final ctrls = {for (final f in fields) f.key: TextEditingController(text: f.init)};
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in fields)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (f.options.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(spacing: 6, runSpacing: 0, children: [
                        for (final o in f.options)
                          ActionChip(label: Text(o), onPressed: () => ctrls[f.key]!.text = o),
                      ]),
                    ),
                  TextField(
                    controller: ctrls[f.key],
                    readOnly: f.date || f.time,
                    keyboardType: f.number
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.text,
                    decoration: InputDecoration(
                      labelText: f.label,
                      border: const OutlineInputBorder(),
                      suffixIcon: f.date ? const Icon(Icons.calendar_today) : (f.time ? const Icon(Icons.access_time) : null),
                    ),
                    onTap: f.time
                        ? () async {
                            final tm = await showTimePicker(context: ctx, initialTime: TimeOfDay.now());
                            if (tm != null) ctrls[f.key]!.text = '${two(tm.hour)}:${two(tm.minute)}';
                          }
                        : f.date
                        ? () async {
                            final t = ctrls[f.key]!.text;
                            final d = await showDatePicker(
                              context: ctx,
                              initialDate: t.isEmpty ? DateTime.now() : parseDate(t),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (d != null) ctrls[f.key]!.text = fmtDate(d);
                          }
                        : null,
                  ),
                ]),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
        FilledButton(
          onPressed: () => Navigator.pop(
              ctx, {for (final e in ctrls.entries) e.key: e.value.text.trim()}),
          child: const Text('Kaydet'),
        ),
      ],
    ),
  );
}

Widget emptyState(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
        ]),
      ),
    );

Widget _circle(double d, double o) => Container(
      width: d,
      height: d,
      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(o)),
    );

PreferredSizeWidget heroBar(String title, List<Color> colors, {PreferredSizeWidget? bottom}) => AppBar(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 28, letterSpacing: -0.4)),
      toolbarHeight: 84,
      centerTitle: false,
      foregroundColor: Colors.white,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      bottom: bottom,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(bottom: Radius.circular(30))),
      flexibleSpace: Stack(fit: StackFit.expand, children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
        ),
        Positioned(right: -40, top: -60, child: _circle(170, 0.13)),
        Positioned(right: 80, bottom: -62, child: _circle(110, 0.09)),
      ]),
    );

const deleteHint = Padding(
  padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
  child: Text('Düzenlemek veya silmek için kaydın üzerine uzun basın', style: TextStyle(color: Colors.grey, fontSize: 12)),
);

Future<bool> deleteSheet(BuildContext c, String title) async {
  final r = await showModalBottomSheet<bool>(
    context: c,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.red),
          title: const Text('Sil', style: TextStyle(color: Colors.red)),
          onTap: () => Navigator.pop(ctx, true),
        ),
        ListTile(
          leading: const Icon(Icons.close),
          title: const Text('Vazgeç'),
          onTap: () => Navigator.pop(ctx, false),
        ),
      ]),
    ),
  );
  return r ?? false;
}

Future<String?> actionSheet(BuildContext c, String title) {
  return showModalBottomSheet<String>(
    context: c,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Düzenle'),
          onTap: () => Navigator.pop(ctx, 'edit'),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.red),
          title: const Text('Sil', style: TextStyle(color: Colors.red)),
          onTap: () => Navigator.pop(ctx, 'delete'),
        ),
        ListTile(
          leading: const Icon(Icons.close),
          title: const Text('Vazgeç'),
          onTap: () => Navigator.pop(ctx),
        ),
      ]),
    ),
  );
}

class Tile extends StatelessWidget {
  final Color color;
  final Widget? leading, title, subtitle, trailing;
  final VoidCallback? onTap, onLongPress;
  final bool isThreeLine;
  const Tile({super.key, required this.color, this.leading, this.title, this.subtitle, this.trailing, this.onTap, this.onLongPress, this.isThreeLine = false});
  @override
  Widget build(BuildContext c) => Card(
        elevation: 0,
        color: Theme.of(c).brightness == Brightness.dark ? const Color(0xFF181C24) : Colors.white,
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.fromLTRB(16, 5, 16, 5),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: color.withOpacity(0.3))),
        child: ListTile(
          leading: leading == null
              ? null
              : Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [color, Color.lerp(color, Colors.white, 0.35)!],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: IconTheme(data: const IconThemeData(color: Colors.white), child: leading!),
                ),
          title: title,
          subtitle: subtitle,
          trailing: trailing,
          onTap: onTap,
          onLongPress: onLongPress,
          isThreeLine: isThreeLine,
        ),
      );
}

class CTile extends StatelessWidget {
  final Color color;
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final Widget? title, subtitle, secondary;
  final VoidCallback? onLongPress;
  const CTile({super.key, required this.color, this.value, this.onChanged, this.title, this.subtitle, this.secondary, this.onLongPress});
  @override
  Widget build(BuildContext c) => GestureDetector(
        onLongPress: onLongPress,
        child: Card(
          elevation: 0,
          color: Theme.of(c).brightness == Brightness.dark ? const Color(0xFF181C24) : Colors.white,
          clipBehavior: Clip.antiAlias,
          margin: const EdgeInsets.fromLTRB(16, 5, 16, 5),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: color.withOpacity(0.3))),
          child: CheckboxListTile(
            value: value,
            onChanged: onChanged,
            title: title,
            subtitle: subtitle,
            secondary: secondary,
            activeColor: color,
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ),
      );
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B5BDB), brightness: b),
    scaffoldBackgroundColor: dark ? const Color(0xFF0F1218) : const Color(0xFFF4F5F9),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: dark ? const Color(0xFF181C24) : Colors.white,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Kişisel Takip',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ValueListenableBuilder<int>(valueListenable: appEpoch, builder: (_, e, __) => Home(key: ValueKey(e))),
      );
}

NavigationDestination _nav(IconData i, String label, Color c) => NavigationDestination(
      icon: Icon(i, color: c.withOpacity(0.55)),
      selectedIcon: Icon(i, color: c),
      label: label,
    );

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int i = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: i, children: const [
          TasksPage(),
          VehiclesPage(),
          RemindersPage(),
          ShiftPage(),
          PaymentsPage(),
          SettingsPage(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: i,
          onDestinationSelected: (v) => setState(() => i = v),
          destinations: [
            _nav(Icons.checklist, 'Günlük', const Color(0xFF4263EB)),
            _nav(Icons.directions_car, 'Araçlar', const Color(0xFF0C8599)),
            _nav(Icons.notifications_active, 'Hatırlat', const Color(0xFFD6336C)),
            _nav(Icons.calendar_month, 'Vardiya', const Color(0xFF7048E8)),
            _nav(Icons.payments, 'Ödemeler', const Color(0xFF0CA678)),
            _nav(Icons.settings, 'Ayarlar', const Color(0xFF364FC7)),
          ],
        ),
      );
}

// ---------- 1) ARAÇLAR ----------
const _vehC1 = Color(0xFF0C8599);
const _vehC2 = Color(0xFF22B8CF);

int daysLeft(dynamic due) {
  final d = parseDate(due), n = DateTime.now();
  return DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
}

String dueText(int d) => d < 0 ? '${-d} gün geçti' : (d == 0 ? 'Bugün' : '$d gün kaldı');
Color dueColor(int d) => d < 0 ? Colors.red : (d <= 30 ? Colors.orange.shade800 : Colors.green.shade700);

class VehiclesPage extends StatefulWidget {
  const VehiclesPage({super.key});
  @override
  State<VehiclesPage> createState() => _VehiclesPageState();
}

class _VehiclesPageState extends State<VehiclesPage> {
  List<Rec> items = loadList('vehicles');

  List<Rec> upcoming() {
    final res = <Rec>[];
    for (final e in loadList('vehicle_entries')) {
      if (e['kind'] != 'tax') continue;
      if ((e['date'] ?? '').toString().isEmpty) continue;
      final d = daysLeft(e['date']);
      if (d < 0 || d > 30) continue;
      final v = items.where((x) => x['id'] == e['vid']).toList();
      if (v.isEmpty) continue;
      final plate = (v.first['plate'] ?? '').toString();
      res.add({'title': e['title'], 'veh': plate.isEmpty ? v.first['name'] : plate, 'days': d});
    }
    res.sort((a, b) => (a['days'] as int).compareTo(b['days'] as int));
    return res;
  }

  Future<void> add() async {
    final r = await inputDialog(context, 'Araç ekle',
        [const F('name', 'Araç (marka / model)'), const F('plate', 'Plaka')]);
    if (r == null || r['name']!.isEmpty) return;
    setState(() => items.add({'id': newId(), ...r}));
    await saveList('vehicles', items);
  }

  Future<void> editVehicle(Rec v) async {
    final r = await inputDialog(context, 'Aracı düzenle', [
      F('name', 'Araç (marka / model)', init: '${v['name'] ?? ''}'),
      F('plate', 'Plaka', init: '${v['plate'] ?? ''}'),
    ]);
    if (r == null || r['name']!.isEmpty) return;
    setState(() {
      v['name'] = r['name'];
      v['plate'] = r['plate'];
    });
    await saveList('vehicles', items);
    final all = loadList('vehicle_entries');
    final label = r['plate']!.isEmpty ? r['name']! : r['plate']!;
    for (final e in all.where((e) => e['vid'] == v['id'] && e['kind'] == 'tax')) {
      e['body'] = '$label  •  ${e['title']}';
      await cancelReminder(e);
      await scheduleReminder(e);
    }
    await saveList('vehicle_entries', all);
  }

  Future<void> actions(Rec v) async {
    final a = await actionSheet(context, '${v['name']} ${v['plate'] ?? ''}');
    if (a == 'edit') {
      await editVehicle(v);
    } else if (a == 'delete') {
      await remove(v);
    }
  }

  Future<void> remove(Rec v) async {
    final all = loadList('vehicle_entries');
    for (final x in all.where((x) => x['vid'] == v['id'])) {
      await cancelReminder(x);
    }
    setState(() => items.remove(v));
    await saveList('vehicles', items);
    all.removeWhere((x) => x['vid'] == v['id']);
    await saveList('vehicle_entries', all);
  }

  @override
  Widget build(BuildContext context) {
    final up = upcoming();
    return Scaffold(
      appBar: heroBar('Araçlarım', const [_vehC1, _vehC2]),
      floatingActionButton: FloatingActionButton(
          backgroundColor: _vehC1, foregroundColor: Colors.white, onPressed: add, child: const Icon(Icons.add)),
      body: items.isEmpty
          ? emptyState('Araç eklemek için + tuşuna basın.')
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 90),
              children: [
                deleteHint,
                if (up.isNotEmpty)
                  Card(
                    elevation: 0,
                    color: Colors.orange.withOpacity(0.15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Row(children: [
                          Icon(Icons.notifications_active, color: Colors.orange),
                          SizedBox(width: 8),
                          Text('Yaklaşan tarihler', style: TextStyle(fontWeight: FontWeight.bold)),
                        ]),
                        for (final u in up)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('${u['veh']}  •  ${u['title']}  •  ${dueText(u['days'] as int)}',
                                style: TextStyle(fontWeight: FontWeight.w600, color: dueColor(u['days'] as int))),
                          ),
                      ]),
                    ),
                  ),
                for (final v in items)
                  Tile(
                    color: _vehC1,
                    leading: const Icon(Icons.local_shipping),
                    title: Text(v['name']),
                    subtitle: Text(v['plate'] ?? ''),
                    onLongPress: () => actions(v),
                    onTap: () async {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => VehicleDetail(v)));
                      setState(() {});
                    },
                  ),
              ],
            ),
    );
  }
}

class VehicleDetail extends StatefulWidget {
  final Rec v;
  const VehicleDetail(this.v, {super.key});
  @override
  State<VehicleDetail> createState() => _VehicleDetailState();
}

class _VehicleDetailState extends State<VehicleDetail> with SingleTickerProviderStateMixin {
  late TabController tc;
  List<Rec> all = loadList('vehicle_entries');
  static const taxTypes = ['Kasko', 'Trafik Sigortası', 'MTV', 'Muayene'];

  @override
  void initState() {
    super.initState();
    tc = TabController(length: 2, vsync: this);
    tc.addListener(() {
      if (!tc.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    tc.dispose();
    super.dispose();
  }

  void snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> persist() => saveList('vehicle_entries', all);

  List<Rec> of(String kind) {
    final l = all.where((e) => e['vid'] == widget.v['id'] && e['kind'] == kind).toList();
    if (kind == 'tax') {
      l.sort((a, b) => parseDate(a['date']).compareTo(parseDate(b['date'])));
    } else {
      l.sort((a, b) => parseDate(b['date']).compareTo(parseDate(a['date'])));
    }
    return l;
  }

  Future<void> add() async {
    if (tc.index == 0) {
      final r = await inputDialog(context, 'Vergi / sigorta ekle', [
        const F('title', 'Tür (seçin ya da yazın)', options: taxTypes),
        const F('date', 'Tarih', date: true),
      ]);
      if (r == null) return;
      if (r['title']!.isEmpty || r['date']!.isEmpty) {
        snack('Tür ve tarih girmelisiniz.');
        return;
      }
      final plate = '${widget.v['plate'] ?? ''}'.trim();
      final label = plate.isEmpty ? '${widget.v['name']}' : plate;
      final at = parseAt(r['date']!, '09:00');
      final rec = <String, dynamic>{
        'id': newId(),
        'nid': newNid(),
        'vid': widget.v['id'],
        'kind': 'tax',
        'title': r['title'],
        'date': r['date'],
        'at': at?.toIso8601String(),
        'ntitle': 'Araç hatırlatması',
        'body': '$label  •  ${r['title']}',
      };
      setState(() => all.add(rec));
      await persist();
      await scheduleReminder(rec);
    } else {
      final r = await inputDialog(context, 'Bakım kaydı aç', [
        F('date', 'Tarih', date: true, init: fmtDate(DateTime.now())),
        const F('km', 'Kilometre', number: true),
      ]);
      if (r == null || r['date']!.isEmpty) return;
      final rec = <String, dynamic>{
        'id': newId(),
        'vid': widget.v['id'],
        'kind': 'service',
        'items': <Rec>[],
        ...r
      };
      setState(() => all.add(rec));
      await persist();
      await addItem(rec);
    }
  }

  Future<void> addItem(Rec rec) async {
    final r = await inputDialog(context, 'Yapılan iş ekle', [
      const F('name', 'Yapılan iş'),
      const F('price', 'Tutar (₺) - isteğe bağlı', number: true),
    ]);
    if (r == null || r['name']!.isEmpty) return;
    setState(() => (rec['items'] as List).add({'name': r['name'], 'price': r['price']}));
    await persist();
  }

  Future<void> itemActions(Rec rec, int i) async {
    final it = (rec['items'] as List)[i] as Map;
    final a = await actionSheet(context, '${it['name']}');
    if (a == 'edit') {
      final r = await inputDialog(context, 'Yapılan işi düzenle', [
        F('name', 'Yapılan iş', init: '${it['name'] ?? ''}'),
        F('price', 'Tutar (₺) - isteğe bağlı', number: true, init: '${it['price'] ?? ''}'),
      ]);
      if (r == null || r['name']!.isEmpty) return;
      setState(() {
        it['name'] = r['name'];
        it['price'] = r['price'];
      });
      await persist();
    } else if (a == 'delete') {
      setState(() => (rec['items'] as List).removeAt(i));
      await persist();
    }
  }

  Future<void> removeEntry(Rec e) async {
    final label = e['kind'] == 'service' ? 'Bakım kaydı  ${e['date']}' : '${e['title']}';
    final a = await actionSheet(context, label);
    if (a == 'edit') {
      await editEntry(e);
    } else if (a == 'delete') {
      if (e['kind'] == 'tax') await cancelReminder(e);
      setState(() => all.removeWhere((x) => x['id'] == e['id']));
      await persist();
    }
  }

  Future<void> editEntry(Rec e) async {
    if (e['kind'] == 'tax') {
      final r = await inputDialog(context, 'Vergi / sigorta düzenle', [
        F('title', 'Tür (seçin ya da yazın)', options: taxTypes, init: '${e['title'] ?? ''}'),
        F('date', 'Tarih', date: true, init: '${e['date'] ?? ''}'),
      ]);
      if (r == null) return;
      if (r['title']!.isEmpty || r['date']!.isEmpty) {
        snack('Tür ve tarih girmelisiniz.');
        return;
      }
      await cancelReminder(e);
      final plate = '${widget.v['plate'] ?? ''}'.trim();
      final label = plate.isEmpty ? '${widget.v['name']}' : plate;
      setState(() {
        e['title'] = r['title'];
        e['date'] = r['date'];
        e['at'] = parseAt(r['date']!, '09:00')?.toIso8601String();
        e['body'] = '$label  •  ${r['title']}';
      });
      await persist();
      await scheduleReminder(e);
    } else {
      final r = await inputDialog(context, 'Bakım kaydını düzenle', [
        F('date', 'Tarih', date: true, init: '${e['date'] ?? ''}'),
        F('km', 'Kilometre', number: true, init: '${e['km'] ?? ''}'),
      ]);
      if (r == null || r['date']!.isEmpty) return;
      setState(() {
        e['date'] = r['date'];
        e['km'] = r['km'];
      });
      await persist();
    }
  }

  Widget taxList() {
    final l = of('tax');
    if (l.isEmpty) {
      return emptyState('Kasko, sigorta, MTV, muayene tarihlerini eklemek için + tuşuna basın. Günü gelince bildirim gelir.');
    }
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 90),
      children: [
        deleteHint,
        for (final e in l)
          Tile(
            color: _vehC1,
            leading: const Icon(Icons.event),
            title: Text('${e['title']}'),
            subtitle: Builder(builder: (_) {
              final d = daysLeft(e['date']);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${e['date']}'),
                Text(dueText(d), style: TextStyle(fontWeight: FontWeight.w600, color: dueColor(d))),
              ]);
            }),
            onLongPress: () => removeEntry(e),
          ),
      ],
    );
  }

  Widget serviceCard(Rec rec) {
    final its = (rec['items'] as List? ?? []).map((x) => Rec.from(x as Map)).toList();
    final total = its.fold<double>(0, (s, x) => s + toNum(x['price']));
    return GestureDetector(
      onLongPress: () => removeEntry(rec),
      child: Card(
        elevation: 0,
        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF181C24) : Colors.white,
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.fromLTRB(16, 5, 16, 5),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: _vehC1.withOpacity(0.3))),
        child: ExpansionTile(
          key: PageStorageKey(rec['id']),
          initiallyExpanded: true,
          shape: const Border(),
          collapsedShape: const Border(),
          leading: const Icon(Icons.build_circle, color: _vehC1, size: 32),
          title: Text('${rec['date']}  •  ${rec['km'] ?? ''} km', style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${its.length} kalem${total > 0 ? '  •  ${money(total)}' : ''}'),
          children: [
            for (var i = 0; i < its.length; i++)
              ListTile(
                dense: true,
                leading: Text('${i + 1}.'),
                title: Text('${its[i]['name'] ?? ''}'),
                trailing: toNum(its[i]['price']) > 0 ? Text(money(toNum(its[i]['price']))) : null,
                onLongPress: () => itemActions(rec, i),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(children: [
                TextButton.icon(onPressed: () => addItem(rec), icon: const Icon(Icons.add), label: const Text('Ekle')),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget serviceList() {
    final l = of('service');
    if (l.isEmpty) {
      return emptyState('Bakım kaydı açmak için + tuşuna basın. Sonra yapılan işleri ekleyin.');
    }
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 90),
      children: [deleteHint, for (final rec in l) serviceCard(rec)],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: heroBar(
          '${widget.v['name']} ${widget.v['plate'] ?? ''}',
          const [_vehC1, _vehC2],
          bottom: TabBar(
            controller: tc,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            dividerColor: Colors.transparent,
            tabs: const [Tab(text: 'Vergi / Sigorta'), Tab(text: 'Bakım')],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: _vehC1,
          foregroundColor: Colors.white,
          onPressed: add,
          icon: const Icon(Icons.add),
          label: Text(tc.index == 0 ? 'Tarih ekle' : 'Bakım kaydı'),
        ),
        body: TabBarView(controller: tc, children: [taxList(), serviceList()]),
      );
}

// ---------- 2) ÖDEMELER ----------
const _payC1 = Color(0xFF0CA678);
const _payC2 = Color(0xFF51CF66);

class PaymentsPage extends StatefulWidget {
  const PaymentsPage({super.key});
  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage> {
  List<Rec> items = loadList('payments');

  void snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> add() async {
    final r = await inputDialog(context, 'Ödeme ekle', [
      const F('name', 'Ödeme adı (Kira, Fatura...)'),
      const F('date', 'Tarih', date: true),
    ]);
    if (r == null) return;
    if (r['name']!.isEmpty || r['date']!.isEmpty) {
      snack('Ödeme adı ve tarih girmelisiniz.');
      return;
    }
    final at = parseAt(r['date']!, '09:00');
    final rec = <String, dynamic>{
      'id': newId(),
      'nid': newNid(),
      'name': r['name'],
      'title': r['name'],
      'date': r['date'],
      'at': at?.toIso8601String(),
      'ntitle': 'Ödeme günü',
      'body': '${r['name']}',
    };
    setState(() => items.add(rec));
    await saveList('payments', items);
    await scheduleReminder(rec);
  }

  Future<void> remove(Rec e) async {
    final a = await actionSheet(context, '${e['name']}');
    if (a == 'edit') {
      final r = await inputDialog(context, 'Ödemeyi düzenle', [
        F('name', 'Ödeme adı', init: '${e['name'] ?? ''}'),
        F('date', 'Tarih', date: true, init: '${e['date'] ?? ''}'),
      ]);
      if (r == null) return;
      if (r['name']!.isEmpty || r['date']!.isEmpty) {
        snack('Ödeme adı ve tarih girmelisiniz.');
        return;
      }
      await cancelReminder(e);
      setState(() {
        e['name'] = r['name'];
        e['title'] = r['name'];
        e['body'] = r['name'];
        e['date'] = r['date'];
        e['at'] = parseAt(r['date']!, '09:00')?.toIso8601String();
      });
      await saveList('payments', items);
      await scheduleReminder(e);
    } else if (a == 'delete') {
      await cancelReminder(e);
      setState(() => items.remove(e));
      await saveList('payments', items);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...items]..sort((a, b) => parseDate(a['date']).compareTo(parseDate(b['date'])));
    return Scaffold(
      appBar: heroBar('Ödemeler', const [_payC1, _payC2]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _payC1,
        foregroundColor: Colors.white,
        onPressed: add,
        icon: const Icon(Icons.add),
        label: const Text('Ödeme ekle'),
      ),
      body: items.isEmpty
          ? emptyState('Ödeme eklemek için + tuşuna basın. Seçtiğiniz günün sabahı bildirim gelir.')
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 90),
              children: [
                deleteHint,
                for (final e in sorted)
                  Tile(
                    color: _payC1,
                    leading: const Icon(Icons.payments),
                    title: Text('${e['name']}'),
                    subtitle: Builder(builder: (_) {
                      final d = daysLeft(e['date']);
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${e['date']}'),
                        Text(dueText(d), style: TextStyle(fontWeight: FontWeight.w600, color: dueColor(d))),
                      ]);
                    }),
                    onLongPress: () => remove(e),
                  ),
              ],
            ),
    );
  }
}

// ---------- 3) HATIRLATMALAR ----------
const _remC1 = Color(0xFFD6336C);
const _remC2 = Color(0xFFFF922B);

String remainText(DateTime at) {
  final m = at.difference(DateTime.now()).inMinutes;
  if (m < 0) return 'Zamanı geçti';
  if (m < 60) return '$m dk sonra';
  if (m < 1440) return '${(m / 60).round()} saat sonra';
  return '${(m / 1440).round()} gün sonra';
}

class RemindersPage extends StatefulWidget {
  const RemindersPage({super.key});
  @override
  State<RemindersPage> createState() => _RemindersPageState();
}

class _RemindersPageState extends State<RemindersPage> {
  List<Rec> items = loadList('reminders');

  void snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> add() async {
    final r = await inputDialog(context, 'Hatırlatma ekle', [
      const F('title', 'Ne hatırlatılsın?'),
      F('date', 'Tarih', date: true, init: fmtDate(DateTime.now())),
      const F('time', 'Saat', time: true),
    ]);
    if (r == null) return;
    final at = parseAt(r['date']!, r['time']!);
    if (r['title']!.isEmpty || at == null) {
      snack('Başlık, tarih ve saat girmelisiniz.');
      return;
    }
    final rec = <String, dynamic>{
      'id': newId(),
      'nid': DateTime.now().millisecondsSinceEpoch % 2000000000,
      'title': r['title'],
      'at': at.toIso8601String(),
      'done': false,
    };
    setState(() => items.add(rec));
    await saveList('reminders', items);
    await scheduleReminder(rec);
    if (at.isBefore(DateTime.now())) snack('Seçilen zaman geçmiş, bildirim gelmeyecek.');
  }

  Future<void> toggle(Rec e, bool v) async {
    setState(() => e['done'] = v);
    await saveList('reminders', items);
    if (v) {
      await cancelReminder(e);
    } else {
      await scheduleReminder(e);
    }
  }

  Future<void> remove(Rec e) async {
    if (!await confirmDelete(context)) return;
    await cancelReminder(e);
    setState(() => items.remove(e));
    await saveList('reminders', items);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...items];
    sorted.sort((a, b) {
      final da = a['done'] == true ? 1 : 0, db = b['done'] == true ? 1 : 0;
      if (da != db) return da.compareTo(db);
      return DateTime.parse(a['at']).compareTo(DateTime.parse(b['at']));
    });
    return Scaffold(
      appBar: heroBar('Hatırlatmalar', const [_remC1, _remC2]),
      floatingActionButton: FloatingActionButton(
          backgroundColor: _remC1, foregroundColor: Colors.white, onPressed: add, child: const Icon(Icons.add)),
      body: items.isEmpty
          ? emptyState('Hatırlatma eklemek için + tuşuna basın. Seçtiğiniz tarih ve saatte telefonunuza bildirim gelir.')
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 90),
              children: [
                for (final e in sorted)
                  CTile(
                    color: _remC1,
                    value: e['done'] == true,
                    onChanged: (v) => toggle(e, v ?? false),
                    title: Text('${e['title']}',
                        style: TextStyle(decoration: e['done'] == true ? TextDecoration.lineThrough : null)),
                    subtitle: Builder(builder: (_) {
                      final at = DateTime.parse(e['at']);
                      final done = e['done'] == true;
                      final late = !done && at.isBefore(DateTime.now());
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${fmtDate(at)}  •  ${two(at.hour)}:${two(at.minute)}'),
                        Text(done ? 'Tamamlandı ✓' : remainText(at),
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: done ? Colors.green.shade700 : (late ? Colors.red : _remC1))),
                      ]);
                    }),
                    secondary: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => remove(e)),
                  ),
              ],
            ),
    );
  }
}

// ---------- 4) GÜNLÜK İŞLER ----------
const _taskC1 = Color(0xFF4263EB);
const _taskC2 = Color(0xFF7950F2);
const _dayNames = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];

List<Rec> loadRecurring() {
  final l = prefs.getString('recurring') == null ? <Rec>[] : loadList('recurring');
  var changed = false;
  if (prefs.getInt('rec_seed') != 2) {
    final seeds = <Rec>[
      {'title': 'Birsen’i kursa götür', 'days': [1, 2], 'time': '14:00'},
      {'title': 'Birsen’i okuldan al', 'days': [1, 2, 3, 4, 5], 'time': '12:40'},
      {'title': 'Mete’yi kreşten al', 'days': [1, 2, 3, 4, 5], 'time': '16:30'},
    ];
    for (final sd in seeds) {
      if (!l.any((r) => r['title'] == sd['title'])) {
        l.add({'id': newId(), ...sd, 'doneDates': <String>[]});
      }
    }
    prefs.setInt('rec_seed', 2);
    changed = true;
  }
  var k = DateTime.now().millisecondsSinceEpoch % 100000000;
  for (final r in l) {
    if (r['nid'] == null) {
      r['nid'] = k++;
      changed = true;
    }
  }
  if (changed) saveList('recurring', l);
  return l;
}

String recSub(Rec r) {
  final t = '${r['time'] ?? ''}';
  final days = (r['days'] as List).map((d) => _dayNames[(d as int) - 1]).join(', ');
  final dl = r['days'] as List;
  final weekdays = dl.join(',') == '1,2,3,4,5';
  final txt = weekdays ? 'Hafta içi her gün' : (dl.length == 7 ? 'Her gün' : 'Her hafta $days');
  return '${t.isEmpty ? '' : '$t  •  '}$txt';
}

class _TaskRow {
  final String time, title, sub;
  final bool isRec;
  final Rec data;
  const _TaskRow(this.time, this.title, this.sub, this.isRec, this.data);
}

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  List<Rec> items = loadList('tasks');
  List<Rec> rec = loadRecurring();
  DateTime day = DateTime.now();

  List<Rec> get todays => items.where((e) => e['date'] == fmtDate(day)).toList();
  List<Rec> get todaysRec => rec.where((r) => (r['days'] as List).contains(day.weekday)).toList();

  void snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> add() async {
    final c = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Ne eklemek istersiniz?'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 1), child: const Text('Bu güne bir iş')),
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 2), child: const Text('Her hafta tekrarlayan iş')),
        ],
      ),
    );
    if (c == 1) {
      await addOnce();
    } else if (c == 2) {
      await addRecurring();
    }
  }

  Future<void> addOnce() async {
    final r = await inputDialog(context, 'İş ekle', [
      const F('title', 'Yapılacak iş'),
      const F('time', 'Saat (isteğe bağlı)', time: true),
    ]);
    if (r == null || r['title']!.isEmpty) return;
    final time = r['time']!;
    final at = parseAt(fmtDate(day), time.isEmpty ? '09:00' : time);
    final nr = <String, dynamic>{
      'id': newId(),
      'nid': newNid(),
      'title': r['title'],
      'date': fmtDate(day),
      'time': time,
      'at': at?.toIso8601String(),
      'ntitle': 'Günlük iş',
    };
    setState(() => items.add(nr));
    await saveList('tasks', items);
    await scheduleReminder(nr);
  }

  Future<void> addRecurring([Rec? ex]) async {
    final title = TextEditingController(text: ex == null ? '' : '${ex['title']}');
    final time = TextEditingController(text: ex == null ? '' : '${ex['time'] ?? ''}');
    final days = <int>{if (ex != null) ...(ex['days'] as List).map((d) => d as int)};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Tekrarlayan iş'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Yapılacak iş', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 14),
                const Text('Hangi günler?'),
                Wrap(spacing: 6, children: [
                  for (var i = 0; i < 7; i++)
                    FilterChip(
                      label: Text(_dayNames[i]),
                      selected: days.contains(i + 1),
                      onSelected: (v) => setS(() {
                        if (v) {
                          days.add(i + 1);
                        } else {
                          days.remove(i + 1);
                        }
                      }),
                    ),
                ]),
                const SizedBox(height: 14),
                TextField(
                  controller: time,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'Saat (isteğe bağlı)',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.access_time),
                  ),
                  onTap: () async {
                    final tm = await showTimePicker(
                        context: ctx, initialTime: const TimeOfDay(hour: 14, minute: 0));
                    if (tm != null) time.text = '${two(tm.hour)}:${two(tm.minute)}';
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (title.text.trim().isEmpty || days.isEmpty) {
      snack('İş adı yazın ve en az bir gün seçin.');
      return;
    }
    final d = days.toList()..sort();
    if (ex != null) {
      await cancelRecurring(ex);
      setState(() {
        ex['title'] = title.text.trim();
        ex['days'] = d;
        ex['time'] = time.text.trim();
      });
      await saveList('recurring', rec);
      await scheduleRecurring(ex);
      return;
    }
    final nr = <String, dynamic>{
      'id': newId(),
      'nid': DateTime.now().millisecondsSinceEpoch % 100000000,
      'title': title.text.trim(),
      'days': d,
      'time': time.text.trim(),
      'doneDates': <String>[],
    };
    setState(() => rec.add(nr));
    await saveList('recurring', rec);
    await scheduleRecurring(nr);
  }

  Future<void> removeOnce(Rec e) async {
    final a = await actionSheet(context, '${e['title']}');
    if (a == 'edit') {
      final r = await inputDialog(context, 'İşi düzenle', [
        F('title', 'Yapılacak iş', init: '${e['title'] ?? ''}'),
        F('time', 'Saat (isteğe bağlı)', time: true, init: '${e['time'] ?? ''}'),
      ]);
      if (r == null || r['title']!.isEmpty) return;
      await cancelReminder(e);
      final time = r['time']!;
      setState(() {
        e['title'] = r['title'];
        e['time'] = time;
        e['at'] = parseAt('${e['date']}', time.isEmpty ? '09:00' : time)?.toIso8601String();
      });
      await saveList('tasks', items);
      await scheduleReminder(e);
    } else if (a == 'delete') {
      await cancelReminder(e);
      setState(() => items.remove(e));
      await saveList('tasks', items);
    }
  }

  Future<void> removeRec(Rec r) async {
    final a = await actionSheet(context, '${r['title']}  (tekrarlayan iş)');
    if (a == 'edit') {
      await addRecurring(r);
    } else if (a == 'delete') {
      await cancelRecurring(r);
      setState(() => rec.remove(r));
      await saveList('recurring', rec);
    }
  }

  Future<void> pick() async {
    final d = await showDatePicker(
        context: context, initialDate: day, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (d != null) setState(() => day = d);
  }

  @override
  Widget build(BuildContext context) {
    final rows = <_TaskRow>[
      for (final r in todaysRec) _TaskRow('${r['time'] ?? ''}', '${r['title']}', recSub(r), true, r),
      for (final e in todays) _TaskRow('${e['time'] ?? ''}', '${e['title']}', '${e['time'] ?? ''}', false, e),
    ];
    rows.sort((a, b) => (a.time.isEmpty ? '99:99' : a.time).compareTo(b.time.isEmpty ? '99:99' : b.time));
    final isToday = fmtDate(day) == fmtDate(DateTime.now());
    return Scaffold(
      appBar: heroBar('Günlük İşler', const [_taskC1, _taskC2]),
      floatingActionButton: FloatingActionButton(
          backgroundColor: _taskC1, foregroundColor: Colors.white, onPressed: add, child: const Icon(Icons.add)),
      body: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(() => day = day.subtract(const Duration(days: 1)))),
          TextButton(
              onPressed: pick,
              child: Text(isToday ? 'Bugün  (${fmtDate(day)})' : fmtDate(day), style: const TextStyle(fontSize: 16))),
          IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(() => day = day.add(const Duration(days: 1)))),
        ]),
        Expanded(
          child: rows.isEmpty
              ? emptyState('Bu gün için iş yok. + tuşu ile ekleyin.')
              : ListView(padding: const EdgeInsets.only(top: 4, bottom: 90), children: [
                  deleteHint,
                  for (final x in rows)
                    Tile(
                      color: _taskC1,
                      leading: Icon(x.isRec ? Icons.repeat : Icons.task_alt),
                      title: Text(x.title),
                      subtitle: x.sub.isEmpty ? null : Text(x.sub),
                      onLongPress: () {
                        if (x.isRec) {
                          removeRec(x.data);
                        } else {
                          removeOnce(x.data);
                        }
                      },
                    ),
                ]),
        ),
      ]),
    );
  }
}

// ---------- 5) VARDİYA ----------
const _shC1 = Color(0xFF7048E8);
const _shC2 = Color(0xFFDA77F2);
const _monthNames = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
const _weekNames = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];

// Döngü (4 gün): 0 = herkes izinli, 1 = Murat gündüz, 2 = Murat gece + Raziye gündüz, 3 = Raziye gece
const Map<String, List<Object>> _hol = {
  '2027-01-01': ['Yılbaşı', 8],
  '2027-03-08': ['Ramazan Bayramı arifesi (yarım gün)', 4],
  '2027-03-09': ['Ramazan Bayramı', 8],
  '2027-03-10': ['Ramazan Bayramı', 8],
  '2027-03-11': ['Ramazan Bayramı', 8],
  '2027-04-23': ['Ulusal Egemenlik ve Çocuk Bayramı', 8],
  '2027-05-01': ['Emek ve Dayanışma Günü', 8],
  '2027-05-15': ['Kurban Bayramı arifesi (yarım gün)', 4],
  '2027-05-16': ['Kurban Bayramı', 8],
  '2027-05-17': ['Kurban Bayramı', 8],
  '2027-05-18': ['Kurban Bayramı', 8],
  '2027-05-19': ['Kurban Bayramı / 19 Mayıs', 8],
  '2027-07-15': ['Demokrasi ve Milli Birlik Günü', 8],
  '2027-08-30': ['Zafer Bayramı', 8],
  '2027-10-28': ['Cumhuriyet Bayramı arifesi (yarım gün)', 4],
  '2027-10-29': ['Cumhuriyet Bayramı', 8],
};

String holKey(int y, int m, int d) => '$y-${two(m)}-${two(d)}';

DateTime shiftAnchor() => parseDate(prefs.getString('shift_anchor') ?? '01.11.2026');

int cyclePos(DateTime d, DateTime a) {
  final diff = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
  return ((diff % 4) + 4) % 4;
}

class ShiftStat {
  final int murat, raziye, mesai;
  const ShiftStat(this.murat, this.raziye, this.mesai);
}

ShiftStat monthStat(int y, int m, DateTime a) {
  final n = DateTime(y, m + 1, 0).day;
  var mu = 0, ra = 0, wd = 0;
  for (var d = 1; d <= n; d++) {
    final p = cyclePos(DateTime(y, m, d), a);
    if (p == 1 || p == 2) mu++;
    if (p == 2 || p == 3) ra++;
    if (DateTime(y, m, d).weekday <= 5) {
      final h = _hol[holKey(y, m, d)];
      wd += 8 - (h == null ? 0 : h[1] as int);
    }
  }
  return ShiftStat(mu * 12, ra * 12, wd);
}

String sgn(int v) => v > 0 ? '+$v' : '$v';

class _C {
  final String text;
  final int flex;
  final Color? bg, fg;
  final bool bold;
  final bool left;
  const _C(this.text, this.flex, {this.bg, this.fg, this.bold = false, this.left = false});
}

Widget shLine(List<_C> cs, Color line, {VoidCallback? onTap}) {
  final row = Row(children: [
    for (final c in cs)
      Expanded(
        flex: c.flex,
        child: Container(
          alignment: c.left ? Alignment.centerLeft : Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
          decoration: BoxDecoration(color: c.bg, border: Border.all(color: line, width: 0.5)),
          child: Text(c.text,
              style: TextStyle(fontSize: 13, fontWeight: c.bold ? FontWeight.bold : FontWeight.normal, color: c.fg)),
        ),
      ),
  ]);
  return onTap == null ? row : InkWell(onTap: onTap, child: row);
}

class ShiftPage extends StatefulWidget {
  const ShiftPage({super.key});
  @override
  State<ShiftPage> createState() => _ShiftPageState();
}

class _ShiftPageState extends State<ShiftPage> {
  late int y, m;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    y = n.year < 2027 ? 2027 : n.year;
    m = n.year < 2027 ? 1 : n.month;
  }

  void move(int delta) {
    setState(() {
      m += delta;
      if (m < 1) {
        m = 12;
        y--;
      } else if (m > 12) {
        m = 1;
        y++;
      }
    });
  }

  Future<void> settings() async {
    final r = await inputDialog(context, 'Vardiya döngüsü', [
      F('a', 'Herkesin izinli olduğu gün (döngü başlangıcı)', date: true, init: fmtDate(shiftAnchor())),
    ]);
    if (r == null || r['a']!.isEmpty) return;
    await prefs.setString('shift_anchor', r['a']!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final a = shiftAnchor();
    final st = monthStat(y, m, a);
    final n = DateTime(y, m + 1, 0).day;
    final now = DateTime.now();
    final line = Theme.of(context).colorScheme.outlineVariant;
    const yellow = Color(0xFFFFEB3B);
    final red = Theme.of(context).colorScheme.primary;
    final todayBg = _shC1.withOpacity(0.2);
    final hols = <String>[];
    for (var d = 1; d <= n; d++) {
      final h = _hol[holKey(y, m, d)];
      if (h != null) hols.add('$d ${_monthNames[m - 1]} ${h[0]}');
    }

    var tm = 0, tr = 0, tx = 0;
    final yearRows = <Widget>[];
    for (var i = 1; i <= 12; i++) {
      final s = monthStat(y, i, a);
      tm += s.murat;
      tr += s.raziye;
      tx += s.mesai;
      yearRows.add(shLine([
        _C(_monthNames[i - 1], 3, left: true),
        _C('${s.murat}', 2),
        _C('${s.raziye}', 2),
        _C('${s.mesai}', 2),
      ], line, onTap: () => setState(() => m = i)));
    }

    return Scaffold(
      appBar: heroBar('Vardiya', const [_shC1, _shC2]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => move(-1)),
            SizedBox(
              width: 160,
              child: Center(
                child: Text('${_monthNames[m - 1]} $y',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => move(1)),
            IconButton(icon: const Icon(Icons.settings), tooltip: 'Döngü ayarı', onPressed: settings),
          ]),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Text(
              'Döngü: izin → Murat gündüz → Murat gece + Raziye gündüz → Raziye gece',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          shLine([_C(_monthNames[m - 1].toUpperCase(), 4, bold: true, fg: red), _C('MURAT', 4, bold: true, fg: red), _C('RAZİYE', 4, bold: true, fg: red)], line),
          shLine([const _C('', 4), const _C('GÜNDÜZ', 2, bold: true), const _C('GECE', 2, bold: true), const _C('GÜNDÜZ', 2, bold: true), const _C('GECE', 2, bold: true)], line),
          for (var d = 1; d <= n; d++)
            Builder(builder: (_) {
              final date = DateTime(y, m, d);
              final p = cyclePos(date, a);
              final off = p == 0;
              final isToday = now.year == y && now.month == m && now.day == d;
              final dayBg = isToday ? todayBg : null;
              Color? c(bool on) => off ? yellow : (isToday ? todayBg : null);
              return shLine([
                _C('$d', 1, bold: isToday, bg: dayBg),
                _C('${_weekNames[date.weekday - 1]}${_hol[holKey(y, m, d)] != null ? ' ★' : ''}', 3, left: true, bold: isToday, bg: dayBg),
                _C(p == 1 ? '12' : '', 2, bg: c(p == 1), fg: off ? Colors.black : null),
                _C(p == 2 ? '12' : '', 2, bg: c(p == 2), fg: off ? Colors.black : null),
                _C(p == 2 ? '12' : '', 2, bg: c(p == 2), fg: off ? Colors.black : null),
                _C(p == 3 ? '12' : '', 2, bg: c(p == 3), fg: off ? Colors.black : null),
              ], line);
            }),
          shLine([_C('Toplam', 4, bold: true, fg: red), _C('${st.murat}', 4, bold: true), _C('${st.raziye}', 4, bold: true)], line),
          shLine([_C('Mesai ${st.mesai}', 4, bold: true, fg: red), _C(sgn(st.murat - st.mesai), 4, bold: true), _C(sgn(st.raziye - st.mesai), 4, bold: true)], line),
          if (hols.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text('★ Resmî tatil: ${hols.join(' • ')} (hafta içine denk gelenler mesaiden düşüldü)',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          const SizedBox(height: 20),
          Text('$y yıllık özet (saat)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Ayı açmak için satıra dokunun  •  Mesai: hafta içi × 8 saat, resmî tatil ve arifeler düşüldü', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          shLine([_C('Ay', 3, bold: true, fg: red), _C('Murat', 2, bold: true, fg: red), _C('Raziye', 2, bold: true, fg: red), _C('Mesai', 2, bold: true, fg: red)], line),
          ...yearRows,
          shLine([const _C('Yıl', 3, bold: true), _C('$tm', 2, bold: true), _C('$tr', 2, bold: true), _C('$tx', 2, bold: true)], line),
        ],
      ),
    );
  }
}

// ---------- 6) YEDEK ----------
const _bkC = Color(0xFF364FC7);
const _bkKeys = ['vehicles', 'vehicle_entries', 'payments', 'tasks', 'reminders', 'recurring'];

Map<String, dynamic> buildBackup() {
  final data = <String, dynamic>{};
  for (final k in _bkKeys) {
    data[k] = loadList(k);
  }
  data['shift_anchor'] = prefs.getString('shift_anchor');
  data['rec_seed'] = prefs.getInt('rec_seed');
  return {
    'app': 'kisisel_takip',
    'version': 1,
    'exported': DateTime.now().toIso8601String(),
    'data': data,
  };
}

String backupSummary(Map<String, dynamic> d) {
  int n(String k) => (d[k] as List? ?? []).length;
  return '${n('vehicles')} araç, ${n('vehicle_entries')} araç kaydı, ${n('payments')} ödeme, '
      '${n('reminders')} hatırlatma, ${n('tasks')} günlük iş, ${n('recurring')} tekrarlayan iş';
}

Map<String, dynamic>? parseBackup(String text) {
  try {
    final j = jsonDecode(text.trim());
    if (j is! Map || j['app'] != 'kisisel_takip' || j['data'] is! Map) return null;
    final d = Map<String, dynamic>.from(j['data'] as Map);
    for (final k in _bkKeys) {
      if (d[k] != null && d[k] is! List) return null;
    }
    return d;
  } catch (_) {
    return null;
  }
}

const _seedBackup = r'''{"app":"kisisel_takip","version":1,"exported":"2026-11-27T19:00:10.805838","data":{"vehicles":[{"id":"1795507850994437","name":"POLO","plate":"45 FJ 432"},{"id":"1795507935154275","name":"PALİO","plate":"35 CUG 870"},{"id":"1795524455183200","name":"EV","plate":""},{"id":"1795537609546714","name":"KUBA","plate":"45 AYN 702"}],"vehicle_entries":[{"id":"1795507889646560","nid":1689646581,"vid":"1795507850994437","kind":"tax","title":"MTV","date":"01.01.2027","at":"2027-01-01T09:00:00.000","ntitle":"Araç hatırlatması","body":"45 FJ 432  •  MTV"},{"id":"1795518516209719","nid":1516209732,"vid":"1795507850994437","kind":"tax","title":"Muayene","date":"19.06.2028","at":"2028-06-19T09:00:00.000","ntitle":"Araç hatırlatması","body":"45 FJ 432  •  Muayene"},{"id":"1795518563600550","vid":"1795507850994437","kind":"service","items":[{"name":"buji","price":""},{"name":"ön fren balata","price":""}],"date":"24.11.2022","km":"60000"},{"id":"1795518606066708","vid":"1795507850994437","kind":"service","items":[{"name":"Devir Daim","price":""},{"name":"arka fren balata","price":""}],"date":"21.12.2022","km":"75000"},{"id":"1795518673509057","vid":"1795507850994437","kind":"service","items":[{"name":"Triger","price":""}],"date":"24.11.2023","km":"87000"},{"id":"1795518739042091","vid":"1795507850994437","kind":"service","items":[{"name":"Şanzıman yağı","price":""},{"name":"Hidrolik yağı","price":""}],"date":"24.11.2024","km":"102000"},{"id":"1795518940421244","vid":"1795507850994437","kind":"service","items":[{"name":"buji","price":""},{"name":"ön fren balata","price":""}],"date":"24.04.2025","km":"115000"},{"id":"1795518989637582","vid":"1795507850994437","kind":"service","items":[{"name":"baskı balata","price":""},{"name":"V kayışı","price":""}],"date":"24.11.2025","km":"122000"},{"id":"1795519168886968","vid":"1795507850994437","kind":"service","items":[{"name":"Bakım","price":""}],"date":"24.05.2026","km":"135000"},{"id":"1795519198603389","vid":"1795507850994437","kind":"service","items":[{"name":"bakım","price":""}],"date":"04.11.2026","km":"143000"},{"id":"1795519230551839","vid":"1795507850994437","kind":"service","items":[{"name":"akü 22.07.2026","price":""},{"name":"lastik 25.06.2025","price":""}],"date":"24.11.2021","km":"000000"},{"id":"1795519329892400","vid":"1795507850994437","kind":"service","items":[{"name":"arka fren balata","price":""},{"name":"motor temizleme","price":""}],"date":"12.12.2025","km":"125000"},{"id":"1795524476536031","nid":1176536044,"vid":"1795524455183200","kind":"tax","title":"Vergi","date":"01.01.2027","at":"2027-01-01T09:00:00.000","ntitle":"Araç hatırlatması","body":"EV  •  Vergi"},{"id":"1795524498254125","nid":1198254141,"vid":"1795524455183200","kind":"tax","title":"Vergi","date":"01.07.2027","at":"2027-07-01T09:00:00.000","ntitle":"Araç hatırlatması","body":"EV  •  Vergi"},{"id":"1795526503228679","nid":1403228685,"vid":"1795507850994437","kind":"tax","title":"Kasko","date":"05.12.2027","at":"2027-12-05T09:00:00.000","ntitle":"Araç hatırlatması","body":"45 FJ 432  •  Kasko"},{"id":"1795526526891980","nid":1426891993,"vid":"1795507850994437","kind":"tax","title":"Trafik Sigortası","date":"05.12.2027","at":"2027-12-05T09:00:00.000","ntitle":"Araç hatırlatması","body":"45 FJ 432  •  Trafik Sigortası"},{"id":"1795526545995576","nid":1445995588,"vid":"1795507850994437","kind":"tax","title":"MTV","date":"01.07.2027","at":"2027-07-01T09:00:00.000","ntitle":"Araç hatırlatması","body":"45 FJ 432  •  MTV"},{"id":"1795537241746780","vid":"1795507935154275","kind":"service","items":[{"name":"triger","price":""},{"name":"V kayışı","price":""},{"name":"su tankı","price":""},{"name":"devir daim","price":""},{"name":"motor takozu","price":""},{"name":"kapak contası","price":""},{"name":"arka fren balata","price":""},{"name":"bakım","price":""}],"date":"23.07.2026","km":"234000"},{"id":"1795537366844444","vid":"1795507935154275","kind":"service","items":[{"name":"yağ müşiri","price":""},{"name":"yağ filtresi","price":""},{"name":"yağ pompası","price":""}],"date":"28.08.2026","km":"235400"},{"id":"1795537501938614","nid":1601938628,"vid":"1795507935154275","kind":"tax","title":"Trafik Sigortası","date":"20.07.2027","at":"2027-07-20T09:00:00.000","ntitle":"Araç hatırlatması","body":"35 CUG 870  •  Trafik Sigortası"},{"id":"1795537515812341","nid":1615812349,"vid":"1795507935154275","kind":"tax","title":"MTV","date":"01.01.2027","at":"2027-01-01T09:00:00.000","ntitle":"Araç hatırlatması","body":"35 CUG 870  •  MTV"},{"id":"1795537525030247","nid":1625030260,"vid":"1795507935154275","kind":"tax","title":"MTV","date":"01.07.2027","at":"2027-07-01T09:00:00.000","ntitle":"Araç hatırlatması","body":"35 CUG 870  •  MTV"},{"id":"1795537557375237","nid":1657375243,"vid":"1795507935154275","kind":"tax","title":"Muayene","date":"09.06.2028","at":"2028-06-09T09:00:00.000","ntitle":"Araç hatırlatması","body":"35 CUG 870  •  Muayene"},{"id":"1795537637926500","nid":1737926508,"vid":"1795537609546714","kind":"tax","title":"Muayene","date":"23.12.2027","at":"2027-12-23T09:00:00.000","ntitle":"Araç hatırlatması","body":"45 AYN 702  •  Muayene"}],"payments":[{"id":"1795506922898335","nid":1622898348,"name":"Vakıfbank Kart","title":"Vakıfbank Kart","date":"15.01.2027","at":"2027-01-15T09:00:00.000","ntitle":"Ödeme günü","body":"Vakıfbank Kart"},{"id":"1795519415667126","nid":1515667139,"name":"Garanti Kart","title":"Garanti Kart","date":"27.03.2027","at":"2027-03-27T09:00:00.000","ntitle":"Ödeme günü","body":"Garanti Kart"},{"id":"1795519432387322","nid":1532387335,"name":"Halkbankası Kart","title":"Halkbankası Kart","date":"12.02.2027","at":"2027-02-12T09:00:00.000","ntitle":"Ödeme günü","body":"Halkbankası Kart"},{"id":"1795519443597913","nid":1543597924,"name":"Kreş","title":"Kreş","date":"12.02.2027","at":"2027-02-12T09:00:00.000","ntitle":"Ödeme günü","body":"Kreş"},{"id":"1795519458761806","nid":1558761819,"name":"Aidat","title":"Aidat","date":"13.02.2027","at":"2027-02-13T09:00:00.000","ntitle":"Ödeme günü","body":"Aidat"}],"tasks":[],"reminders":[{"id":"1795541946867909","nid":1541946867,"title":"Palio Akü-lastik-elfreni","at":"2027-01-30T18:39:00.000","done":false},{"id":"1795542236850340","nid":1542236850,"title":"Mete Kan tahlili","at":"2027-01-08T16:43:00.000","done":false},{"id":"1795770186729671","nid":1770186729,"title":"Palio su rengi seviyesi","at":"2027-03-20T15:03:00.000","done":false},{"id":"1795770226070235","nid":1770226070,"title":"Palio buji","at":"2027-02-20T15:03:00.000","done":false}],"recurring":[{"id":"1795506834801184","title":"Birsen’i okuldan al","days":[1,2,3,4,5],"time":"12:40","doneDates":[],"nid":6834802},{"id":"1795506834801185","title":"Mete’yi kreşten al","days":[1,2,3,4,5],"time":"16:30","doneDates":[],"nid":6834803},{"id":"1795508010093686","nid":8010093,"title":"Çocuklara vitamin ver.","days":[1,2,3,4,5,6,7],"time":"08:00","doneDates":[]},{"id":"1795518048872415","nid":18048872,"title":"Birseni kursa götür.","days":[1,2],"time":"13:15","doneDates":[]},{"id":"1795758071026544","nid":58071026,"title":"Birseni dicem götür.","days":[5],"time":"14:00","doneDates":[]}],"shift_anchor":null,"rec_seed":2}}''';

Future<void> writeBackupToPrefs(Map<String, dynamic> d) async {
  for (final k in _bkKeys) {
    if (d[k] is List) {
      await prefs.setString(k, jsonEncode(d[k]));
    } else {
      await prefs.remove(k);
    }
  }
  if (d['shift_anchor'] is String) {
    await prefs.setString('shift_anchor', d['shift_anchor'] as String);
  } else {
    await prefs.remove('shift_anchor');
  }
  if (d['rec_seed'] is int) {
    await prefs.setInt('rec_seed', d['rec_seed'] as int);
  } else {
    await prefs.remove('rec_seed');
  }
}

Future<void> applyBackup(Map<String, dynamic> d) async {
  try {
    await notifPlugin.cancelAll();
  } catch (_) {}
  await writeBackupToPrefs(d);
  try {
    await rescheduleAll();
  } catch (_) {}
  appEpoch.value++;
}

Widget bkCard(BuildContext c, IconData icon, String title, String text, String button, VoidCallback onTap,
    {String? foot}) {
  final dark = Theme.of(c).brightness == Brightness.dark;
  return Card(
    elevation: 0,
    color: dark ? const Color(0xFF181C24) : Colors.white,
    margin: const EdgeInsets.symmetric(vertical: 6),
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Theme.of(c).colorScheme.outlineVariant)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: _bkC),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 10),
        Text(text),
        if (foot != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(foot, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _bkC),
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(button),
          ),
        ),
      ]),
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  void snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> downloadBackup() async {
    final n = DateTime.now();
    final name = 'kisisel_takip_yedek_${n.year}-${two(n.month)}-${two(n.day)}.json';
    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(buildBackup())));
      final out = await FilePicker.saveFile(
        dialogTitle: 'Yedeği kaydet',
        fileName: name,
        bytes: bytes,
      );
      if (out == null) return;
      await prefs.setString('last_backup', '${fmtDate(n)} ${two(n.hour)}:${two(n.minute)}');
      setState(() {});
      snack('Yedek kaydedildi: $name');
    } catch (e) {
      snack('Yedek kaydedilemedi.');
    }
  }

  Future<void> restoreBackup() async {
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final d = parseBackup(utf8.decode(bytes));
      if (d == null) {
        snack('Seçilen dosya geçerli bir yedek değil.');
        return;
      }
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Veriler değiştirilsin mi?'),
          content: Text('Yedekte: ${backupSummary(d)}.\n\nŞu anki bütün verileriniz silinip bu yedekle değiştirilecek.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yedeği yükle')),
          ],
        ),
      );
      if (ok != true) return;
      final messenger = ScaffoldMessenger.of(context);
      await applyBackup(d);
      messenger.showSnackBar(const SnackBar(content: Text('Yedek yüklendi.')));
    } catch (e) {
      snack('Dosya okunamadı.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = backupSummary(Map<String, dynamic>.from(buildBackup()['data'] as Map));
    final last = prefs.getString('last_backup');
    return Scaffold(
      appBar: heroBar('Ayarlar', const [_bkC, Color(0xFF4DABF7)]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text('VERİ YEDEKLEME',
                style: TextStyle(color: Colors.grey, fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600)),
          ),
          bkCard(
            context,
            Icons.download,
            'Yedek indir',
            'Bütün verileriniz (araçlar, ödemeler, hatırlatmalar, günlük işler, vardiya ayarı) bir yedek dosyası olarak telefona indirilir. '
                'Dosyayı telefonda veya bulutta saklayın.',
            'Yedeği indir',
            downloadBackup,
            foot: 'Şu an kayıtlı: $cur\nSon yedek: ${last ?? 'henüz alınmadı'}',
          ),
          bkCard(
            context,
            Icons.upload_file,
            'Yedekten yükle',
            'Daha önce indirdiğiniz yedek dosyasını seçin. Telefon değiştirdiğinizde de aynı şekilde yükleyebilirsiniz.',
            'Yedek dosyası seç',
            restoreBackup,
            foot: 'Dikkat: yükleme, şu anki verilerin yerine geçer.',
          ),
        ],
      ),
    );
  }
}
