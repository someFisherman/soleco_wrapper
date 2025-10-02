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
const _kViewsUrl = 'preferred_views_url';

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
  WebViewController? _aux; // unsichtbarer Controller (für 80%-Monitor)

  bool _loading = true;
  bool _showStartMenu = true;
  bool _didAutoLogin = false;

  Timer? _autoStopTimer;
  bool _autoStopActive = false;

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

            // Vehicle-Appointments geladen? – Cookies sichern
            if (url.contains('/VehicleAppointments')) {
              await _persistCookies(url);
              // Startmenü beim ersten Start sichtbar lassen
              return;
            }

            // /Views?… – bevorzugte URL merken (SiteId etc.)
            if (url.contains('/Views')) {
              await _persistCookies(url);
              await storage.write(key: _kViewsUrl, value: url);
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

  Future<void> _ensureAuxController() async {
    if (_aux != null) return;
    _aux = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (u) async => _persistCookies(u),
      ));
    // Cookies sind global (WKWebView), aber aus Höflichkeit: restore
    await _restoreCookies();
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
    } catch (_) { return false; }
  }

  Future<void> _autoLoginB2C() async {
    final user = await storage.read(key: _kUser);
    final pass = await storage.read(key: _kPass);
    if (user == null || pass == null) return;
    final esc = (String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('`', r'\`');

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

  // ---------- Startmenü-Aktionen ----------
  Future<void> _openWebsite() async {
    setState(() => _showStartMenu = false);
    await _main.loadRequest(Uri.parse(startViewsUrl));
  }

  Future<void> _openAuto() async {
    setState(() => _showStartMenu = false);
    await _main.loadRequest(Uri.parse(startVehicleUrl));
    // Der Schnellstart-Panel kommt als Overlay
    await Future.delayed(const Duration(milliseconds: 200));
    if (mounted) {
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
          onStart: (minutes, autoStop80) async {
            await _triggerParameters(minutes);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Sofortladung gestartet (${minutes} min)')),
            );
            if (autoStop80) {
              _startAutoStopMonitor();
            }
          },
        ),
      );
    }
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

  // ---------- Auto-Stop 80% (nur aktiv, wenn App offen) ----------
  void _startAutoStopMonitor() async {
    _autoStopTimer?.cancel();
    _autoStopActive = true;

    await _ensureAuxController();
    final viewsUrl = await storage.read(key: _kViewsUrl) ?? startViewsUrl;

    // sofort einmal prüfen + dann alle 20s
    Future<int> readSOC() async {
      try {
        await _aux!.loadRequest(Uri.parse(viewsUrl));
        await Future.delayed(const Duration(seconds: 2)); // DOM settle
        final res = await _aux!.runJavaScriptReturningResult(r'''
          (function(){
            try{
              // suche „40%“ in SVG/Text
              var ts = Array.from(document.querySelectorAll('text')).map(t => (t.textContent||'').trim());
              for (var s of ts) {
                var m = /^(\d{1,3})\s*%$/.exec(s);
                if (m) return parseInt(m[1],10);
              }
              // generische Suche
              var all = document.body.innerText || '';
              var mm = all.match(/(\d{1,3})\s*%/);
              if(mm) return parseInt(mm[1],10);
            }catch(e){}
            return -1;
          })();
        ''');
        final v = int.tryParse(res.toString()) ?? -1;
        return v;
      } catch (_) {
        return -1;
      }
    }

    Future<void> stopNow() async {
      await _triggerParameters(0); // Minuten=0
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Auto-Stop: 80 % erreicht – Ladung beendet.')),
      );
    }

    // erster Check
    () async {
      final v = await readSOC();
      if (v >= 80 && v <= 100) {
        await stopNow();
        _autoStopActive = false;
        return;
      }
    }();

    _autoStopTimer = Timer.periodic(const Duration(seconds: 20), (t) async {
      if (!_autoStopActive) {
        t.cancel();
        return;
      }
      final v = await readSOC();
      if (v >= 80 && v <= 100) {
        await stopNow();
        _autoStopActive = false;
        t.cancel();
      }
    });
  }

  // ---------- UI ----------
  @override
  void dispose() {
    _autoStopTimer?.cancel();
    super.dispose();
  }

  Future<void> _openCredentials() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CredsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Optimizer', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Startmenü',
            onPressed: () => setState(() => _showStartMenu = !_showStartMenu),
            icon: const Icon(Icons.local_florist_outlined, color: Brand.primary),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'views') {
                await _openWebsite();
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
                await _main.loadRequest(Uri.parse('https://soleco-optimizer.ch/Account/SignOut'));
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
              onWebsite: _openWebsite,
            )
          : null,
    );
  }
}

/// Startmenü – schwebende Karte unten
class StartMenu extends StatelessWidget {
  final VoidCallback onAuto;
  final VoidCallback onWebsite;
  const StartMenu({super.key, required this.onAuto, required this.onWebsite});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [BoxShadow(blurRadius: 24, color: Colors.black12, offset: Offset(0, 8))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Schnellstart', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Row(
              children: [
                _RoundAction(
                  label: 'Webseite',
                  icon: Icons.public,
                  onTap: onWebsite,
                ),
                const SizedBox(width: 16),
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
  const _RoundAction({required this.label, required this.icon, required this.onTap});

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
                  BoxShadow(blurRadius: 24, color: Colors.black26, offset: Offset(0, 10)),
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Login gespeichert.')));
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

/// ---- Schnellstart-Sheet ----
class ChargingSheet extends StatefulWidget {
  final int defaultMinutes;
  final Future<void> Function(int minutes, bool autoStop80) onStart;
  const ChargingSheet({
    super.key,
    required this.defaultMinutes,
    required this.onStart,
  });

  @override
  State<ChargingSheet> createState() => _ChargingSheetState();
}

class _ChargingSheetState extends State<ChargingSheet> {
  late final TextEditingController _minCtrl =
      TextEditingController(text: widget.defaultMinutes.toString());
  bool _autoStop = false;
  bool _busy = false;

  Widget _chip(int v) {
    return ChoiceChip(
      label: Text('$v min'),
      selected: _minCtrl.text.trim() == '$v',
      onSelected: (_) => setState(() => _minCtrl.text = '$v'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 42, height: 4,
              decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Sofortladung', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [_chip(60), _chip(120), _chip(180)],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _minCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Dauer in Minuten',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _autoStop,
            onChanged: (v) => setState(() => _autoStop = v),
            title: const Text('Auto-Stop bei 80 % (Beta, nur wenn App offen)'),
            subtitle: const Text('Prüft regelmäßig die Ansichten-Seite und stoppt bei ≥ 80 %.'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final m = int.tryParse(_minCtrl.text.trim());
                    if (m == null || m < 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Bitte gültige Minuten eingeben.')),
                      );
                      return;
                    }
                    setState(() => _busy = true);
                    try {
                      await widget.onStart(m, _autoStop);
                      if (context.mounted) Navigator.pop(context);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            icon: const Icon(Icons.flash_on),
            label: Text(_busy ? 'Bitte warten…' : 'Laden starten'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
