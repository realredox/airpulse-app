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
  String _typeFilter = '전체';
  String _termFilter = '전체';
  String _searchKw = '';
  bool _onlyChanged = false;
  bool _includeCs = false;

  // MY JOB 상태
  String _jobTermFilter = '전체';
  String _jobTypeFilter = '전체';
  List<String> _todoKeys = [];
  List<String> _doneKeys = [];
  List<String> _favAirlines = [];
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _fetchData();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchData(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _todoKeys = p.getStringList('todo_keys') ?? [];
      _doneKeys = p.getStringList('done_keys') ?? [];
      _favAirlines = p.getStringList('fav_airlines') ?? [];
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('todo_keys', _todoKeys);
    await p.setStringList('done_keys', _doneKeys);
    await p.setStringList('fav_airlines', _favAirlines);
  }

  String _fmtHHMM(dynamic raw) {
    final s = (raw ?? '').toString().trim();
    return s.length >= 5 ? s.substring(0, 5) : (s.isEmpty ? '-' : s);
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
              children: [
                _buildAllFlightsTab(),
                _buildMyJobTab(),
                _buildSettingsTab(),
              ],
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
  Widget _buildAllFlightsTab() {
    final kw = _searchKw.trim().toUpperCase();
    final filtered = _allRecords.where((r) {
      if (!_includeCs && r['_is_cs'] == true) return false;
      if (_onlyChanged && r['_changed'] != true) return false;
      if (_ioFilter != '전체' && r['구분'] != _ioFilter) return false;
      if (_typeFilter != '전체' && r['여객/화물'] != _typeFilter) return false;
      if (_termFilter != '전체' && r['터미널'] != _termFilter) return false;
      if (kw.isNotEmpty) {
        final target = '${r['편명']} ${r['출발지']} ${r['도착지']} ${r['주기장']}'.toUpperCase();
        if (!target.contains(kw)) return false;
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
                decoration: InputDecoration(
                  hintText: '편명, 공항, 주기장 검색 (예: 7C101, 627)',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (v) => setState(() => _searchKw = v),
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _chip('전체', _ioFilter == '전체', () => setState(() => _ioFilter = '전체')),
                    _chip('IN/B', _ioFilter == 'INBOUND', () => setState(() => _ioFilter = 'INBOUND')),
                    _chip('OUT/B', _ioFilter == 'OUTBOUND', () => setState(() => _ioFilter = 'OUTBOUND')),
                    const SizedBox(width: 6),
                    _chip('T1', _termFilter == 'T1', () => setState(() => _termFilter = _termFilter == 'T1' ? '전체' : 'T1')),
                    _chip('T2', _termFilter == 'T2', () => setState(() => _termFilter = _termFilter == 'T2' ? '전체' : 'T2')),
                    _chip('화물터미널', _termFilter == '화물터미널', () => setState(() => _termFilter = _termFilter == '화물터미널' ? '전체' : '화물터미널')),
                    const SizedBox(width: 6),
                    _chip('방금변경', _onlyChanged, () => setState(() => _onlyChanged = !_onlyChanged)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length > 300 ? 300 : filtered.length,
            itemBuilder: (_, idx) => _flightTile(filtered[idx]),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontSize: 12, color: active ? Colors.white : Colors.black87)),
        selected: active,
        selectedColor: const Color(0xFF00205B),
        onSelected: (_) => onTap(),
      ),
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
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: ListTile(
        dense: true,
        title: Row(
          children: [
            Text('${r['편명']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(width: 6),
            Text(isIn ? 'IN/B' : 'OUT/B', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isIn ? Colors.blue[800] : Colors.orange[900])),
            const SizedBox(width: 6),
            Text('${r['터미널']} · 주기장 ${r['주기장'] ?? '-'}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const Spacer(),
            if (r['_changed'] == true)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: Colors.deepOrange, borderRadius: BorderRadius.circular(4)),
                child: const Text('변경', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        subtitle: Text('${r['일자']} | ${r['출발지']}→${r['도착지']} | STD ${_fmtHHMM(r['STD/A'])} · ETD $eta · ATD ${_fmtHHMM(r['ATD/A'])} (${r['현황'] ?? '-'})', style: const TextStyle(fontSize: 11)),
        trailing: IconButton(
          icon: Icon(inMyJob ? Icons.check_circle : Icons.add_circle_outline, color: inMyJob ? Colors.teal : const Color(0xFF00205B)),
          onPressed: () {
            setState(() {
              if (!inMyJob) _todoKeys.add(key);
            });
            _savePrefs();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['편명']} MY JOB에 추가됨'), duration: const Duration(seconds: 1)));
          },
        ),
      ),
    );
  }

  Widget _buildMyJobTab() {
    final mapByKey = {for (final r in _allRecords) _rowKey(r): r};
    bool matchJobFilter(String k) {
      final r = mapByKey[k];
      if (r == null) return true;
      if (_jobTermFilter != '전체' && r['터미널'] != _jobTermFilter) return false;
      if (_jobTypeFilter == '여객(P)' && r['여객/화물'] != '여객') return false;
      if (_jobTypeFilter == '화물(C)' && r['여객/화물'] != '화물') return false;
      return true;
    }

    final todos = _todoKeys.where(matchJobFilter).toList();
    final dones = _doneKeys.where(matchJobFilter).toList();

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _importCsvFile,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('CSV 불러오기', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00205B), foregroundColor: Colors.white),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: ['전체', '여객(P)', '화물(C)'].map((t) => _chip(t, _jobTypeFilter == t, () => setState(() => _jobTypeFilter = t))).toList(),
                      ),
                    ),
                  ),
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: ['전체', 'T1', 'T2', '화물터미널'].map((tm) => _chip(tm, _jobTermFilter == tm, () => setState(() => _jobTermFilter = tm))).toList(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _kanbanColumn('해야 할 일 (${todos.length})', Colors.blue[50]!, todos, mapByKey, true)),
              const VerticalDivider(width: 1),
              Expanded(child: _kanbanColumn('완료한 일 (${dones.length})', Colors.green[50]!, dones, mapByKey, false)),
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
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: keys.length,
            itemBuilder: (_, i) {
              final k = keys[i];
              final r = mapByKey[k];
              final flt = r != null ? '${r['편명']}' : k.split(':').last;
              final stand = r != null ? '${r['주기장'] ?? '-'}' : '-';
              final tm = r != null ? '${r['터미널'] ?? ''}' : '';
              final std = r != null ? _fmtHHMM(r['STD/A']) : '';
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
                  margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(flt, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 2),
                        Text('$tm · 주기장 $stand', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00205B))),
                        Text('STD $std ${isTodo ? '→ 밀어서 완료' : '← 밀어서 복구'}', style: const TextStyle(fontSize: 10, color: Colors.black54)),
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
        SwitchListTile(
          title: const Text('전체 운항에서 코드쉐어 편명 포함'),
          value: _includeCs,
          onChanged: (v) => setState(() => _includeCs = v),
        ),
        const Divider(),
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
