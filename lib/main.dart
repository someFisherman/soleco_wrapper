import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

/// --- Datentyp für die Fahrzeugliste (bewusst ganz oben, damit überall bekannt) ---
class VehicleItem {
  final String label; // z. B. "Audi Q6"
  final int index;    // Position in der dxSelectBox
  VehicleItem({required this.label, required this.index});
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soleco',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const WebShell(),
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
  bool? hasCreds;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final u = await storage.read(key: 'soleco_user');
    final p = await storage.read(key: 'soleco_pass');
    setState(() => hasCreds = (u?.isNotEmpty == true && p?.isNotEmpty == true));
  }

  @override
  Widget build(BuildContext context) {
    if (hasCreds == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (hasCreds == true) return const WebShell();
    return CredsScreen(onSaved: () => setState(() => hasCreds = true));
  }
}

class CredsScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const CredsScreen({super.key, required this.onSaved});
  @override
  State<CredsScreen> createState() => _CredsScreenState();
}

class _CredsScreenState extends State<CredsScreen> {
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
    setState(() => _busy = false);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Soleco Login speichern')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            children: [
              const Text('Einmalig Benutzername & Passwort speichern – die App loggt dich automatisch ein.'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'Benutzername', border: OutlineInputBorder()),
                validator: (v) => (v==null||v.trim().isEmpty) ? 'Benutzername erforderlich' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Passwort', border: OutlineInputBorder()),
                validator: (v) => (v==null||v.isEmpty) ? 'Passwort erforderlich' : null,
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

/// ---------------- WebShell (WebView + Overlays) ----------------
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  static const String vehicleUrl = 'https://soleco-optimizer.ch/VehicleAppointments';
  static const String viewsUrl   = 'https://soleco-optimizer.ch/Views';

  final storage = const FlutterSecureStorage();
  final cookieMgr = WebviewCookieManager();

  late final WebViewController _c;
  bool _loading = true;

  // Overlays
  bool _showHub = false;            // Auswahl: Webseite / Auto
  bool _showVehiclePicker = false;  // Liste aus #vehicleSelection
  bool _showCharging = false;       // Sofortladen-Panel

  bool _didAutoLogin = false;
  bool _autoShowHub = true;         // nur 1x nach Login anzeigen
  static const _cookieStoreKey = 'cookie_store_v1';

  String _lastUrl = '';
  List<VehicleItem> _vehicles = const [];

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

            // B2C Login erkannt? -> Auto-Login (einmalig)
            if (await _isB2CLoginDom()) {
              if (!_didAutoLogin) {
                _didAutoLogin = true;
                await _autoLoginB2C();
              }
            }

            // Eingeloggt -> Cookies sichern
            if (url.contains('VehicleAppointments')) {
              await _persistCookies(url);
              if (!mounted) return;
              // Nur beim allerersten Erreichen den Hub automatisch zeigen
              if (_autoShowHub && !_showCharging && !_showVehiclePicker && !_showHub) {
                setState(() { _showHub = true; });
              }
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

    // Cookies wiederherstellen und Vehicle-Seite laden (Soleco leitet dann ggf. zum Login um)
    Future.microtask(() async {
      await _restoreCookies();
      await _c.loadRequest(Uri.parse(vehicleUrl));
    });
  }

  // ---------- Cookie-Persistenz ----------
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

