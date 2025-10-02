import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

/// ---- Datentyp für Fahrzeuge ----
class VehicleItem {
  final String label;
  final int index;
  VehicleItem({required this.label, required this.index});
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    // Kolibri-Orange als Seed
    const kolibri = Color(0xFFEE7E1B);
    return MaterialApp(
      title: 'Optimizer',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: kolibri,
        scaffoldBackgroundColor: const Color(0xFFF8F7F5),
      ),
      home: const WebShell(),
    );
  }
}

/// ---------------- WebShell (WebView + Startmenü + BottomSheets) ----------------
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  static const String vehicleUrl = 'https://soleco-optimizer.ch/VehicleAppointments';

  final storage = const FlutterSecureStorage();
  final cookieMgr = WebviewCookieManager();

  late final WebViewController _c;
  bool _loading = true;

  // Startmenü-Overlay
  bool _showHub = false;

  // Flusssteuerung
  bool _didAutoLogin = false;
  bool _autoLaunchBottomSheet = true; // beim ersten Laden automatisch BottomSheet starten
  bool _sheetOpen = false;

  static const _cookieStoreKey = 'cookie_store_v1';
  String _lastUrl = '';

  @override
  void initState() {
    super.initState();

    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (url) async {
            _lastUrl = url;
            setState(() => _loading = false);

            // Auto-Login erkennen
            if (await _isB2CLoginDom()) {
              if (!_didAutoLogin) {
                _didAutoLogin = true;
                await _autoLoginB2C();
              }
            }

            // Wenn auf VehicleAppointments: Cookies sichern & Auto-Fluss starten
            if (url.contains('VehicleAppointments')) {
              await _persistCookies(url);
              if (!mounted) return;
              // Startmenü anzeigen (zugänglich via AppBar), aber direkt BottomSheet starten
              if (_autoLaunchBottomSheet && !_sheetOpen) {
                setState(() => _showHub = true);
                Future.microtask(_startAutoFlow);
              }
              return;
            }

            await _persistCookies(url);
          },

          onNavigationRequest: (req) {
            final u = req.url;

            // Navbar-Logout abfangen
            if (u.startsWith('https://soleco-optimizer.ch/Account/SignOut') ||
                u.contains('/Account/SignOut')) {
              Future.microtask(() async { await _performSignOutAndGotoLogin(); });
              return NavigationDecision.prevent;
            }

            if (u.startsWith('tel:') || u.startsWith('mailto:')) {
              launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    // Cookies wiederherstellen, dann Fahrzeug-Seite laden
    Future.microtask(() async {
      await _restoreCookies();
      await _c.loadRequest(Uri.parse(vehicleUrl));
    });
  }

  // ---------- Signout & Cookies ----------
  Future<void> _performSignOutAndGotoLogin() async {
    try {
      await cookieMgr.clearCookies();
      try { await _c.runJavaScript('try{localStorage.clear();sessionStorage.clear();}catch(e){}'); } catch(_){}
      await storage.delete(key: _cookieStoreKey);
    } catch(_) {}
    setState(() {
      _didAutoLogin = false;
      _autoLaunchBottomSheet = true;
      _showHub = false;
      _sheetOpen = false;
    });
    await _c.loadRequest(Uri.parse(vehicleUrl));
  }

  Future<void> _restoreCookies() async {
    final raw = await storage.read(key: _cookieStoreKey);
    if (raw == null) return;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    for (final entry in map.entries) {
      final domain = entry.key;
      final list = (entry.value as List).cast<Map>();
      for (final m in list) {
        try {
          final c = Cookie(m['name'] as String, m['value'] as String)
            ..domain = domain
            ..path = (m['path'] as String?) ?? '/'
            ..secure = (m['secure'] as bool?) ?? true;
          await cookieMgr.setCookies([c]);
        } catch (_) {}
      }
    }
  }

  Future<void> _persistCookies(String currentUrl) async {
    try {
      final uri = Uri.parse(currentUrl);
      final cookies = await cookieMgr.getCookies(currentUrl);
      final raw = await storage.read(key: _cookieStoreKey);
      final Map<String, List<Map<String, dynamic>>> store =
          raw == null ? {} : (jsonDecode(raw) as Map)
              .map((k, v) => MapEntry(k as String, (v as List).cast<Map>().cast<Map<String, dynamic>>()));

      for (final c in cookies) {
        final domain = c.domain ?? uri.host;
        store.putIfAbsent(domain, () => []);
        final list = store[domain]!;
        final idx = list.indexWhere((m) => m['name'] == c.name && m['path'] == (c.path ?? '/'));
        final m = {
          'name': c.name,
          'value': c.value,
          'path': c.path ?? '/',
          'secure': c.secure ?? true,
        };
        if (idx >= 0) list[idx] = m; else list.add(m);
      }
      await storage.write(key: _cookieStoreKey, value: jsonEncode(store));
    } catch (_) {}
  }

  // ---------- B2C Auto-Login ----------
  Future<bool> _isB2CLoginDom() async {
    try {
      final res = await _c.runJavaScriptReturningResult('''
        (function(){
          var f=document.getElementById('localAccountForm');
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var n=document.getElementById('next');
          return !!(f&&u&&p&&n);
        })();
      ''');
      return res.toString() == 'true' || res.toString() == '1';
    } catch (_) { return false; }
  }

  Future<void> _autoLoginB2C() async {
    final user = await storage.read(key: 'soleco_user');
    final pass = await storage.read(key: 'soleco_pass');
    if (user == null || pass == null) return;

    final js = '''
      (function(){
        function setVal(el,val){
          if(!el) return false;
          el.focus(); el.value=val;
          try{
            el.dispatchEvent(new Event('input',{bubbles:true}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
            var ev=document.createEvent('HTMLEvents'); ev.initEvent('keyup',true,false); el.dispatchEvent(ev);
          }catch(e){}
          return true;
        }
        function tryLogin(){
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var btn=document.getElementById('next');
          if(u&&p&&btn){
            setVal(u,'${_js(user)}');
            setVal(p,'${_js(pass)}');
            btn.click();
            return true;
          }
          return false;
        }
        if(!tryLogin()){
          var tries=0;
          var t=setInterval(function(){ tries++; if(tryLogin()||tries>50){clearInterval(t);} },100);
        }
      })();
    ''';
    await _c.runJavaScript(js);
  }

  String _js(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('`', r'\`');

  Future<void> _reload() => _c.reload();

  // ---------- Fahrzeug-Scan & Auswahl ----------
  Future<void> _ensureOnVehiclePage() async {
    if (!_lastUrl.contains('VehicleAppointments')) {
      await _c.loadRequest(Uri.parse(vehicleUrl));
      for (int i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (_lastUrl.contains('VehicleAppointments')) break;
      }
    }
  }

  Future<List<VehicleItem>> _scanVehiclesOnce() async {
    final js = r'''
      (function(){
        function clean(t){return (t||'').toString().replace(/\s+/g,' ').trim();}
        var root = document.getElementById('vehicleSelection');
        var out = [];
        if(!root){ return JSON.stringify({ok:false, reason:'no_element', list:[]}); }

        try{
          if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(root).dxSelectBox('instance');
            if(inst){
              var ds = inst.option('dataSource');
              var items = inst.option('items');
              var arr = [];
              if (Array.isArray(items)) arr = items;
              else if (ds && typeof ds.items === 'function') arr = ds.items();
              else if (ds && Array.isArray(ds._items)) arr = ds._items;
              var displayExpr = inst.option('displayExpr');
              if (Array.isArray(arr) && arr.length){
                for (var i=0;i<arr.length;i++){
                  var it = arr[i], label = '';
                  if (typeof displayExpr==='string' && it && typeof it==='object' && displayExpr in it){
                    label = clean(it[displayExpr]);
                  } else if (typeof displayExpr==='function'){
                    try { label = clean(displayExpr(it)); } catch(e){}
                  }
                  if (!label){
                    if (typeof it==='object'){
                      label = clean(it.text || it.name || it.label || it.title || it.value || it.id || ('Fahrzeug '+(i+1)));
                    } else label = clean(it);
                  }
                  out.push({label: label, index: i});
                }
                return JSON.stringify({ok:true, from:'items', list:out});
              }
            }
          }
        }catch(e){}

        try{
          if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst2 = jQuery(root).dxSelectBox('instance');
            if(inst2) inst2.option('opened', true);
          }
        }catch(e){}

        var nodes = root.querySelectorAll('.dx-selectbox-popup .dx-list-items .dx-item .dx-item-content');
        if(nodes.length===0){
          nodes = document.querySelectorAll('#vehicleSelection .dx-selectbox-popup .dx-item .dx-item-content, .dx-selectbox-popup .dx-item .dx-item-content');
        }
        for(var j=0;j<nodes.length;j++){
          var t = clean(nodes[j].textContent);
          if(t){ out.push({label:t, index:j}); }
        }
        return JSON.stringify({ok:true, from:'dom', list:out});
      })();
    ''';

    try {
      final res = await _c.runJavaScriptReturningResult(js);
      final jsonStr = res is String ? res : res.toString();
      final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list = (obj['list'] as List).cast<Map<String, dynamic>>();
      return list.map((m) => VehicleItem(label: m['label'] as String, index: (m['index'] as num).toInt())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<VehicleItem>> _scanVehiclesWithPolling() async {
    await _ensureOnVehiclePage();
    for (int i = 0; i < 20; i++) {
      final list = await _scanVehiclesOnce();
      if (list.isNotEmpty) return list;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    await _c.reload();
    for (int i = 0; i < 20; i++) {
      final list = await _scanVehiclesOnce();
      if (list.isNotEmpty) return list;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return [];
  }

  Future<String> _selectVehicle(VehicleItem v) async {
    final js = '''
      (function(){
        var idx = ${v.index};
        var root = document.getElementById('vehicleSelection');
        if(!root) return 'no_element';

        try{
          if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(root).dxSelectBox('instance');
            if(inst){
              var ds = inst.option('dataSource');
              var items = inst.option('items');
              var arr = [];
              if (Array.isArray(items)) arr = items;
              else if (ds && typeof ds.items === 'function') arr = ds.items();
              else if (ds && Array.isArray(ds._items)) arr = ds._items;

              if (Array.isArray(arr) && arr.length>idx){
                var item = arr[idx];
                try{ inst.option('selectedItem', item); }catch(e){}
                var sel = inst.option('selectedItem');
                if (sel===item) { try{ inst.option('opened', false);}catch(e){} return 'set_selectedItem'; }

                var valueExpr = inst.option('valueExpr');
                if (typeof valueExpr==='string' && item && item[valueExpr] !== undefined){
                  inst.option('value', item[valueExpr]);
                  try{ inst.option('opened', false);}catch(e){}
                  return 'set_valueExpr';
                }
              }
            }
          }
        }catch(e){}

        try{
          var inst2 = (window.jQuery && jQuery.fn.dxSelectBox) ? jQuery(root).dxSelectBox('instance') : null;
          try{ inst2 && inst2.option('opened', true); }catch(e){}
          var nodes = root.querySelectorAll('.dx-selectbox-popup .dx-list-items .dx-item');
          if(nodes.length>idx){
            nodes[idx].click();
            return 'clicked_dom';
          }
        }catch(e){}
        return 'failed';
      })();
    ''';

    try {
      final res = await _c.runJavaScriptReturningResult(js);
      return res.toString();
    } catch (_) {
      return 'error';
    }
  }

  // ---------- BottomSheets ----------
  Future<void> _startAutoFlow() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    _autoLaunchBottomSheet = false;
    try {
      final vehicles = await _scanVehiclesWithPolling();
      if (!mounted) return;
      if (vehicles.isEmpty) {
        await _openVehiclePickerSheet(const [], showEmptyHint: true);
      } else if (vehicles.length == 1) {
        await _selectVehicle(vehicles.first);
        await Future.delayed(const Duration(milliseconds: 250));
        await _openChargingSheet();
      } else {
        await _openVehiclePickerSheet(vehicles);
      }
    } finally {
      _sheetOpen = false;
    }
  }

  Future<void> _openVehiclePickerSheet(List<VehicleItem> vehicles, {bool showEmptyHint = false}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 44, height: 5, margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(3))),
                const Text('Fahrzeug auswählen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                if (showEmptyHint || vehicles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('Keine Fahrzeuge gefunden. Bitte neu laden.', textAlign: TextAlign.center),
                  ),
                if (vehicles.isNotEmpty)
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: vehicles.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (ctx, i) {
                        final v = vehicles[i];
                        return ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          tileColor: const Color(0xFFFFF3E8),
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFFEE7E1B),
                            child: Icon(Icons.directions_car, color: Colors.white),
                          ),
                          title: Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            await _selectVehicle(v);
                            await Future.delayed(const Duration(milliseconds: 250));
                            await _openChargingSheet();
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () { Navigator.of(ctx).pop(); },
                        icon: const Icon(Icons.close),
                        label: const Text('Schließen'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          final list = await _scanVehiclesWithPolling();
                          if (!mounted) return;
                          Navigator.of(ctx).pop();
                          await _openVehiclePickerSheet(list, showEmptyHint: list.isEmpty);
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Neu scannen'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openChargingSheet() async {
    final minutesCtrl = TextEditingController(text: '180'); // Standard: 3h
    bool busy = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        Future<void> start() async {
          if (busy) return;
          final minutes = minutesCtrl.text.trim();
          if (minutes.isEmpty) return;
          busy = true;

          final js = '''
            (function(){
              function toNum(x){var n=parseFloat(x); return isNaN(n)?0:n;}
              var m = toNum("$minutes");

              // DevExtreme-Button-Handler direkt
              try {
                if (window.jQuery) {
                  var inst = jQuery("#PostParametersButton").dxButton("instance");
                  if (inst) {
                    try {
                      var form = jQuery("#parameterform").dxForm("instance");
                      if (form) { try { form.updateData("Minutes", m); } catch(e){} }
                    } catch(e){}
                    var handler = inst.option("onClick");
                    if (typeof handler === "function") { handler({}); return "handler_called"; }
                  }
                }
              } catch(e){}

              // Fallback: direkte PostParameters(...)
              try {
                if (window.DevExpress && window.jQuery) {
                  var form = jQuery("#parameterform").dxForm("instance");
                  if (form) {
                    var eMin = form.getEditor("Minutes");
                    var eCR  = form.getEditor("CurrentRange");
                    if (eMin) { try { eMin.option("value", m); } catch(e){} }
                    try { form.updateData("Minutes", m); } catch(e){}

                    function toN(v){v=parseFloat(v);return isNaN(v)?0:v;}
                    var valMin = eMin ? toN(eMin.option("value")) : toN((document.querySelector("input[name='Minutes']")||{}).value) || m;
                    var minMin = eMin && eMin.option("min")!=null ? toN(eMin.option("min")) : 0.0;
                    var maxMin = eMin && eMin.option("max")!=null ? toN(eMin.option("max")) : 600.0;

                    var valCR  = eCR  ? toN(eCR.option("value")) : toN((document.querySelector("input[name='CurrentRange']")||{}).value);
                    var minCR  = eCR && eCR.option("min")!=null ? toN(eCR.option("min")) : 0.0;
                    var maxCR  = eCR && eCR.option("max")!=null ? toN(eCR.option("max")) : 10000.0;

                    if (typeof PostParameters === 'function') {
                      PostParameters({
                        "ManualControls":[{"SetPoints":[
                          {"Min":minCR,"Max":maxCR,"Value":valCR,"Format":"#0.0","Label":null,"ControlLabel":"Aktuelle Reichweite [km]","ReadOnly":true,"IsRequired":true,"Type":"RangeSetPoint","Id":"CurrentRange"},
                          {"Min":minMin,"Max":maxMin,"Value":valMin,"Format":"#0.0","Label":null,"ControlLabel":"Sofortladung mit voller Leistung für [minutes]","ReadOnly":false,"IsRequired":false,"Type":"RangeSetPoint","Id":"Minutes"}
                        ],"Label":null,"Id":"EV1"}]
                      });
                      return "called_PostParameters";
                    }
                  }
                }
              } catch(e){}

              // Letzter Fallback: Klick-Sequenz
              var btn = document.querySelector("#PostParametersButton");
              if (btn) {
                try { if (window.jQuery) jQuery(btn).trigger('dxclick'); } catch(e){}
                try { btn.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true})); } catch(e){}
                try { btn.dispatchEvent(new MouseEvent('pointerup',{bubbles:true})); } catch(e){}
                try { btn.click(); } catch(e){}
                return "clicked_btn";
              }
              return "no_button_found";
            })();
          ''';

          try {
            await _c.runJavaScript(js);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sofortladung für $minutes min gestartet')),
              );
            }
          } finally {
            busy = false;
            if (ctx.mounted) Navigator.of(ctx).pop(); // Sheet schließen
          }
        }

        return Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 44, height: 5, margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(3))),
                const Text('Sofort laden', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                TextField(
                  controller: minutesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Minuten', hintText: 'z. B. 180', border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () { Navigator.of(ctx).pop(); },
                        icon: const Icon(Icons.close),
                        label: const Text('Schließen'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: start,
                        icon: const Icon(Icons.flash_on),
                        label: const Text('Starten'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Optimizer'),
        leading: IconButton(
          tooltip: 'Start',
          icon: const Icon(Icons.apps),
          onPressed: () => setState(() {
            _autoLaunchBottomSheet = false; // manueller Aufruf
            _showHub = true;
          }),
        ),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Stack(
        children: [
          // WebView bleibt sichtbar im Hintergrund
          WebViewWidget(controller: _c),

          if (_loading) const LinearProgressIndicator(minHeight: 2),

          if (_showHub) const _HubOverlay(),
        ],
      ),
      floatingActionButton: _showHub
          ? FloatingActionButton.extended(
              onPressed: _startAutoFlow,
              icon: const Icon(Icons.ev_station),
              label: const Text('Auto'),
            )
          : FloatingActionButton(
              onPressed: _startAutoFlow,
              child: const Icon(Icons.ev_station),
            ),
    );
  }
}

/// ---------------- Startmenü-Overlay (nur „Auto“) ----------------
class _HubOverlay extends StatelessWidget {
  const _HubOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true, // nur visuell
      child: Container(
        color: Colors.transparent,
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundAction(
              icon: Icons.ev_station,
              label: 'Auto',
            ),
            const SizedBox(height: 8),
            const Text('Tippe auf den „Auto“-Button unten', style: TextStyle(color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final IconData icon;
  final String label;
  const _RoundAction({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFEE7E1B);
    return Container(
      width: 160, height: 160,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [orange, Color(0xFFFF9B3A)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 10)),
        ],
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(icon, size: 58, color: Colors.white),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
