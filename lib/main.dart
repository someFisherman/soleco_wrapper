import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soleco',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const Gate(),
    );
  }
}

/// ---------- Gate: prüft, ob Zugangsdaten gespeichert sind ----------
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

/// ---------- Zugangsdaten einmalig speichern ----------
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
              const Text('Einmalig Benutzername & Passwort speichern – die App loggt dich dann automatisch ein.'),
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

/// ---------- WebShell mit InAppWebView + Cookie-Persistenz ----------
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  static const String startUrl = 'https://soleco-optimizer.ch/VehicleAppointments';
  static const cookieStoreKey = 'cookie_jar_v1'; // SecureStorage-Key

  final storage = const FlutterSecureStorage();
  final cookieManager = CookieManager.instance();

  InAppWebViewController? _web;
  bool _loading = true;
  bool _showCustomUI = false;
  bool _didAutoLogin = false;

  @override
  void initState() {
    super.initState();
  }

  // ---------- Cookies wiederherstellen (vor dem ersten Laden) ----------
  Future<void> _restoreCookies() async {
    final raw = await storage.read(key: cookieStoreKey);
    if (raw == null) return;
    final List list = jsonDecode(raw);
    for (final m in list) {
      try {
        final domain = (m['domain'] as String?) ?? '';
        final name = (m['name'] as String?) ?? '';
        final value = (m['value'] as String?) ?? '';
        final path = (m['path'] as String?) ?? '/';
        final isSecure = (m['isSecure'] as bool?) ?? true;
        final isHttpOnly = (m['isHttpOnly'] as bool?) ?? false;
        final expiresDate = (m['expiresDate'] as int?); // epoch seconds
        final sameSiteStr = (m['sameSite'] as String?) ?? 'LAX';
        HTTPCookieSameSitePolicy? sameSite;
        switch (sameSiteStr.toUpperCase()) {
          case 'NONE': sameSite = HTTPCookieSameSitePolicy.NONE; break;
          case 'STRICT': sameSite = HTTPCookieSameSitePolicy.STRICT; break;
          default: sameSite = HTTPCookieSameSitePolicy.LAX;
        }

        // zum Setzen braucht setCookie eine URL – wir bauen eine passende:
        final urlForCookie = Uri.parse('https://${domain.startsWith('.') ? domain.substring(1) : domain}$path');

        await cookieManager.setCookie(
          url: WebUri(urlForCookie.toString()),
          name: name,
          value: value,
          domain: domain,
          path: path,
          isSecure: isSecure,
          isHttpOnly: isHttpOnly,
          sameSite: sameSite,
          // expiresDate erwartet epoch seconds
          expiresDate: expiresDate,
        );
      } catch (_) {}
    }
  }

  // ---------- Cookies speichern (nach Login / wenn wir auf Zielseite sind) ----------
  Future<void> _persistCookiesForCurrentUrl(String url) async {
    try {
      final cookies = await cookieManager.getCookies(url: WebUri(url));
      // wir speichern ALLE Cookies, die wir unterwegs sehen (auch b2c-Domain)
      final jsonList = cookies.map((c) => {
        'name': c.name,
        'value': c.value,
        'domain': c.domain,
        'path': c.path,
        'isSecure': c.isSecure,
        'isHttpOnly': c.isHttpOnly,
        'expiresDate': c.expiresDate, // kann null sein (Session-Cookie)
        'sameSite': c.sameSite?.name.toUpperCase(),
      }).toList();
      await storage.write(key: cookieStoreKey, value: jsonEncode(jsonList));
    } catch (_) {}
  }

  // ---------- Erkennung der Azure B2C Loginseite im DOM ----------
  Future<bool> _isB2CLoginDom() async {
    if (_web == null) return false;
    try {
      final res = await _web!.evaluateJavascript(source: '''
        (function(){
          var f=document.getElementById('localAccountForm');
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var n=document.getElementById('next');
          return !!(f&&u&&p&&n);
        })();
      ''');
      return res == true || res.toString() == 'true' || res.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  // ---------- Auto-Login auf der B2C-Seite ----------
  Future<void> _autoLoginB2C() async {
    final user = await storage.read(key: 'soleco_user');
    final pass = await storage.read(key: 'soleco_pass');
    if (user == null || pass == null || _web == null) return;

    final js = '''
      (function(){
        function esc(s){return s.replaceAll('\\\\','\\\\\\\\').replaceAll('`','\\\\`').replaceAll(\"'\",\"\\\\'\");}
        function setVal(el, val){
          if(!el) return false;
          el.focus(); el.value = val;
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
          if(u && p && btn){
            setVal(u, '${_esc(user)}');
            setVal(p, '${_esc(pass)}');
            btn.click();
            return true;
          }
          return false;
        }
        if(!tryLogin()){
          var tries=0;
          var t=setInterval(function(){
            tries++;
            if(tryLogin() || tries>50){ clearInterval(t); }
          }, 100);
        }
      })();
    ''';
    await _web!.evaluateJavascript(source: js);
  }

  String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('`', r'\`').replaceAll("'", r"\'");

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    if (_showCustomUI) {
      return CustomChargingScreen(
        controller: _web,
        onBackToWeb: () => setState(() => _showCustomUI = false),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _web?.reload(),
          ),
          IconButton(
            tooltip: 'Login ändern',
            icon: const Icon(Icons.manage_accounts),
            onPressed: () async {
              await storage.delete(key: 'soleco_user');
              await storage.delete(key: 'soleco_pass');
              await storage.delete(key: cookieStoreKey);
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const Gate()),
                  (_) => false,
                );
              }
            },
          ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(startUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          incognito: false,                   // wichtig: NICHT inkognito
          cacheEnabled: true,
          sharedCookiesEnabled: true,         // iOS: Cookies mit WK-Store teilen
          thirdPartyCookiesEnabled: true,     // sicherheitshalber
          mediaPlaybackRequiresUserGesture: true,
        ),
        onWebViewCreated: (controller) async {
          _web = controller;
          await _restoreCookies();            // <<< Cookies vor dem ersten Laden setzen
        },
        shouldOverrideUrlLoading: (controller, navAction) async {
          final url = navAction.request.url?.toString() ?? '';
          if (url.startsWith('tel:') || url.startsWith('mailto:')) {
            await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        onLoadStart: (controller, url) {
          setState(() => _loading = true);
        },
        onLoadStop: (controller, url) async {
          setState(() => _loading = false);
          final current = url?.toString() ?? '';

          // Wenn wir auf der B2C-Loginseite stehen -> Auto-Login (nur 1x pro Besuch)
          if (!_didAutoLogin && await _isB2CLoginDom()) {
            _didAutoLogin = true;
            await _autoLoginB2C();
            return;
          }

          // Wenn wir auf der Zielseite sind -> Cookies sichern + Custom UI anzeigen
          if (current.contains('VehicleAppointments')) {
            await _persistCookiesForCurrentUrl(current);
            if (mounted) setState(() => _showCustomUI = true);
            return;
          }

          // Auf jeder Seite, die wir besuchen, Cookies einsammeln (damit wir alle relevanten Domains haben)
          await _persistCookiesForCurrentUrl(current);
        },
        onReceivedError: (controller, request, error) {
          // optional: Fehler-UI anzeigen
        },
        onProgressChanged: (controller, progress) {
          setState(() => _loading = progress < 100);
        },
      ),
      bottomNavigationBar: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
    );
  }
}

