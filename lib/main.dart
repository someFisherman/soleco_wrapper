import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const OptimizerApp());

/// Brandfarben – Kolibri (Orange als Primär, Petrol als Akzent)
class Brand {
  static const Color primary = Color(0xFFF28C00); // Kolibri-Orange
  static const Color primaryDark = Color(0xFFCC7600);
  static const Color petrol = Color(0xFF155D78);
  static const Color surface = Color(0xFFF7F8FA);
}

class OptimizerApp extends StatelessWidget {
  const OptimizerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.primary,
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'Optimizer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme.copyWith(
          primary: Brand.primary,
          secondary: Brand.petrol,
          surface: Brand.surface,
        ),
        scaffoldBackgroundColor: Brand.surface,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Brand.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const WebShell(),
    );
  }
}

/// ---------------- Secure storage keys ----------------
const _kUser = 'soleco_user';
const _kPass = 'soleco_pass';
const _kCookieStore = 'cookie_store_v1';

/// Kleiner Datentyp für Fahrzeuge
class VehicleItem {
  final String label;
  final int index;
  VehicleItem({required this.label, required this.index});
}

/// ---------------- Start-Shell: WebView + Overlays ----------------
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  static const String startVehicleUrl =
      'https://soleco-optimizer.ch/VehicleAppointments';
  static const String startViewsUrl = 'https://soleco-optimizer.ch/Views';

  final storage = const FlutterSecureStorage();
  final cookieMgr = WebviewCookieManager();

  late final WebViewController _main; // sichtbarer Controller

  bool _loading = true;
  bool _showStartMenu = true;
  bool _didAutoLogin = false;

  @override
  void initState() {
    super.initState();
    _initMainController();

    // Cookies laden und Start-URL öffnen
    Future.microtask(() async {
      await _restoreCookies();
      await _main.loadRequest(Uri.parse(startVehicleUrl));
    });
  }

  // ---------- Controller ----------
  void _initMainController() {
    _main = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (url) async {
            setState(() => _loading = false);

            // B2C Login?
            if (await _isB2CLoginDom()) {
              if (!_didAutoLogin) {
                _didAutoLogin = true;
                await _autoLoginB2C();
              }
              await _persistCookies(url);
              return;
            }

            // Vehicle-Appointments / Views -> Cookies sichern
            if (url.contains('/VehicleAppointments') || url.contains('/Views')) {
              await _persistCookies(url);
              return;
            }

            await _persistCookies(url);
          },
          onNavigationRequest: (req) {
            final u = req.url;
            if (u.startsWith('tel:') || u.startsWith('mailto:')) {
              launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  // ---------- Cookies ----------
  Future<void> _restoreCookies() async {
    final raw = await storage.read(key: _kCookieStore);
    if (raw == null) return;
    final map = jsonDecode(raw) as Map<String, dynamic>; // domain -> List<Map>
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
      final raw = await storage.read(key: _kCookieStore);
      final Map<String, List<Map<String, dynamic>>> store =
          raw == null
              ? {}
              : (jsonDecode(raw) as Map).map(
                  (k, v) => MapEntry(
                    k as String,
                    (v as List).cast<Map>().cast<Map<String, dynamic>>(),
                  ),
                );

      for (final c in cookies) {
        final domain = c.domain ?? uri.host;
        store.putIfAbsent(domain, () => []);
        final list = store[domain]!;
        final idx = list.indexWhere(
            (m) => m['name'] == c.name && m['path'] == (c.path ?? '/'));
        final m = {
          'name': c.name,
          'value': c.value,
          'path': c.path ?? '/',
          'secure': c.secure ?? true,
        };
        if (idx >= 0) {
          list[idx] = m;
        } else {
          list.add(m);
        }
      }
      await storage.write(key: _kCookieStore, value: jsonEncode(store));
    } catch (_) {}
  }

  // ---------- B2C Auto-Login ----------
  Future<bool> _isB2CLoginDom() async {
    try {
      final res = await _main.runJavaScriptReturningResult('''
        (function(){
          var f=document.getElementById('localAccountForm');
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var n=document.getElementById('next');
          return !!(f&&u&&p&&n);
        })();
      ''');
      return res.toString() == 'true' || res.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> _autoLoginB2C() async {
    final user = await storage.read(key: _kUser);
    final pass = await storage.read(key: _kPass);
    if (user == null || pass == null) return;
    final esc = (String s) =>
        s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('`', r'\`');

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
            setVal(u,'${esc(user)}');
            setVal(p,'${esc(pass)}');
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
    await _main.runJavaScript(js);
  }

  // ---------- Fahrzeug-Ermittlung & Auswahl ----------
  Future<List<VehicleItem>> _scanVehiclesOnce() async {
    const js = r'''
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
                  if (typeof displayExpr === 'string' && it && typeof it === 'object' && displayExpr in it){
                    label = clean(it[displayExpr]);
                  } else if (typeof displayExpr === 'function'){
                    try { label = clean(displayExpr(it)); } catch(e){}
                  }
                  if (!label){
                    if (typeof it === 'object'){
                      label = clean(it.text || it.name || it.label || it.title || it.value || it.id || ('Fahrzeug '+(i+1)));
                    } else {
                      label = clean(it);
                    }
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
      final res = await _main.runJavaScriptReturningResult(js);
      final jsonStr = res is String ? res : res.toString();
      final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list = (obj['list'] as List).cast<Map<String, dynamic>>();
      return list
          .map((m) =>
              VehicleItem(label: m['label'] as String, index: (m['index'] as num).toInt()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<VehicleItem>> _scanVehiclesWithPolling() async {
    // etwas warten, bis die Seite wirklich steht
    for (int i = 0; i < 20; i++) {
      final list = await _scanVehiclesOnce();
      if (list.isNotEmpty) return list;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    // einmal reload versuchen
    await _main.reload();
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
      final res = await _main.runJavaScriptReturningResult(js);
      return res.toString();
    } catch (_) {
      return 'error';
    }
  }

  // ---------- Startmenü-Aktion: nur „Auto“ ----------
  Future<void> _openAuto() async {
    setState(() => _showStartMenu = false);
    await _main.loadRequest(Uri.parse(startVehicleUrl));

    // Fahrzeuge ermitteln (automatisch neu scannen, falls leer)
    final vehicles = await _scanVehiclesWithPolling();

    // 1 Fahrzeug -> direkt wählen und sofort Laden-Sheet
    if (vehicles.length == 1) {
      await _selectVehicle(vehicles.first);
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      _openChargingSheet();
      return;
    }

    // mehrere Fahrzeuge -> Auswahl-Sheet
    if (vehicles.length > 1) {
      if (!mounted) return;
      final chosen = await showModalBottomSheet<VehicleItem>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _VehiclePickerSheet(
          items: vehicles,
          onRescan: () async {
            final v2 = await _scanVehiclesWithPolling();
            return v2;
          },
        ),
      );
      if (!mounted) return;
      if (chosen != null) {
        await _selectVehicle(chosen);
        await Future.delayed(const Duration(milliseconds: 250));
        _openChargingSheet();
      } else {
        // abgebrochen -> Startmenü wieder zeigen
        setState(() => _showStartMenu = true);
      }
      return;
    }

    // keine Fahrzeuge gefunden -> trotzdem Sheet anzeigen (wir lassen den Nutzer Zeit wählen)
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kein Fahrzeug gefunden – bitte Fahrzeugauswahl in der Seite prüfen.')),
      );
      _openChargingSheet();
    }
  }

  void _openChargingSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ChargingSheet(
        defaultMinutes: 180,
        webViewController: _main,
        onStart: (minutes) async {
          await _triggerParameters(minutes);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sofortladung gestartet (${minutes} min)')),
          );
        },
      ),
    );
  }

  // ---------- Parameter aktivieren ----------
  Future<void> _triggerParameters(int minutes) async {
    final js = '''
      (function(){
        function toNum(x){var n=parseFloat(x); return isNaN(n)?0:n;}
        var m = toNum("$minutes");

        try {
          if (window.DevExpress && window.jQuery) {
            var form = jQuery("#parameterform").dxForm("instance");
            if (form) {
              var eMin = form.getEditor("Minutes");
              if (eMin) { try { eMin.option("value", m); } catch(e){} }
              try { form.updateData("Minutes", m); } catch(e){}
              var eCR  = form.getEditor("CurrentRange");
              var valCR  = eCR  ? toNum(eCR.option("value")) :
                           toNum((document.querySelector("input[name='CurrentRange']")||{}).value);
              var minCR  = eCR && eCR.option("min")!=null ? toNum(eCR.option("min")) : 0.0;
              var maxCR  = eCR && eCR.option("max")!=null ? toNum(eCR.option("max")) : 10000.0;

              var valMin = eMin ? toNum(eMin.option("value")) :
                           (toNum((document.querySelector("input[name='Minutes']")||{}).value) || m);
              var minMin = eMin && eMin.option("min")!=null ? toNum(eMin.option("min")) : 0.0;
              var maxMin = eMin && eMin.option("max")!=null ? toNum(eMin.option("max")) : 600.0;

              if (typeof PostParameters === 'function') {
                PostParameters({
                  "ManualControls":[{"SetPoints":[
                    {"Min":minCR,"Max":maxCR,"Value":valCR,"Format":"#0.0","Label":null,"ControlLabel":"Aktuelle Reichweite [km]","ReadOnly":true,"IsRequired":true,"Type":"RangeSetPoint","Id":"CurrentRange"},
                    {"Min":minMin,"Max":maxMin,"Value":valMin,"Format":"#0.0","Label":null,"ControlLabel":"Sofortladung mit voller Leistung für [minutes]","ReadOnly":false,"IsRequired":false,"Type":"RangeSetPoint","Id":"Minutes"}
                  ],"Label":null,"Id":"EV1"}]
                });
                return "ok";
              }
            }
          }
        } catch(e){}

        try {
          var hidden = document.querySelector("input[name='Minutes']");
          if (hidden) hidden.value = m;
          var vis = document.querySelector("input#Minutes, input.dx-texteditor-input");
          if (vis) {
            vis.value = m;
            try {
              vis.dispatchEvent(new Event('input',{bubbles:true}));
              vis.dispatchEvent(new Event('change',{bubbles:true}));
              var ev=document.createEvent('HTMLEvents'); ev.initEvent('keyup',true,false); vis.dispatchEvent(ev);
            } catch(e){}
          }
          var btn = document.querySelector("#PostParametersButton");
          if (btn) {
            try { if (window.jQuery) jQuery(btn).trigger('dxclick'); } catch(e){}
            try { btn.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true})); } catch(e){}
            try { btn.dispatchEvent(new MouseEvent('pointerup',{bubbles:true})); } catch(e){}
            try { btn.click(); } catch(e){}
            return "clicked";
          }
        } catch(e){}

        return "fail";
      })();
    ''';
    await _main.runJavaScript(js);
  }

  // ---------- UI ----------
  Future<void> _openCredentials() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const CredsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Optimizer', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Startmenü',
            onPressed: () => setState(() => _showStartMenu = !_showStartMenu),
            icon: const Icon(Icons.local_florist_outlined, color: Brand.primary),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'views') {
                setState(() => _showStartMenu = false);
                await _main.loadRequest(Uri.parse(startViewsUrl));
              } else if (v == 'vehicle') {
                await _openAuto();
              } else if (v == 'creds') {
                await _openCredentials();
              } else if (v == 'logout') {
                await storage.delete(key: _kUser);
                await storage.delete(key: _kPass);
                await storage.delete(key: _kCookieStore);
                await _main.clearCache();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Abgemeldet.')),
                  );
                }
                await _main.loadRequest(
                    Uri.parse('https://soleco-optimizer.ch/Account/SignOut'));
                _didAutoLogin = false;
                setState(() => _showStartMenu = true);
              }
            },
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'views', child: Text('Zu Ansichten')),
              PopupMenuItem(value: 'vehicle', child: Text('Zu Fahrzeuge')),
              PopupMenuItem(value: 'creds', child: Text('Login speichern/ändern')),
              PopupMenuItem(value: 'logout', child: Text('Abmelden')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _main),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_showStartMenu) const _StartOverlay(),
        ],
      ),
      floatingActionButton: _showStartMenu
          ? null
          : FloatingActionButton.extended(
              onPressed: () => setState(() => _showStartMenu = true),
              backgroundColor: Brand.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.home),
              label: const Text('Start'),
            ),
      bottomSheet: _showStartMenu
          ? StartMenu(
              onAuto: _openAuto,
            )
          : null,
    );
  }
}

/// Startmenü – schwebende Karte unten (nur noch „Auto“)
class StartMenu extends StatelessWidget {
  final VoidCallback onAuto;
  const StartMenu({super.key, required this.onAuto});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(blurRadius: 24, color: Colors.black12, offset: Offset(0, 8))
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Schnellstart',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Row(
              children: [
                _RoundAction(
                  label: 'Auto',
                  icon: Icons.ev_station,
                  onTap: onAuto,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _RoundAction(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(120),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Brand.primary, Brand.primaryDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: const [
                  BoxShadow(
                      blurRadius: 24, color: Colors.black26, offset: Offset(0, 10)),
                ],
              ),
              child: Icon(icon, size: 46, color: Colors.white),
            ),
            const SizedBox(height: 10),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// zartes Overlay-Hintergrundmuster
class _StartOverlay extends StatelessWidget {
  const _StartOverlay();
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.transparent, Color(0x11F28C00)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      ),
    );
  }
}

/// ---- Login speichern / ändern ----
class CredsScreen extends StatefulWidget {
  const CredsScreen({super.key});
  @override
  State<CredsScreen> createState() => _CredsScreenState();
}

class _CredsScreenState extends State<CredsScreen> {
  final storage = const FlutterSecureStorage();
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      _user.text = (await storage.read(key: _kUser)) ?? '';
      _pass.text = (await storage.read(key: _kPass)) ?? '';
      setState(() {});
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    await storage.write(key: _kUser, value: _user.text.trim());
    await storage.write(key: _kPass, value: _pass.text);
    setState(() => _busy = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Login gespeichert.')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login speichern')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            children: [
              TextFormField(
                controller: _user,
                decoration: const InputDecoration(
                    labelText: 'Benutzername', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Benutzername erforderlich' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Passwort', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Passwort erforderlich' : null,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_busy ? 'Speichere…' : 'Speichern'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ---- Fahrzeugauswahl (Bottom Sheet) ----
class _VehiclePickerSheet extends StatefulWidget {
  final List<VehicleItem> items;
  final Future<List<VehicleItem>> Function() onRescan;

  const _VehiclePickerSheet({
    required this.items,
    required this.onRescan,
  });

  @override
  State<_VehiclePickerSheet> createState() => _VehiclePickerSheetState();
}

class _VehiclePickerSheetState extends State<_VehiclePickerSheet> {
  late List<VehicleItem> _list = widget.items;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          const Text('Fahrzeug auswählen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('${_list.length} gefunden', style: const TextStyle(color: Colors.black54)),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : () async {
                  setState(() => _busy = true);
                  try {
                    final v2 = await widget.onRescan();
                    if (mounted) setState(() => _list = v2);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Neu scannen'),
              )
            ],
          ),
          const SizedBox(height: 6),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final v = _list[i];
                return ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  tileColor: Colors.orange.shade50,
                  leading: CircleAvatar(
                    backgroundColor: Brand.primary,
                    child: const Icon(Icons.directions_car, color: Colors.white),
                  ),
                  title: Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, v),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// ---- Neues Charging Interface mit Slider und PageView ----
class ChargingSheet extends StatefulWidget {
  final int defaultMinutes;
  final WebViewController webViewController;
  final Future<void> Function(int minutes) onStart;
  const ChargingSheet({
    super.key,
    required this.defaultMinutes,
    required this.webViewController,
    required this.onStart,
  });

  @override
  State<ChargingSheet> createState() => _ChargingSheetState();
}

class _ChargingSheetState extends State<ChargingSheet> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  double _chargePercentage = 80.0; // Standard 80%
  bool _busy = false;

  // Quick Charge Daten
  int _currentRange = 0;
  int _maxRange = 0;
  int _calculatedMinutes = 0;
  bool _hasRealData = false;

  @override
  void initState() {
    super.initState();
    _loadVehicleData();
  }

  Future<void> _loadVehicleData() async {
    try {
      setState(() => _busy = true);
      
      print('🔄 Loading vehicle data from both pages...');
      
      int currentRange = 0;
      int maxRange = 0;
      
      // 1. Lade Current Range von der Views-Seite
      print('📊 Loading current range from Views page...');
      final currentUrl = await widget.webViewController.currentUrl();
      if (currentUrl == null || !currentUrl.contains('/Views')) {
        print('🔄 Switching to Views page for current range...');
        await widget.webViewController.loadRequest(Uri.parse('https://soleco-optimizer.ch/Views'));
        await Future.delayed(const Duration(seconds: 2));
      }
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final currentRangeJs = '''
        (function(){
          console.log('🔍 Searching for current range on Views page...');
          
          // Suche nach SVG-Text-Elementen mit km-Werten
          var svgTexts = document.querySelectorAll('text[id*="text860"], text[id*="tspan858"]');
          console.log('Found ' + svgTexts.length + ' SVG text elements');
          
          for (var i = 0; i < svgTexts.length; i++) {
            var text = svgTexts[i].textContent.trim();
            console.log('SVG text content: "' + text + '"');
            
            // Suche nach km-Werten
            var match = text.match(/(\d+)\s*km/i);
            if (match) {
              var value = parseInt(match[1]);
              console.log('Found km value: ' + value);
              
              // Erste gefundene Zahl ist wahrscheinlich current range (kleinere Zahl)
              if (value > 50 && value < 500) {
                console.log('✅ Current Range: ' + value + ' km');
                return value;
              }
            }
          }
          
          // Fallback: Suche nach allen Text-Elementen mit km
          var allTexts = document.querySelectorAll('text, span, div, p');
          for (var i = 0; i < allTexts.length; i++) {
            var text = allTexts[i].textContent.trim();
            var match = text.match(/(\d+)\s*km/i);
            if (match) {
              var value = parseInt(match[1]);
              if (value > 50 && value < 500) {
                console.log('✅ Current Range (fallback): ' + value + ' km');
                return value;
              }
            }
          }
          
          console.log('❌ No current range found');
          return null;
        })();
      ''';
      
      final currentRangeResult = await widget.webViewController.runJavaScriptReturningResult(currentRangeJs);
      currentRange = int.tryParse(currentRangeResult.toString()) ?? 0;
      print('📊 Current Range Result: $currentRange');
      
      // 2. Lade Max Range von der Settings/VehiclesConfig-Seite
      print('📊 Loading max range from Settings/VehiclesConfig page...');
      await widget.webViewController.loadRequest(Uri.parse('https://soleco-optimizer.ch/Settings/VehiclesConfig'));
      await Future.delayed(const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 500));
      
      final maxRangeJs = '''
        (function(){
          console.log('🔍 Searching for max range on Settings/VehiclesConfig page...');
          
          // Suche nach DistanceMax Input-Feld
          var selectors = [
            'input[name="DistanceMax"]',
            'input[id*="DistanceMax"]',
            'input[aria-valuenow]',
            '.dx-numberbox input[value]',
            'input[type="hidden"][name="DistanceMax"]'
          ];
          
          for (var i = 0; i < selectors.length; i++) {
            var inputs = document.querySelectorAll(selectors[i]);
            console.log('Selector ' + selectors[i] + ' found ' + inputs.length + ' elements');
            for (var j = 0; j < inputs.length; j++) {
              var input = inputs[j];
              var value = input.value || input.getAttribute('aria-valuenow') || input.getAttribute('value');
              if (value && !isNaN(parseInt(value))) {
                var num = parseInt(value);
                if (num > 200 && num < 1000) { // Realistische Max Range
                  console.log('✅ Max Range gefunden: ' + num + ' with selector: ' + selectors[i]);
                  return num;
                }
              }
            }
          }
          
          console.log('❌ No max range found');
          return null;
        })();
      ''';
      
      final maxRangeResult = await widget.webViewController.runJavaScriptReturningResult(maxRangeJs);
      maxRange = int.tryParse(maxRangeResult.toString()) ?? 0;
      print('📊 Max Range Result: $maxRange');
      
      // 3. Setze die gefundenen Werte
      if (currentRange > 0 && maxRange > 0) {
        setState(() {
          _currentRange = currentRange;
          _maxRange = maxRange;
          _hasRealData = true;
        });
        print('✅ Echte Fahrzeugdaten geladen: Current: $currentRange km (Views), Max: $maxRange km (Settings/VehiclesConfig)');
        
        // Berechne automatisch die Minuten basierend auf 80% Ladung
        _calculateMinutes();
        
        // Zeige Erfolgs-Snackbar
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Fahrzeugdaten geladen: ${currentRange}km / ${maxRange}km'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        setState(() {
          _currentRange = 0;
          _maxRange = 0;
          _hasRealData = false;
        });
        print('❌ Keine gültigen Fahrzeugdaten gefunden');
        
        // Zeige Fehler
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Keine Fahrzeugdaten gefunden'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      
    } catch (e) {
      print('❌ Fehler beim Laden der Fahrzeugdaten: $e');
      setState(() {
        _currentRange = 0;
        _maxRange = 0;
        _hasRealData = false;
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  void _calculateMinutes() {
    if (!_hasRealData || _currentRange == 0 || _maxRange == 0) {
      _calculatedMinutes = 0;
      return;
    }
    
    final targetRange = (_maxRange * _chargePercentage / 100).round();
    final rangeToCharge = targetRange - _currentRange;
    
    if (rangeToCharge <= 0) {
      _calculatedMinutes = 0;
      return;
    }
    
    // 11kW Ladeleistung: 1 km = 1.15 Minuten (basierend auf 11kW)
    // Plus 1 Minute pro 15 Minuten (wie vom User gewünscht)
    final baseMinutes = (rangeToCharge * 1.15).round();
    final extraMinutes = (baseMinutes / 15).round(); // 1 Minute pro 15 Minuten
    _calculatedMinutes = (baseMinutes + extraMinutes).clamp(0, 600);
    
    // Setze die berechneten Minuten in das Textfeld
    _minCtrl.text = _calculatedMinutes.toString();
  }

  Widget _buildMainSlider() {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: Brand.primary,
        inactiveTrackColor: Brand.primary.withOpacity(0.3),
        thumbColor: Colors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 16),
        trackHeight: 8,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
      ),
      child: Slider(
        value: _chargePercentage,
        min: 0,
        max: 100,
        divisions: 100,
        onChanged: (value) {
          setState(() {
            _chargePercentage = value;
          });
          _calculateQuickCharge();
        },
      ),
    );
  }

  Widget _buildPageIndicator(int index) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _currentPage == index ? Brand.primary : Colors.grey[300],
      ),
    );
  }

  Widget _buildPlannedPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Planned',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          
          // Day Slider
          const Text(
            'Days',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _buildDaySelector(),
          
          const SizedBox(height: 24),
          
          // Time Slider
          const Text(
            'Time',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _buildTimeSelector(),
          
          const Spacer(),
          
          // Start Button (blockiert)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Start (Coming Soon)',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildDaySelector() {
    final days = ['Today', 'Tomorrow', 'In 2 Days', 'In 3 Days'];
    return Container(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        itemBuilder: (context, index) {
          return Container(
            margin: const EdgeInsets.only(right: 12),
            child: ChoiceChip(
              label: Text(days[index]),
              selected: index == 0, // Default: Today
              onSelected: (selected) {
                // Funktion kommt später
              },
              selectedColor: Brand.primary.withOpacity(0.2),
              labelStyle: TextStyle(
                color: index == 0 ? Brand.primary : Colors.grey[600],
                fontWeight: index == 0 ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTimeSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: const Text(
        'Time selection will adapt based on day choice',
        style: TextStyle(
          color: Colors.grey,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Widget _buildQuickChargePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Quick Charge',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                onPressed: () async {
                  await _loadVehicleData();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Fahrzeugdaten wurden neu geladen'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.refresh),
                tooltip: 'Daten neu laden',
              ),
            ],
          ),
          const SizedBox(height: 24),
          
          // Vehicle Info
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Brand.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Current Range:'),
                    Text('$_currentRange km', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Max Range:'),
                    Text('$_maxRange km', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Target Range:'),
                    Text('${(_maxRange * _chargePercentage / 100).round()} km', 
                         style: const TextStyle(fontWeight: FontWeight.bold, color: Brand.primary)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _hasRealData 
                    ? '✅ Echte Fahrzeugdaten geladen' 
                    : '❌ Keine Daten verfügbar - bitte Views-Seite laden',
                  style: TextStyle(
                    fontSize: 12,
                    color: _hasRealData ? Colors.green : Colors.red,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Calculation Result
          if (_calculatedMinutes > 0) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  const Text(
                    'Berechnung:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Range to charge: ${((_maxRange * _chargePercentage / 100) - _currentRange).round()} km',
                    style: const TextStyle(fontSize: 14),
                  ),
                  Text(
                    'Charging rate: 11kW',
                    style: const TextStyle(fontSize: 14),
                  ),
                  Text(
                    'Estimated time: $_calculatedMinutes minutes',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          
          // Quick Charge Button
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || !_hasRealData || _calculatedMinutes == 0) ? null : () {
                // Für Test: Nur Berechnung anzeigen
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Quick Charge würde $_calculatedMinutes Minuten laden (11kW)'),
                    backgroundColor: Brand.primary,
                  ),
                );
                  },
            icon: const Icon(Icons.flash_on),
              label: Text(_busy ? 'Berechne...' : 
                         !_hasRealData ? 'Keine Daten' : 
                         _calculatedMinutes == 0 ? 'Bereit' : 'Quick Charge'),
              style: FilledButton.styleFrom(
                backgroundColor: (_busy || !_hasRealData || _calculatedMinutes == 0) 
                    ? Colors.grey 
                    : Brand.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
