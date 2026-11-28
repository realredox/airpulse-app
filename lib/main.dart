import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const AirPulseApp());
}

class AirPulseApp extends StatelessWidget {
  const AirPulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirPulse',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00205B)),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      ),
      home: const MainHomeScreen(),
    );
  }
}

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> {
  static const String dbUrl =
      'https://storage.googleapis.com/airpulse-icn-data-2026/flight_db.json';

  int _tabIndex = 0;
  bool _loading = true;
  String _updatedAt = '-';
  List<Map<String, dynamic>> _allRecords = [];
  // 전체 운항 필터
  String _ioFilter = '전체';
  String _termFilter = '전체';
  String _searchKw = '';
  bool _includeCs = false;
  late DateTime _fromDate;
  late int _fromHour;
  late DateTime _toDate;
  late int _toHour;

  // MY JOB & 설정 상태
  String _jobTermFilter = '전체';
  List<String> _todoKeys = [];
  List<String> _doneKeys = [];
  String _fixedAirlines = '';
  bool _useFixedAirlines = true;
  Timer? _timer;
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _fixedAlCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _setDefault6Hours();
    _loadPrefs();
    _fetchData();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchData(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchCtrl.dispose();
    _fixedAlCtrl.dispose();
    super.dispose();
  }

  void _setDefault6Hours() {
    final now = DateTime.now();
    _fromDate = DateTime(now.year, now.month, now.day);
    _fromHour = now.hour;
    final end = now.add(const Duration(hours: 6));
    _toDate = DateTime(end.year, end.month, end.day);
    _toHour = end.hour;
  }
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _todoKeys = p.getStringList('todo_keys') ?? [];
      _doneKeys = p.getStringList('done_keys') ?? [];
      _fixedAirlines = p.getString('fixed_airlines') ?? '';
      _fixedAlCtrl.text = _fixedAirlines;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('todo_keys', _todoKeys);
    await p.setStringList('done_keys', _doneKeys);
    await p.setString('fixed_airlines', _fixedAirlines);
  }

  String _fmtHHMM(dynamic raw) {
    final s = (raw ?? '').toString().trim();
    return s.length >= 5 ? s.substring(0, 5) : (s.isEmpty ? '-' : s);
  }

  String _fmtDayMon(Map<String, dynamic> r) {
    final ymd = (r['일자코드'] ?? '').toString();
    if (ymd.length == 8) {
      const mons = ['', 'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
      final m = int.tryParse(ymd.substring(4, 6)) ?? 0;
      final d = ymd.substring(6, 8);
      if (m >= 1 && m <= 12) return '$d/${mons[m]}';
    }
    return (r['일자'] ?? '-').toString();
  }

  String _rowKey(Map<String, dynamic> r) {
    final ymd = (r['일자코드'] ?? '').toString();
    final dd = ymd.length >= 8 ? ymd.substring(6, 8) : '00';
    return '$dd:${(r['편명'] ?? '').toString().toUpperCase()}';
  }
  Future<void> _fetchData({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final res = await http.get(Uri.parse('$dbUrl?t=${DateTime.now().millisecondsSinceEpoch}'));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final List rawList = data['records'] ?? [];
        final parsed = rawList.map((e) => Map<String, dynamic>.from(e)).toList();
        parsed.sort((a, b) {
          final d = (a['일자코드'] ?? '').toString().compareTo((b['일자코드'] ?? '').toString());
          return d != 0 ? d : (a['STD/A'] ?? '99:99').toString().compareTo((b['STD/A'] ?? '99:99').toString());
        });
        setState(() {
          _allRecords = parsed;
          final parts = (data['updated_at'] ?? '-').toString().split(' ');
          _updatedAt = _fmtHHMM(parts.isNotEmpty ? parts.last : '-');
          _loading = false;
        });
      }
    } catch (_) {
      if (!silent) setState(() => _loading = false);
    }
  }

  Future<void> _importCsvFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (res == null || res.files.single.path == null) return;
    final rawText = await File(res.files.single.path!).readAsString();
    final lines = const LineSplitter().convert(rawText);
    if (lines.length < 2) return;

    final headers = lines.first.replaceAll('"', '').split(',').map((e) => e.trim()).toList();
    final dateIdx = headers.indexOf('일자');
    final fltIdx = headers.indexOf('편명');
    if (dateIdx < 0 || fltIdx < 0) return;

    int added = 0;
    setState(() {
      for (final line in lines.skip(1)) {
        final cols = line.split(',').map((e) => e.replaceAll('"', '').trim()).toList();
        if (cols.length <= fltIdx) continue;
        final dStr = cols[dateIdx];
        final flt = cols[fltIdx].toUpperCase();
        final dd = dStr.contains('/') ? dStr.split('/').last.padLeft(2, '0') : dStr.padLeft(2, '0');
        final key = '$dd:$flt';
        if (flt.isNotEmpty && !_todoKeys.contains(key) && !_doneKeys.contains(key)) {
          _todoKeys.add(key);
          added++;
        }
      }
    });
    await _savePrefs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV에서 $added편을 [해야 할 일]에 등록했습니다.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF00205B),
        foregroundColor: Colors.white,
        title: Row(
          children: [
            const Text('✈ AirPulse', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(10)),
              child: Text('LIVE $_updatedAt', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _fetchData()),
        ],
      ),
      body: _loading && _allRecords.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tabIndex,
              children: [_buildAllFlightsTab(), _buildMyJobTab(), _buildSettingsTab()],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.flight_takeoff), label: '전체 운항'),
          NavigationDestination(
            icon: Badge(label: Text('${_todoKeys.length}'), child: const Icon(Icons.assignment_turned_in)),
            label: 'MY JOB',
          ),
          const NavigationDestination(icon: Icon(Icons.settings), label: '설정'),
        ],
      ),
    );
  }
  String _fmtDateShort(DateTime d) => '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDateTime(bool isFrom) async {
    final initDate = isFrom ? _fromDate : _toDate;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initDate,
      firstDate: DateTime(2025),
      lastDate: DateTime(2030),
    );
    if (pickedDate == null || !mounted) return;
    final pickedHour = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(isFrom ? 'From 시작 시각 선택' : 'To 종료 시각 선택'),
        children: [
          SizedBox(
            width: 260,
            height: 260,
            child: GridView.count(
              crossAxisCount: 4,
              children: List.generate(24, (h) => TextButton(
                onPressed: () => Navigator.pop(ctx, h),
                child: Text('${h.toString().padLeft(2, '0')}시'),
              )),
            ),
          ),
        ],
      ),
    );
    if (pickedHour != null) {
      setState(() {
        if (isFrom) {
          _fromDate = pickedDate;
          _fromHour = pickedHour;
        } else {
          _toDate = pickedDate;
          _toHour = pickedHour;
        }
      });
    }
  }

  Widget _buildAllFlightsTab() {
    final kw = _searchKw.trim().toUpperCase();
    final fixedList = _fixedAirlines.split(',').map((e) => e.trim().toUpperCase()).where((e) => e.isNotEmpty).toList();
    final minKey = '${_fromDate.year}${_fromDate.month.toString().padLeft(2, '0')}${_fromDate.day.toString().padLeft(2, '0')} ${_fromHour.toString().padLeft(2, '0')}';
    final maxKey = '${_toDate.year}${_toDate.month.toString().padLeft(2, '0')}${_toDate.day.toString().padLeft(2, '0')} ${_toHour.toString().padLeft(2, '0')}';

    final filtered = _allRecords.where((r) {
      if (!_includeCs && r['_is_cs'] == true) return false;
      if (_useFixedAirlines && fixedList.isNotEmpty && !fixedList.contains((r['항공사코드'] ?? '').toString().toUpperCase())) return false;
      if (_ioFilter != '전체' && r['구분'] != _ioFilter) return false;
      if (_termFilter != '전체' && r['터미널'] != _termFilter) return false;
      if (kw.isNotEmpty) {
        final target = '${r['편명']} ${r['출발지']} ${r['도착지']}'.toUpperCase();
        if (!target.contains(kw)) return false;
      }
      final ymd = (r['일자코드'] ?? '').toString();
      final std = _fmtHHMM(r['STD/A']);
      if (ymd.length == 8 && std.length >= 2 && std != '-') {
        final curKey = '$ymd ${std.substring(0, 2)}';
        if (curKey.compareTo(minKey) < 0 || curKey.compareTo(maxKey) > 0) return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            children: [
              TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: '편명, 공항 검색 (예: 7C101, 101, LAX)',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchKw.isNotEmpty
                      ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { _searchCtrl.clear(); setState(() => _searchKw = ''); })
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (v) => setState(() => _searchKw = v),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _ioFilter,
                      isDense: true,
                      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6), border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: '전체', child: Text('구분: 전체', style: TextStyle(fontSize: 13))),
                        DropdownMenuItem(value: 'INBOUND', child: Text('IN/B (도착)', style: TextStyle(fontSize: 13))),
                        DropdownMenuItem(value: 'OUTBOUND', child: Text('OUT/B (출발)', style: TextStyle(fontSize: 13))),
                      ],
                      onChanged: (v) => setState(() => _ioFilter = v ?? '전체'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _termFilter,
                      isDense: true,
                      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6), border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: '전체', child: Text('터미널: 전체', style: TextStyle(fontSize: 13))),
                        DropdownMenuItem(value: 'T1', child: Text('T1', style: TextStyle(fontSize: 13))),
                        DropdownMenuItem(value: 'T2', child: Text('T2', style: TextStyle(fontSize: 13))),
                        DropdownMenuItem(value: '화물터미널', child: Text('화물터미널', style: TextStyle(fontSize: 13))),
                      ],
                      onChanged: (v) => setState(() => _termFilter = v ?? '전체'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pickDateTime(true),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                      child: Text('From ${_fmtDateShort(_fromDate)} ${_fromHour.toString().padLeft(2, '0')}시', style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('~')),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pickDateTime(false),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                      child: Text('To ${_fmtDateShort(_toDate)} ${_toHour.toString().padLeft(2, '0')}시', style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.restart_alt, color: Color(0xFF00205B)),
                    tooltip: '현재 시각 +6시간으로 초기화',
                    onPressed: () => setState(() {
                      _setDefault6Hours();
                      _ioFilter = '전체';
                      _termFilter = '전체';
                      _searchCtrl.clear();
                      _searchKw = '';
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (_, idx) => _flightTile(filtered[idx]),
          ),
        ),
      ],
    );
  }
  Widget _flightTile(Map<String, dynamic> r) {
    final isIn = r['구분'] == 'INBOUND';
    final bgColor = isIn ? const Color(0xFFF0F9FF) : const Color(0xFFFFFBEB);
    final key = _rowKey(r);
    final inMyJob = _todoKeys.contains(key) || _doneKeys.contains(key);
    final eta = (r['ATD/A'] ?? '').toString().isNotEmpty ? '-' : _fmtHHMM(r['ETD/A']);

    return Card(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: r['_changed'] == true ? const BorderSide(color: Colors.deepOrange, width: 1.5) : BorderSide.none,
      ),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showFlightDetailSheet(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('${r['편명']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(width: 6),
                        Text(isIn ? 'IN/B' : 'OUT/B', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isIn ? Colors.blue.shade800 : Colors.orange.shade900)),
                        const SizedBox(width: 6),
                        Text('${r['터미널']}  주기장${r['주기장'] ?? '-'}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        if (r['_changed'] == true) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: Colors.deepOrange, borderRadius: BorderRadius.circular(4)),
                            child: const Text('변경', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text('${r['일자']}  ${r['출발지']}-${r['도착지']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87)),
                    const SizedBox(height: 2),
                    Text('STD ${_fmtHHMM(r['STD/A'])} · ETD $eta · ATD ${_fmtHHMM(r['ATD/A'])}  (${r['현황'] ?? '-'})', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(inMyJob ? Icons.check_circle : Icons.add_circle_outline, color: inMyJob ? Colors.teal : const Color(0xFF00205B)),
                onPressed: () {
                  setState(() {
                    if (!inMyJob) _todoKeys.add(key);
                  });
                  _savePrefs();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['편명']} MY JOB에 추가됨'), duration: const Duration(seconds: 1)));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFlightDetailSheet(Map<String, dynamic> r) {
    final isIn = r['구분'] == 'INBOUND';
    final eta = (r['ATD/A'] ?? '').toString().isNotEmpty ? '-' : _fmtHHMM(r['ETD/A']);
    final key = _rowKey(r);
    final inMyJob = _todoKeys.contains(key) || _doneKeys.contains(key);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(ctx).viewPadding.bottom + 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('${r['편명']} (${r['항공사명'] ?? r['항공사코드']})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF00205B))),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const Divider(),
              _detailRow('운항 일자', '${r['일자']}'),
              _detailRow('구분 / 유형', '${isIn ? 'IN/B (도착)' : 'OUT/B (출발)'} · ${r['여객/화물'] ?? '-'}'),
              _detailRow('터미널 / 주기장', '${r['터미널']} · 주기장 ${r['주기장'] ?? '-'}'),
              _detailRow('노선', '${r['출발지']} → ${r['도착지']}'),
              _detailRow('등록기호 / 기종', '${r['등록기호'] ?? '-'} / ${r['기종'] ?? '-'}'),
              _detailRow('STD / ETD / ATD', '${_fmtHHMM(r['STD/A'])}  /  $eta  /  ${_fmtHHMM(r['ATD/A'])}'),
              _detailRow('운항 현황', '${r['현황'] ?? '-'}'),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: inMyJob ? null : () {
                    setState(() => _todoKeys.add(key));
                    _savePrefs();
                    Navigator.pop(ctx);
                  },
                  icon: Icon(inMyJob ? Icons.check : Icons.add),
                  label: Text(inMyJob ? '이미 MY JOB에 등록됨' : 'MY JOB 해야 할 일에 추가'),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00205B), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 115, child: Text(label, style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.bold, fontSize: 13))),
          Expanded(child: Text(val, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
        ],
      ),
    );
  }
  Widget _buildMyJobTab() {
    final mapByKey = {for (final r in _allRecords) _rowKey(r): r};
    bool matchTerm(String k) {
      if (_jobTermFilter == '전체') return true;
      final r = mapByKey[k];
      return r == null || r['터미널'] == _jobTermFilter;
    }

    final todos = _todoKeys.where(matchTerm).toList();
    final dones = _doneKeys.where(matchTerm).toList();

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: _importCsvFile,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('CSV 불러오기', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00205B), foregroundColor: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _jobTermFilter,
                  isDense: true,
                  decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: '전체', child: Text('터미널: 전체', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'T1', child: Text('T1', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'T2', child: Text('T2', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: '화물터미널', child: Text('화물터미널', style: TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) => setState(() => _jobTermFilter = v ?? '전체'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(flex: 2, child: _kanbanColumn('해야 할 일 (${todos.length})', Colors.blue.shade100, todos, mapByKey, true)),
              const VerticalDivider(width: 1),
              Expanded(flex: 1, child: _kanbanColumn('완료한 일 (${dones.length})', Colors.green.shade100, dones, mapByKey, false)),
            ],
          ),
        ),
      ],
    );
  }
  Widget _kanbanColumn(String title, Color headerBg, List<String> keys, Map<String, Map<String, dynamic>> mapByKey, bool isTodo) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: headerBg,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: keys.length,
            itemBuilder: (_, i) {
              final k = keys[i];
              final r = mapByKey[k];
              final flt = r != null ? '${r['편명']}' : k.split(':').last;
              final dayMon = r != null ? _fmtDayMon(r) : k.split(':').first;
              final tm = r != null ? '${r['터미널'] ?? '-'}' : '-';
              final stand = r != null ? '${r['주기장'] ?? '-'}' : '-';
              final std = r != null ? _fmtHHMM(r['STD/A']) : '-';
              final etd = r != null ? ((r['ATD/A'] ?? '').toString().isNotEmpty ? '-' : _fmtHHMM(r['ETD/A'])) : '-';
              final isIn = r?['구분'] == 'INBOUND';

              return Dismissible(
                key: ValueKey('${isTodo ? 'todo' : 'done'}_$k'),
                direction: isTodo ? DismissDirection.startToEnd : DismissDirection.endToStart,
                onDismissed: (_) {
                  setState(() {
                    if (isTodo) {
                      _todoKeys.remove(k);
                      if (!_doneKeys.contains(k)) _doneKeys.insert(0, k);
                    } else {
                      _doneKeys.remove(k);
                      if (!_todoKeys.contains(k)) _todoKeys.add(k);
                    }
                  });
                  _savePrefs();
                },
                background: Container(
                  color: isTodo ? Colors.teal : Colors.orange,
                  alignment: isTodo ? Alignment.centerLeft : Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(isTodo ? Icons.check : Icons.undo, color: Colors.white),
                ),
                child: Card(
                  color: isIn ? const Color(0xFFF0F9FF) : const Color(0xFFFFFBEB),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: r?['_changed'] == true ? const BorderSide(color: Colors.deepOrange, width: 1.5) : BorderSide.none,
                  ),
                  margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: isTodo
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(flt, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                  Text(dayMon, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54)),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text('$tm · 주기장 $stand', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF00205B))),
                              const SizedBox(height: 2),
                              Text('STD $std · ETD $etd', style: const TextStyle(fontSize: 11, color: Colors.black87)),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(flt, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              Text(dayMon, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                              Text('주기장 $stand', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00205B))),
                            ],
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('기본 고정 항공사 필터 (쉼표 구분)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _fixedAlCtrl,
                decoration: const InputDecoration(hintText: '예: KE, OZ (비워두면 전체 표시)', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                setState(() => _fixedAirlines = _fixedAlCtrl.text.trim().toUpperCase());
                _savePrefs();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('기본 항공사 설정이 저장되었습니다.')));
              },
              child: const Text('저장'),
            ),
          ],
        ),
        SwitchListTile(
          title: const Text('전체 운항에서 고정 항공사 필터 적용'),
          value: _useFixedAirlines,
          onChanged: (v) => setState(() => _useFixedAirlines = v),
        ),
        SwitchListTile(
          title: const Text('전체 운항에서 코드쉐어 편명 포함'),
          value: _includeCs,
          onChanged: (v) => setState(() => _includeCs = v),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.copy, color: Color(0xFF00205B)),
          title: const Text('MY JOB 작업 현황 카톡 공유용 복사'),
          subtitle: const Text('완료한 일과 남은 일 목록을 텍스트로 복사'),
          onTap: () {
            final summary = '[AirPulse MY JOB 현황]\n✅ 완료 (${_doneKeys.length}편): ${_doneKeys.join(', ')}\n⏳ 남은 일 (${_todoKeys.length}편): ${_todoKeys.join(', ')}';
            Clipboard.setData(ClipboardData(text: summary));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('작업 현황이 클립보드에 복사되었습니다.')));
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_sweep, color: Colors.red),
          title: const Text('MY JOB 완료한 일 모두 비우기'),
          onTap: () {
            setState(() => _doneKeys.clear());
            _savePrefs();
          },
        ),
        ListTile(
          leading: const Icon(Icons.restart_alt, color: Colors.red),
          title: const Text('MY JOB 전체 초기화 (해야 할 일 + 완료한 일)'),
          onTap: () {
            setState(() {
              _todoKeys.clear();
              _doneKeys.clear();
            });
            _savePrefs();
          },
        ),
      ],
    );
  }
}