/// ---------- Dein „Sofortladen“-Screen ----------
class CustomChargingScreen extends StatefulWidget {
  final InAppWebViewController? controller;
  final VoidCallback onBackToWeb;
  const CustomChargingScreen({super.key, required this.controller, required this.onBackToWeb});

  @override
  State<CustomChargingScreen> createState() => _CustomChargingScreenState();
}

class _CustomChargingScreenState extends State<CustomChargingScreen> {
  final TextEditingController _minutesCtrl = TextEditingController(text: '30');
  bool _busy = false;

  Future<void> _startCharging() async {
    if (widget.controller == null) return;
    final minutes = _minutesCtrl.text.trim();
    if (minutes.isEmpty) return;

    setState(() => _busy = true);

    final js = '''
      (function(){
        try {
          var m = parseInt("$minutes",10); if(isNaN(m)||m<0) m=0;

          // DevExtreme-Form, falls vorhanden
          try {
            if (window.DevExpress && window.jQuery) {
              var form = jQuery("#parameterform").dxForm("instance");
              if (form && form.updateData) { form.updateData("Minutes", m); }
            }
          } catch(e){}

          // Hidden input (laut HTML vorhanden)
          var hidden = document.querySelector("input[name='Minutes']");
          if (hidden) hidden.value = m;

          // Sichtbares DX-Input als Fallback
          var vis = document.querySelector("input#Minutes, input.dx-texteditor-input");
          if (vis) {
            vis.value = m;
            try {
              vis.dispatchEvent(new Event('input', {bubbles:true}));
              vis.dispatchEvent(new Event('change', {bubbles:true}));
              var ev = document.createEvent('HTMLEvents'); ev.initEvent('keyup', true, false); vis.dispatchEvent(ev);
            } catch(e){}
          }

          // Klick auf „Parameter aktivieren“
          var btn = document.querySelector("#PostParametersButton, .dx-button#PostParametersButton");
          if (btn) btn.click();
        } catch(e){ console.log("start charge error", e); }
      })();
    ''';

    try {
      await widget.controller!.evaluateJavascript(source: js);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sofortladung für $minutes Minuten ausgelöst')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco – Schnellstart'),
        actions: [
          TextButton.icon(
            onPressed: widget.onBackToWeb,
            icon: const Icon(Icons.public),
            label: const Text('Zur Webseite'),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Sofortladung mit voller Leistung', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: _minutesCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Minuten', hintText: 'z. B. 30', border: OutlineInputBorder()),
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
    );
  }
}