  /// ---------- Logout ----------
  Future<void> _logout({bool switchAccount = false}) async {
    try {
      await cookieMgr.clearCookies();
      // Kein _c.clearCache(); -> könnte je nach Pluginversion nicht existieren
      try { await _c.runJavaScript('try{localStorage.clear();sessionStorage.clear();}catch(e){}'); } catch (_){}
      await storage.delete(key: _cookieStoreKey);
      if (switchAccount) {
        await storage.delete(key: 'soleco_user');
        await storage.delete(key: 'soleco_pass');
      }
      setState(() {
        _didAutoLogin = false;
        _autoShowHub = true; // Beim nächsten erfolgreichen Login wieder einmal anzeigen
        _showHub = false; _showVehiclePicker = false; _showCharging = false;
      });
      await _c.loadRequest(Uri.parse(vehicleUrl));
      if (switchAccount && mounted) {
        Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const Gate()), (_) => false);
      }
    } catch (_) {}
  }

  // ---------- Helfer: auf VehicleAppointments wechseln & warten ----------
  Future<void> _ensureOnVehiclePage() async {
    if (!_lastUrl.contains('VehicleAppointments')) {
      await _c.loadRequest(Uri.parse(vehicleUrl));
      // warte, bis wir wirklich dort sind
      for (int i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (_lastUrl.contains('VehicleAppointments')) break;
      }
    }
  }

  /// ---------- Fahrzeuge aus #vehicleSelection holen (robust + Polling) ----------
  Future<List<VehicleItem>> _scanVehiclesOnce() async {
    final js = r'''
      (function(){
        function clean(t){return (t||'').toString().replace(/\s+/g,' ').trim();}
        var root = document.getElementById('vehicleSelection');
        var out = [];
        if(!root){ return JSON.stringify({ok:false, reason:'no_element', list:[]}); }

        // DevExtreme-API (beachtet displayExpr / dataSource.items())
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

        // Popup öffnen (lädt oft erst dann)
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
    // Stelle sicher, dass wir auf der Fahrzeug-Seite sind
    await _ensureOnVehiclePage();

    // Bis zu 4 Sekunden pollen (20 * 200ms)
    for (int i = 0; i < 20; i++) {
      final list = await _scanVehiclesOnce();
      if (list.isNotEmpty) return list;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // Letzter Versuch: Seite neu laden und nochmals kurz pollen
    await _c.reload();
    for (int i = 0; i < 20; i++) {
      final list = await _scanVehiclesOnce();
      if (list.isNotEmpty) return list;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return [];
  }

  /// Auswahl in #vehicleSelection setzen – erst API (selectedItem), dann DOM-Klick (Index)
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

        // Fallback: DOM klicken
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

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco'),
        leading: IconButton( // Startmenü jederzeit öffnen
          tooltip: 'Start',
          icon: const Icon(Icons.apps),
          onPressed: () => setState(() {
            _autoShowHub = false;
            _showHub = true;
            _showVehiclePicker = false;
            _showCharging = false;
          }),
        ),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'logout') {
                await _logout(switchAccount: false);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Abgemeldet.')),
                  );
                }
              } else if (value == 'switch') {
                await _logout(switchAccount: true);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Abmelden'),
                  subtitle: Text('Cookies löschen, gleiches Konto'),
                ),
              ),
              PopupMenuItem(
                value: 'switch',
                child: ListTile(
                  leading: Icon(Icons.switch_account),
                  title: Text('Abmelden & Konto wechseln'),
                  subtitle: Text('Cookies + Zugangsdaten löschen'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          // WebView bleibt immer gemountet
          Offstage(
            offstage: _showHub || _showVehiclePicker || _showCharging,
            child: WebViewWidget(controller: _c),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),

          // HUB: Webseite oder Auto (nur 1x automatisch; sonst per Apps-Icon)
          if (_showHub)
            HubOverlay(
              onWebsite: () async {
                setState(() {
                  _autoShowHub = false;
                  _showHub = false;
                  _showVehiclePicker = false;
                  _showCharging = false;
                });
                await _c.loadRequest(Uri.parse(viewsUrl)); // << /Views
              },
              onAuto: () async {
                setState(() {
                  _autoShowHub = false;
                });
                final list = await _scanVehiclesWithPolling(); // auto öffnen / warten
                if (list.length == 1) {
                  await _selectVehicle(list.first);
                  await Future.delayed(const Duration(milliseconds: 250));
                  setState(() { _showHub = false; _showCharging = true; });
                } else {
                  setState(() {
                    _vehicles = list;
                    _showHub = false;
                    _showVehiclePicker = true;
                  });
                }
              },
            ),

          // Fahrzeug-Picker (aus #vehicleSelection)
          if (_showVehiclePicker)
            VehiclePickerOverlay(
              vehicles: _vehicles,
              onCancel: () => setState(() { _showVehiclePicker = false; _showHub = true; }),
              onRescan: () async {
                final list = await _scanVehiclesWithPolling();
                setState(() => _vehicles = list);
              },
              onSelect: (v) async {
                final res = await _selectVehicle(v);
                await Future.delayed(const Duration(milliseconds: 250));
                setState(() { _showVehiclePicker = false; _showCharging = true; });
                if (mounted && res.startsWith('no_')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Konnte Fahrzeug nicht wählen: $res')),
                  );
                }
              },
            ),

          // Sofortladen
          if (_showCharging)
            CustomChargingPanel(
              runJS: (code) => _c.runJavaScript(code),
              onBackToWeb: () => setState(() {
                _showCharging = false;
                _showHub = false;
                _showVehiclePicker = false;
              }),
              onLogout: () => _logout(switchAccount: false),
              onSwitchAccount: () => _logout(switchAccount: true),
            ),
        ],
      ),
    );
  }
}

/// ---------------- HUB Overlay ----------------
class HubOverlay extends StatelessWidget {
  final VoidCallback onWebsite;
  final VoidCallback onAuto;
  const HubOverlay({super.key, required this.onWebsite, required this.onAuto});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: LayoutBuilder(
          builder: (ctx, c) {
            final size = (c.maxWidth < 500) ? 130.0 : 170.0;
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RoundAction(size: size, icon: Icons.public, label: 'Webseite', onTap: onWebsite),
                const SizedBox(height: 32),
                _RoundAction(size: size, icon: Icons.ev_station, label: 'Auto', onTap: onAuto),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final double size;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _RoundAction({required this.size, required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: size,
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: Colors.teal.shade700,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.2), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: size*0.42, color: Colors.white),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(color: Colors.white, fontSize: size*0.18, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// ---------------- Fahrzeug-Picker ----------------
class VehiclePickerOverlay extends StatelessWidget {
  final List<VehicleItem> vehicles;
  final VoidCallback onCancel;
  final Future<void> Function() onRescan;
  final Future<void> Function(VehicleItem v) onSelect;

  const VehiclePickerOverlay({
    super.key,
    required this.vehicles,
    required this.onCancel,
    required this.onRescan,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(onPressed: onCancel, icon: const Icon(Icons.arrow_back)),
                  const SizedBox(width: 8),
                  const Text('Fahrzeug wählen', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(onPressed: onRescan, icon: const Icon(Icons.refresh)),
                ],
              ),
              const SizedBox(height: 12),
              if (vehicles.isEmpty)
                const Text('Keine Fahrzeuge gefunden. Bitte neu scannen oder zur Webseite.'),
              if (vehicles.isNotEmpty)
                Expanded(
                  child: ListView.separated(
                    itemCount: vehicles.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final v = vehicles[i];
                      return ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        tileColor: Colors.teal.shade50,
                        leading: CircleAvatar(
                          backgroundColor: Colors.teal.shade700,
                          child: const Icon(Icons.directions_car, color: Colors.white),
                        ),
                        title: Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => onSelect(v),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ---------------- Sofortladen-Panel ----------------
class CustomChargingPanel extends StatefulWidget {
  final Future<void> Function(String js) runJS;
  final VoidCallback onBackToWeb;
  final Future<void> Function() onLogout;
  final Future<void> Function() onSwitchAccount;

  const CustomChargingPanel({
    super.key,
    required this.runJS,
    required this.onBackToWeb,
    required this.onLogout,
    required this.onSwitchAccount,
  });

  @override
  State<CustomChargingPanel> createState() => _CustomChargingPanelState();
}

class _CustomChargingPanelState extends State<CustomChargingPanel> {
  final TextEditingController _minutesCtrl = TextEditingController(text: '30');
  bool _busy = false;

  Future<void> _startCharging() async {
    final minutes = _minutesCtrl.text.trim();
    if (minutes.isEmpty) return;
    setState(() => _busy = true);

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
      await widget.runJS(js);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sofortladung ausgelöst')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: widget.onBackToWeb,
                    icon: const Icon(Icons.public),
                    label: const Text('Zur Webseite'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await widget.onLogout();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Abgemeldet.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Abmelden'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () async => widget.onSwitchAccount(),
                    icon: const Icon(Icons.switch_account),
                    label: const Text('Konto wechseln'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Sofortladung mit voller Leistung',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(
                controller: _minutesCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Minuten', hintText: 'z. B. 30', border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _busy ? null : _startCharging,
                icon: const Icon(Icons.flash_on),
                label: Text(_busy ? 'Bitte warten…' : 'Sofortladen starten'),
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
