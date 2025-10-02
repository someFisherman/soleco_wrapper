import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// --- Fahrzeug-Datentyp ---
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
    return MaterialApp(
      title: 'Optimizer',
      theme: ThemeData(
        useMaterial3: true,
        // Kolibri-Farben (frisches Türkis/Teal)
        colorSchemeSeed: const Color(0xFF00AFA3),
        brightness: Brightness.light,
      ),
      home: const WebShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// ---------------- Gate (Zugangsdaten einmalig speichern) ----------------
class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  final storage = const FlutterSecureStorage();
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    await storage.write(key: 'soleco_user', value: _user.text.trim());
    await storage.write(key: 'soleco_pass', value: _pass.text);
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop(); // zurück zur App
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Login-Daten gespeichert')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Optimizer – Login speichern')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            children: [
              const Text('Benutzername & Passwort einmalig speichern – die App loggt dich dann automatisch ein.'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'Benutzername', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Benutzername erforderlich' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Passwort', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.isEmpty) ? 'Passwort erforderlich' : null,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_busy ? 'Speichere…' : 'Speichern'),
              )
            ],
          ),
        ),
      ),
    );
  }
}

/// ---------------- WebShell (WebView + Auto-Login + Start-Hub + BottomSheet) ----------------
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

  // Start-Overlay (nur „Auto“) soll sichtbar bleiben
  bool _showHub = true;

  // Einmaliges automatisches Öffnen des BottomSheets nach erstem Erreichen der Fahrzeugseite
  bool _autoSheetOpened = false;

  bool _didAutoLogin = false;
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

            // B2C-Login erkannt? -> einmal Auto-Login
            if (await _isB2CLoginDom()) {
              if (!_didAutoLogin) {
                _didAutoLogin = true;
                await _autoLoginB2C();
              }
            }

            // Eingeloggt (Vehicle-Seite)?
            if (url.contains('VehicleAppointments')) {
              await _persistCookies(url);

              // Start-Hub bleibt sichtbar; BottomSheet beim ersten Mal automatisch öffnen
              if (!_autoSheetOpened) {
                _autoSheetOpened = true;
                if (mounted) _openAutoBottomSheet();
              }
              return;
            }

            // Sonst Cookies mitschreiben
            await _persistCookies(url);
          },

          onNavigationRequest: (req) {
            final u = req.url;

            // HTML-Menü: Abmelden abfangen
            if (u.startsWith('https://soleco-optimizer.ch/Account/SignOut') ||
                u.contains('/Account/SignOut')) {
              Future.microtask(() async => _performSignOutAndGotoLogin());
              return NavigationDecision.prevent;
            }

            // Tel/Mail extern
            if (u.startsWith('tel:') || u.startsWith('mailto:')) {
              launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    // Cookies wiederherstellen und Fahrzeug-Seite laden
    Future.microtask(() async {
      await _restoreCookies();
      await _c.loadRequest(Uri.parse(vehicleUrl));
    });
  }

  // ---- Signout & Login ----
  Future<void> _performSignOutAndGotoLogin() async {
    try {
      await cookieMgr.clearCookies();
      try {
        await _c.runJavaScript('try{localStorage.clear();sessionStorage.clear();}catch(e){}');
      } catch (_) {}
      await storage.delete(key: _cookieStoreKey);
    } catch (_) {}
    setState(() {
      _didAutoLogin = false;
      _autoSheetOpened = false;
      _showHub = true;
    });
    await _c.loadRequest(Uri.parse(vehicleUrl)); // führt zum B2C-Login
  }

  // ---- Cookies ----
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
        if (idx >= 0) {
          list[idx] = m;
        } else {
          list.add(m);
        }
      }
      await storage.write(key: _cookieStoreKey, value: jsonEncode(store));
    } catch (_) {}
  }

  // ---- B2C Auto-Login ----
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
    } catch (_) {
      return false;
    }
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

  // ---------- Vehicle scan & select ----------
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
    const js = r'''
      (function(){
        function clean(t){return (t||'').toString().replace(/\s+/g,' ').trim();}
        var root = document.getElementById('vehicleSelection');
        var out = [];
        if(!root){ return JSON.stringify({ok:false, list:[]}); }

        // Versuche es über DevExtreme-API
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
                  out.push({label: label || ('Fahrzeug '+(i+1)), index: i});
                }
                return JSON.stringify({ok:true, list:out});
              }
            }
          }
        }catch(e){}

        // Notfalls Overlay öffnen und DOM lesen
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
          out.push({label: t || ('Fahrzeug '+(j+1)), index: j});
        }
        return JSON.stringify({ok:true, list:out});
      })();
    ''';

    try {
      final res = await _c.runJavaScriptReturningResult(js);
      final jsonStr = res is String ? res : res.toString();
      final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list = (obj['list'] as List).cast<Map<String, dynamic>>();
      return list
          .map((m) => VehicleItem(label: (m['label'] as String?)?.trim().isNotEmpty == true ? m['label'] as String : 'Fahrzeug', index: (m['index'] as num).toInt()))
          .toList();
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

  // ---------- BottomSheet öffnen ----------
  Future<void> _openAutoBottomSheet() async {
    // Sicherstellen, dass wir auf der Fahrzeugseite sind und Fahrzeuge laden
    final vehicles = await _scanVehiclesWithPolling();

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      builder: (ctx) {
        return _VehicleAndChargeSheet(
          initialVehicles: vehicles,
          onRescan: () async => await _scanVehiclesWithPolling(),
          onSelectVehicle: (v) => _selectVehicle(v),
          onRunJs: (code) => _c.runJavaScript(code),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Optimizer'),
        leading: IconButton(
          tooltip: 'Start',
          icon: const Icon(Icons.ev_station),
          onPressed: _openAutoBottomSheet, // direkt das BottomSheet
        ),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
          IconButton(
            tooltip: 'Login speichern/ändern',
            icon: const Icon(Icons.manage_accounts),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const Gate()));
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Webseite im Hintergrund
          WebViewWidget(controller: _c),

          if (_loading) const LinearProgressIndicator(minHeight: 2),

          // Start-Hub (nur „Auto“) – bleibt sichtbar
          IgnorePointer(
            ignoring: false,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: _showHub ? 1 : 0,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _RoundAction(
                    icon: Icons.ev_station,
                    label: 'Auto',
                    color: cs.primary,
                    onTap: _openAutoBottomSheet,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Runde Start-Aktion (nur „Auto“). Wichtig: Icon NICHT const (sonst Buildfehler).
class _RoundAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _RoundAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 100,
      child: Container(
        width: 140,
        height: 140,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(.18), blurRadius: 18, offset: const Offset(0, 8)),
          ],
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 58, color: Colors.white), // <- NICHT const
            const SizedBox(height: 8),
            const Text(
              'Auto',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------------- BottomSheet: Fahrzeug wählen + Minuten laden ----------------
class _VehicleAndChargeSheet extends StatefulWidget {
  final List<VehicleItem> initialVehicles;
  final Future<List<VehicleItem>> Function() onRescan;
  final Future<String> Function(VehicleItem v) onSelectVehicle;
  final Future<void> Function(String js) onRunJs;

  const _VehicleAndChargeSheet({
    required this.initialVehicles,
    required this.onRescan,
    required this.onSelectVehicle,
    required this.onRunJs,
  });

  @override
  State<_VehicleAndChargeSheet> createState() => _VehicleAndChargeSheetState();
}

class _VehicleAndChargeSheetState extends State<_VehicleAndChargeSheet> {
  late List<VehicleItem> _vehicles;
  VehicleItem? _selected;
  final _minutesCtrl = TextEditingController(text: '30');
  bool _busy = false;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _vehicles = widget.initialVehicles;
    if (_vehicles.length == 1) _selected = _vehicles.first;
  }

  Future<void> _rescan() async {
    setState(() {
      _busy = true;
      _hint = null;
    });
    final list = await widget.onRescan();
    if (!mounted) return;
    setState(() {
      _vehicles = list;
      if (_vehicles.length == 1) {
        _selected = _vehicles.first;
      } else if (_selected != null && _selected!.index >= _vehicles.length) {
        _selected = null;
      }
      _busy = false;
      if (_vehicles.isEmpty) _hint = 'Keine Fahrzeuge gefunden. Bitte neu scannen.';
    });
  }

  Future<void> _startCharging() async {
    final minutes = int.tryParse(_minutesCtrl.text.trim());
    if (_selected == null) {
      setState(() => _hint = 'Bitte zuerst ein Fahrzeug wählen.');
      return;
    }
    if (minutes == null || minutes < 0) {
      setState(() => _hint = 'Bitte gültige Minuten eingeben (z. B. 30).');
      return;
    }

    setState(() {
      _busy = true;
      _hint = null;
    });

    // 1) Fahrzeug im Web selektieren
    final res = await widget.onSelectVehicle(_selected!);
    await Future.delayed(const Duration(milliseconds: 250));

    // 2) Minuten setzen + „Parameter aktivieren“ triggern (robust)
    final js = '''
      (function(){
        function toNum(x){var n=parseFloat(x); return isNaN(n)?0:n;}
        var m = toNum("$minutes");

        // DevExtreme Button-Handler bevorzugt
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
              var valMin = eMin ? toN(eMin.option("value")) :
                           toN((document.querySelector("input[name='Minutes']")||{}).value) || m;
              var minMin = eMin && eMin.option("min")!=null ? toN(eMin.option("min")) : 0.0;
              var maxMin = eMin && eMin.option("max")!=null ? toN(eMin.option("max")) : 600.0;

              var valCR  = eCR  ? toN(eCR.option("value")) :
                           toN((document.querySelector("input[name='CurrentRange']")||{}).value);
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

    await widget.onRunJs(js);

    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop(); // BottomSheet schließen
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sofortladung für ${minutes} min gestartet (${res})')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        top: 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Titelzeile
          Row(
            children: [
              Icon(Icons.ev_station, color: cs.primary),
              const SizedBox(width: 8),
              const Text('Fahrzeug & Sofortladung', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                tooltip: 'Neu scannen',
                onPressed: _busy ? null : _rescan,
                icon: const Icon(Icons.refresh),
              )
            ],
          ),
          const SizedBox(height: 12),

          // Fahrzeugliste
          if (_vehicles.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: const [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Suche Fahrzeuge…'),
                ],
              ),
            ),
          if (_vehicles.isNotEmpty)
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _vehicles.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (ctx, i) {
                    final v = _vehicles[i];
                    final sel = _selected?.index == v.index;
                    return ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      tileColor: sel ? cs.primaryContainer : cs.surfaceContainerHighest,
                      leading: CircleAvatar(
                        backgroundColor: sel ? cs.primary : cs.secondary,
                        child: const Icon(Icons.directions_car, color: Colors.white),
                      ),
                      title: Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: sel ? const Icon(Icons.check_circle, color: Colors.white) : const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () {
                              setState(() => _selected = v);
                            },
                    );
                  },
                ),
              ),
            ),

          const SizedBox(height: 12),

          // Minutenfeld
          TextField(
            controller: _minutesCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Minuten',
              hintText: 'z. B. 30',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 12),

          // Hinweis / Fehler
          if (_hint != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_hint!, style: TextStyle(color: Theme.of(context).colorScheme.error))),

          // Start-Button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _startCharging,
              icon: const Icon(Icons.flash_on),
              label: Text(_busy ? 'Bitte warten…' : 'Sofortladen starten'),
            ),
          ),
        ],
      ),
    );
  }
}
