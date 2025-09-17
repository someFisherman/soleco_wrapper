import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

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

/// ---------------- WebShell (WebView + Overlays: Hub → Picker → Laden) ----------------
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  static const String startUrl = 'https://soleco-optimizer.ch/VehicleAppointments';

  final storage = const FlutterSecureStorage();
  final cookieMgr = WebviewCookieManager();

  late final WebViewController _c;
  bool _loading = true;

  // Overlays
  bool _showHub = false;            // „Webseite“ oder „Auto“
  bool _showVehiclePicker = false;  // Fahrzeugliste
  bool _showCharging = false;       // Sofortladen-Screen

  bool _didAutoLogin = false;
  static const _cookieStoreKey = 'cookie_store_v1';

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
            setState(() => _loading = false);

            // B2C Login? -> auto login (einmalig)
            if (await _isB2CLoginDom()) {
              if (!_didAutoLogin) {
                _didAutoLogin = true;
                await _autoLoginB2C();
              }
            }

            // Eingeloggt (VehicleAppointments) -> Cookies sichern + Hub einblenden
            if (url.contains('VehicleAppointments')) {
              await _persistCookies(url);
              if (mounted) {
                // Hub statt sofort Laden, damit du zuerst „Webseite/Auto“ siehst
                setState(() {
                  _showHub = true;
                  _showVehiclePicker = false;
                  _showCharging = false;
                });
              }
              return;
            }

            // sonst Cookies einsammeln
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

    // Cookies wiederherstellen und dann Seite laden
    Future.microtask(() async {
      await _restoreCookies();
      await _c.loadRequest(Uri.parse(startUrl));
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

  /// ---------- Logout ----------
  Future<void> _logout({bool switchAccount = false}) async {
    try {
      await cookieMgr.clearCookies();
      await _c.clearCache();
      try { await _c.runJavaScript('try{localStorage.clear();sessionStorage.clear();}catch(e){}'); } catch (_){}
      await storage.delete(key: _cookieStoreKey);
      if (switchAccount) {
        await storage.delete(key: 'soleco_user');
        await storage.delete(key: 'soleco_pass');
      }
      setState(() {
        _didAutoLogin = false;
        _showHub = false;
        _showVehiclePicker = false;
        _showCharging = false;
      });
      await _c.loadRequest(Uri.parse(startUrl));
      if (switchAccount && mounted) {
        Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const Gate()), (_) => false);
      }
    } catch (_) {}
  }

  /// ---------- Fahrzeuge scannen & auswählen ----------
  Future<List<VehicleItem>> _scanVehicles() async {
    final js = '''
      (function(){
        function clean(t){return (t||'').replace(/\\s+/g,' ').trim();}
        var items=[], seen={};

        // 1) Links, die wie Fahrzeug-Navigation aussehen
        var as = Array.from(document.querySelectorAll('a[href]'));
        as.forEach(function(a){
          var href = a.href||'';
          if(/Vehicle/i.test(href) && /Appointment|Vehicle/i.test(href)){
            if(!seen[href]){
              seen[href]=true;
              var label = clean(a.textContent)||clean(a.getAttribute('aria-label'));
              if(!label){
                var card = a.closest('.card, .dx-card, .dx-list-item, li, tr');
                if(card) label = clean(card.textContent);
              }
              items.push({type:'link', href:href, label: label||'Fahrzeug'});
            }
          }
        });

        // 2) Dropdown <select> mit vehicle/fahrzeug im Namen
        var sels = Array.from(document.querySelectorAll('select'));
        sels.forEach(function(s){
          var idn = (s.id||'') + ' ' + (s.name||'');
          if(/vehicle|fahrzeug/i.test(idn)){
            Array.from(s.options||[]).forEach(function(o,idx){
              items.push({type:'select', selectId:(s.id||s.name||'vehicle'), value:o.value, label:clean(o.text), index:idx});
            });
          }
        });

        return JSON.stringify(items.slice(0,40));
      })();
    ''';

    try {
      final res = await _c.runJavaScriptReturningResult(js);
      final jsonStr = res is String ? res : res.toString();
      final data = jsonDecode(jsonStr) as List<dynamic>;
      return data.map((e) => VehicleItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<String> _selectVehicle(VehicleItem v) async {
    final js = (v.type == 'link')
        ? '''
          (function(){
            var href = '${_js(v.href ?? '')}';
            var a = Array.from(document.querySelectorAll('a[href]')).find(x => x.href===href);
            if(a){ a.click(); return 'clicked'; }
            location.href = href; return 'navigated';
          })();
        '''
        : '''
          (function(){
            function sel(q){ try{return document.querySelector(q);}catch(e){return null;} }
            var id = '${_js(v.selectId ?? '')}';
            var s = sel('select#'+id) || sel('select[name="'+id+'"]') || document.querySelector('select');
            if(!s) return 'no_select';
            s.value = '${_js(v.value ?? '')}';
            try{ s.dispatchEvent(new Event('input',{bubbles:true})); }catch(e){}
            try{ s.dispatchEvent(new Event('change',{bubbles:true})); }catch(e){}
            return 'selected';
          })();
        ''';

    try {
      final res = await _c.runJavaScriptReturningResult(js);
      return res.toString();
    } catch (e) {
      return 'error';
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco'),
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

          // HUB: Webseite oder Auto
          if (_showHub)
            HubOverlay(
              onWebsite: () {
                setState(() {
                  _showHub = false;
                  _showVehiclePicker = false;
                  _showCharging = false;
                });
              },
              onAuto: () async {
                final list = await _scanVehicles();
                setState(() {
                  _vehicles = list;
                  _showHub = false;
                  _showVehiclePicker = true;
                });
              },
            ),

          // Fahrzeug-Picker
          if (_showVehiclePicker)
            VehiclePickerOverlay(
              vehicles: _vehicles,
              onCancel: () => setState(() {
                _showVehiclePicker = false;
                _showHub = true;
              }),
              onSelect: (v) async {
                final res = await _selectVehicle(v);
                // kleine Wartezeit, damit die Seite wechseln kann
                await Future.delayed(const Duration(milliseconds: 300));
                setState(() {
                  _showVehiclePicker = false;
                  _showCharging = true;
                });
                if (mounted && res.startsWith('no_')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Konnte Fahrzeug nicht wählen: $res')),
                  );
                }
              },
              onSkip: () {
                // direkt zur Lade-UI
                setState(() {
                  _showVehiclePicker = false;
                  _showCharging = true;
                });
              },
              onRescan: () async {
                final list = await _scanVehicles();
                setState(() => _vehicles = list);
              },
            ),

          // Laden
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
                _RoundAction(
                  size: size,
                  icon: Icons.public,
                  label: 'Webseite',
                  onTap: onWebsite,
                ),
                const SizedBox(height: 32),
                _RoundAction(
                  size: size,
                  icon: Icons.electric_bolt,
                  label: 'Auto',
                  onTap: onAuto,
                ),
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

/// ---------------- Fahrzeug-Picker Overlay ----------------
class VehiclePickerOverlay extends StatelessWidget {
  final List<VehicleItem> vehicles;
  final VoidCallback onCancel;
  final VoidCallback onSkip;
  final Future<void> Function() onRescan;
  final Future<void> Function(VehicleItem v) onSelect;

  const VehiclePickerOverlay({
    super.key,
    required this.vehicles,
    required this.onCancel,
    required this.onSkip,
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
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Keine Liste gefunden.',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        const Text('Du kannst direkt zum Laden gehen oder neu scannen.'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: onSkip,
                          icon: const Icon(Icons.flash_on),
                          label: const Text('Direkt zum Laden'),
                        ),
                      ],
                    ),
                  ),
                )
              else
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
                        title: Text(v.label ?? 'Fahrzeug ${i+1}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(v.type == 'link'
                            ? 'Link'
                            : 'Auswahl: ${v.selectId ?? 'select'}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async => onSelect(v),
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

class VehicleItem {
  final String type;        // 'link' | 'select'
  final String? href;       // bei link
  final String? label;      // Anzeige
  final String? selectId;   // bei select
  final String? value;      // bei select

  VehicleItem({required this.type, this.href, this.label, this.selectId, this.value});

  factory VehicleItem.fromJson(Map<String, dynamic> j) => VehicleItem(
    type: j['type'] as String,
    href: j['href'] as String?,
    label: j['label'] as String?,
    selectId: j['selectId'] as String?,
    value: j['value'] as String?,
  );
}

/// ---------------- Dein Schnellstart-Panel (unverändert zuverlässig) ----------------
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

        // A) Zuerst DevExtreme-Button-Handler direkt (nimmt aktuellen Fahrzeug-Kontext)
        try {
          if (window.jQuery) {
            var inst = jQuery("#PostParametersButton").dxButton("instance");
            if (inst) {
              // Minuten in der Form setzen
              try {
                var form = jQuery("#parameterform").dxForm("instance");
                if (form) { try { form.updateData("Minutes", m); } catch(e){} }
              } catch(e){}

              var handler = inst.option("onClick");
              if (typeof handler === "function") {
                handler({});
                return "handler_called";
              }
            }
          }
        } catch(e){}

        // B) Fallback: direkte PostParameters(...) – mit Werten aus der Form
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

        // C) Letzter Fallback: dxclick + Pointer-Events + click()
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
                      if (context.mounted) {
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
