import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const AirPulseApp());

class AirPulseApp extends StatelessWidget {
  const AirPulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirPulse',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00205B),
          primary: const Color(0xFF00205B),
          secondary: const Color(0xFF0066A6),
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      ),
      home: const MainHomePage(),
    );
  }
}

class MainHomePage extends StatefulWidget {
  const MainHomePage({super.key});
  @override
  State<MainHomePage> createState() => _MainHomePageState();
}

class _MainHomePageState extends State<MainHomePage> {
  int _tabIndex = 0;
  bool _isLoading = true;
  bool _autoSync = true;
  Timer? _syncTimer;
  String _updatedAt = "동기화 중...";
  String _errorMsg = "";
  List<Map<String, dynamic>> _allRecords = [];
  List<String> _dateOptions = ["전체"];
  String _selectedDate = "전체";
  String _selectedIO = "전체";
  String _selectedType = "전체";
  bool _includeCodeshare = false;
  bool _onlyChanged = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  Set<String> _favFlights = {};
  List<String> _favAirlines = [];
  List<String> _favStands = [];
  final TextEditingController _favAirlineCtrl = TextEditingController();
  final TextEditingController _favStandCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPrefsAndFetch();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_autoSync && mounted) _fetchFlightData(silent: true);
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPrefsAndFetch() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _favFlights = (prefs.getStringList('fav_flights') ?? []).toSet();
      _favAirlines = prefs.getStringList('fav_airlines') ?? [];
      _favStands = prefs.getStringList('fav_stands') ?? [];
      _favAirlineCtrl.text = _favAirlines.join(', ');
      _favStandCtrl.text = _favStands.join(', ');
    });
    await _fetchFlightData();
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('fav_flights', _favFlights.toList());
    await prefs.setStringList('fav_airlines', _favAirlines);
    await prefs.setStringList('fav_stands', _favStands);
  }

  Future<void> _fetchFlightData({bool silent = false}) async {
    if (!silent) setState(() { _isLoading = true; _errorMsg = ""; });
    try {
      const liveUrl = "https://storage.googleapis.com/airpulse-icn-data-2026/flight_db.json";
      final uri = Uri.parse("$liveUrl?t=${DateTime.now().millisecondsSinceEpoch}");
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        final List rawList = decoded['records'] ?? [];
        final records = rawList.map((e) => Map<String, dynamic>.from(e)).toList();
        int dayRank(String d) => d.startsWith("어제") ? 1 : (d.startsWith("오늘") ? 2 : (d.startsWith("내일") ? 3 : 4));
        records.sort((a, b) {
          final diff = dayRank(a['일자'] ?? '') - dayRank(b['일자'] ?? '');
          return diff != 0 ? diff : (a['STD/A'] ?? '99:99:99').compareTo(b['STD/A'] ?? '99:99:99');
        });
        final dates = <String>{"전체", ...records.map((r) => (r['일자'] ?? '').toString()).where((s) => s.isNotEmpty)};
        setState(() {
          _allRecords = records;
          _updatedAt = decoded['updated_at'] ?? '';
          _dateOptions = dates.toList();
          if (_selectedDate == "전체") {
            _selectedDate = _dateOptions.firstWhere((d) => d.startsWith("오늘"), orElse: () => "전체");
          }
          _isLoading = false;
        });
      } else if (!silent) {
        setState(() { _errorMsg = "서버 응답 오류 (${res.statusCode})"; _isLoading = false; });
      }
    } catch (e) {
      if (!silent) setState(() { _errorMsg = "데이터 수신 실패: $e"; _isLoading = false; });
    }
  }

  void _jumpToCurrentTime(List<Map<String, dynamic>> currentList) {
    final now = DateTime.now();
    final nowStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:00";
    final idx = currentList.indexWhere((r) => (r['STD/A'] ?? '').toString().compareTo(nowStr) >= 0);
    if (idx > 0 && _scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(idx * 136.0, duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    }
  }
  List<Map<String, dynamic>> _getFilteredList({required bool onlyFavorites}) {
    final query = _searchCtrl.text.trim().toUpperCase();
    return _allRecords.where((r) {
      if (!_includeCodeshare && (r['_is_cs'] == true)) return false;
      if (_onlyChanged && (r['_changed'] != true)) return false;
      if (onlyFavorites) {
        final fn = (r['편명'] ?? '').toString().toUpperCase();
        final al = (r['항공사코드'] ?? '').toString().toUpperCase();
        final st = (r['주기장'] ?? '').toString().toUpperCase();
        if (!_favFlights.contains(fn) && !_favAirlines.contains(al) && !_favStands.any((s) => s.isNotEmpty && st.contains(s))) return false;
      }
      if (_selectedDate != "전체" && r['일자'] != _selectedDate) return false;
      if (_selectedIO != "전체" && r['구분'] != _selectedIO) return false;
      if (_selectedType != "전체" && r['여객/화물'] != _selectedType) return false;
      if (query.isNotEmpty) {
        final target = "${r['항공사코드']} ${r['편명']} ${r['주기장']} ${r['출발지']} ${r['도착지']} ${r['등록기호']}".toUpperCase();
        if (!target.contains(query)) return false;
      }
      return true;
    }).toList();
  }

  Widget _buildFilterBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  value: _dateOptions.contains(_selectedDate) ? _selectedDate : "전체",
                  isDense: true,
                  decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                  items: _dateOptions.map((d) => DropdownMenuItem(value: d, child: Text(d, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)))).toList(),
                  onChanged: (v) => setState(() => _selectedDate = v ?? "전체"),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  value: _selectedIO,
                  isDense: true,
                  decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: "전체", child: Text("구분: 전체", style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: "INBOUND", child: Text("INBOUND", style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: "OUTBOUND", child: Text("OUTBOUND", style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _selectedIO = v ?? "전체"),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  value: _selectedType,
                  isDense: true,
                  decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: "전체", child: Text("유형: 전체", style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: "여객", child: Text("여객", style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: "화물", child: Text("화물", style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _selectedType = v ?? "전체"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: "편명(KE201), 주기장(627), 공항 검색",
                    hintStyle: const TextStyle(fontSize: 13),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () => setState(() => _searchCtrl.clear()))
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              FilterChip(
                label: const Text("변경", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                visualDensity: VisualDensity.compact,
                selectedColor: Colors.orange.shade200,
                selected: _onlyChanged,
                onSelected: (v) => setState(() => _onlyChanged = v),
              ),
              const SizedBox(width: 4),
              FilterChip(
                label: const Text("C/S", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                visualDensity: VisualDensity.compact,
                selected: _includeCodeshare,
                onSelected: (v) => setState(() => _includeCodeshare = v),
              ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFlightCard(Map<String, dynamic> r) {
    final flightNo = (r['편명'] ?? '').toString();
    final status = (r['현황'] ?? '').toString();
    final isChanged = r['_changed'] == true;
    final isDelay = status.contains('지연') || status.contains('결항') || status.contains('회항');
    final isActive = status == '출발' || status == '도착';
    final isCargo = r['여객/화물'] == '화물';
    final isFav = _favFlights.contains(flightNo.toUpperCase());
    final badgeBg = isDelay ? const Color(0xFFFEE2E2) : (isActive ? const Color(0xFFE0F2FE) : const Color(0xFFE2E8F0));
    final badgeFg = isDelay ? const Color(0xFF991B1B) : (isActive ? const Color(0xFF075985) : const Color(0xFF334155));

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: isChanged ? 3 : 1.2,
      color: isChanged ? const Color(0xFFFFFBEB) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isChanged ? const BorderSide(color: Colors.orange, width: 1.5) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() {
                      final key = flightNo.toUpperCase();
                      _favFlights.contains(key) ? _favFlights.remove(key) : _favFlights.add(key);
                    });
                    _saveFavorites();
                  },
                  child: Icon(isFav ? Icons.star : Icons.star_border, color: isFav ? Colors.amber : Colors.grey, size: 24),
                ),
                const SizedBox(width: 6),
                Text(flightNo, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF00205B))),
                if (isChanged) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(4)),
                    child: const Text("방금변경", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ],
                const SizedBox(width: 6),
                Expanded(child: Text(r['항공사명'] ?? '', style: const TextStyle(fontSize: 12, color: Colors.black54), overflow: TextOverflow.ellipsis)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: isCargo ? const Color(0xFFFEF3C7) : const Color(0xFFEDE9FE), borderRadius: BorderRadius.circular(4)),
                  child: Text(r['여객/화물'] ?? '', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isCargo ? const Color(0xFF92400E) : const Color(0xFF5B21B6))),
                ),
                const SizedBox(width: 6),
                if (status.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(4)),
                    child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: badgeFg)),
                  ),
              ],
            ),
            const Divider(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Text("${r['출발지']} ➔ ${r['도착지']}", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Text("(${r['기종']} / ${r['등록기호']})", style: const TextStyle(fontSize: 11, color: Colors.black54)),
                ]),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xFF00205B), borderRadius: BorderRadius.circular(5)),
                  child: Text("주기장: ${(r['주기장'] ?? '').toString().isEmpty ? '-' : r['주기장']}", style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("${r['구분'] == 'INBOUND' ? 'STA' : 'STD'}: ${(r['STD/A'] ?? '').toString().isEmpty ? '-' : r['STD/A']}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                Text("${r['구분'] == 'INBOUND' ? 'ETA' : 'ETD'}: ${(r['ETD/A'] ?? '').toString().isEmpty ? '-' : r['ETD/A']}", style: const TextStyle(fontSize: 12, color: Color(0xFF0066A6), fontWeight: FontWeight.bold)),
                Text("${r['구분'] == 'INBOUND' ? 'ATA' : 'ATD'}: ${(r['ATD/A'] ?? '').toString().isEmpty ? '-' : r['ATD/A']}", style: const TextStyle(fontSize: 12, color: Colors.teal, fontWeight: FontWeight.bold)),
              ],
            ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          tileColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: const Text("30초마다 자동 실시간 동기화", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: const Text("화면을 켜두면 자동으로 최신 1분 서버 데이터를 반영합니다."),
          value: _autoSync,
          onChanged: (v) => setState(() => _autoSync = v),
        ),
        const SizedBox(height: 16),
        const Text("⭐ 담당 항공사 및 주기장 즐겨찾기 설정", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF00205B))),
        const SizedBox(height: 10),
        TextField(controller: _favAirlineCtrl, decoration: const InputDecoration(labelText: "담당 항공사 코드 (쉼표로 구분)", hintText: "예: KE, OZ, 5X", border: OutlineInputBorder(), filled: true, fillColor: Colors.white)),
        const SizedBox(height: 10),
        TextField(controller: _favStandCtrl, decoration: const InputDecoration(labelText: "담당 주기장 번호 (쉼표로 구분)", hintText: "예: 627, 628, 101", border: OutlineInputBorder(), filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00205B), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
          icon: const Icon(Icons.save),
          label: const Text("즐겨찾기 필터 저장하기", style: TextStyle(fontWeight: FontWeight.bold)),
          onPressed: () {
            setState(() {
              _favAirlines = _favAirlineCtrl.text.split(',').map((e) => e.trim().toUpperCase()).where((e) => e.isNotEmpty).toList();
              _favStands = _favStandCtrl.text.split(',').map((e) => e.trim().toUpperCase()).where((e) => e.isNotEmpty).toList();
            });
            _saveFavorites();
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("즐겨찾기 필터가 스마트폰에 저장되었습니다.")));
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final listData = _tabIndex == 0 ? _getFilteredList(onlyFavorites: false) : (_tabIndex == 1 ? _getFilteredList(onlyFavorites: true) : <Map<String, dynamic>>[]);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF00205B),
        foregroundColor: Colors.white,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text("AirPulse", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: _autoSync ? Colors.green : Colors.grey, borderRadius: BorderRadius.circular(10)),
              child: Text(_autoSync ? "LIVE 30s" : "수동", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ]),
          Text("서버수집: $_updatedAt", style: const TextStyle(fontSize: 11, color: Colors.white70)),
        ]),
        actions: [
          if (_tabIndex != 2)
            IconButton(icon: const Icon(Icons.access_time), tooltip: "현재 시간대 이동", onPressed: () => _jumpToCurrentTime(listData)),
          IconButton(icon: const Icon(Icons.refresh), tooltip: "즉시 동기화", onPressed: () => _fetchFlightData()),
        ],
      ),
      body: _tabIndex == 2 ? _buildSettingsTab() : Column(children: [
        _buildFilterBar(),
        Container(
          width: double.infinity, color: const Color(0xFFE2E8F0), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(_tabIndex == 0 ? "조회 결과: ${listData.length}편" : "⭐ 즐겨찾기 항공편: ${listData.length}편", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF00205B))),
        ),
        Expanded(
          child: _isLoading ? const Center(child: CircularProgressIndicator())
            : _errorMsg.isNotEmpty ? Center(child: Text(_errorMsg, style: const TextStyle(color: Colors.red)))
            : listData.isEmpty ? const Center(child: Text("조건에 맞는 운항편이 없습니다.", textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)))
            : ListView.builder(controller: _scrollCtrl, itemCount: listData.length, itemBuilder: (ctx, idx) => _buildFlightCard(listData[idx])),
        ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (idx) => setState(() => _tabIndex = idx),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.flight_takeoff), label: "전체운항"),
          NavigationDestination(icon: Icon(Icons.star), label: "즐겨찾기"),
          NavigationDestination(icon: Icon(Icons.settings), label: "설정"),
        ],
      ),
    );
  }
}
