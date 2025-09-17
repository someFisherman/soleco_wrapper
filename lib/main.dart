import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() => runApp(const App());

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

/// ----------------------------------------------------
/// Gate: fragt einmalig Zugangsdaten ab, speichert sie,
/// startet dann die WebShell
/// ----------------------------------------------------
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

/// ----------------------------------------------------
/// WebShell: lädt VehicleAppointments, macht bei Bedarf
/// **gezielten Azure B2C Auto-Login** und zeigt danach
/// deinen „Sofortladen“-Screen.
/// ----------------------------------------------------
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  // Direkt die Zielseite: wenn nicht eingeloggt, leitet Soleco zu B2C um
  static const String startUrl = 'https://soleco-optimizer.ch/VehicleAppointments';

  final storage = const FlutterSecureStorage();
  late final WebViewController _c;
  bool _loading = true;
  bool _showCustomUI = false;
  bool _didAutoLogin = false; // wichtig: nur EIN Versuch pro Login-Seite

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

            // 1) Bereits eingeloggt? Dann kommt VehicleAppointments -> zeige Custom UI
            if (url.contains('VehicleAppointments')) {
              if (mounted) setState(() => _showCustomUI = true);
              return;
            }

            // 2) Stehen wir auf der B2C-Loginseite? (DOM-Check!)
            final isB2C = await _isB2CLoginDom();
            if (isB2C && !_didAutoLogin) {
              _didAutoLogin = true; // nur einmal pro Besuch
              await _autoLoginB2C();
              return;
            }

            // 3) Falls wir nach Login wieder irgendwo anders landen, einfach laufen lassen.
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
      )
      ..loadRequest(Uri.parse(startUrl));
  }

  Future<bool> _isB2CLoginDom() async {
    // Prüfe, ob das B2C-Login-Formular im DOM ist (IDs aus deinem HTML: #localAccountForm, #UserId, #password, #next)
    try {
      final res = await _c.runJavaScriptReturningResult('''
        (function(){
          var f=document.getElementById('localAccountForm');
          var u=document.getElementById('UserId');
          var p=document.getElementById('password');
          var n=document.getElementById('next');
          return !!(f && u && p && n);
        })();
      ''');
      // iOS gibt als bool manchmal 0/1 oder true/false zurück
      return res.toString() == 'true' || res.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> _autoLoginB2C() async {
    final user = await storage.read(key: 'soleco_user');
    final pass = await storage.read(key: 'soleco_pass');
    if (user == null || pass == null) return;

    // Polling bis Elemente sicher da sind, dann befüllen & klicken (IDs exakt aus deinem HTML)
    final js = '''
      (function(){
        function setVal(el, val){
          if(!el) return false;
          el.focus();
          el.value = val;
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
            setVal(u, '${_js(user)}');
            setVal(p, '${_js(pass)}');
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
    await _c.runJavaScript(js);
  }

  String _js(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('`', r'\`');

  Future<void> _reload() => _c.reload();

  @override
  Widget build(BuildContext context) {
    if (_showCustomUI) {
      return CustomChargingScreen(
        controller: _c,
        onBackToWeb: () => setState(() => _showCustomUI = false),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soleco'),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
          IconButton(
            tooltip: 'Login ändern',
            icon: const Icon(Icons.manage_accounts),
            onPressed: () async {
              await storage.delete(key: 'soleco_user');
              await storage.delete(key: 'soleco_pass');
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const Gate()),
                (_) => false,
              );
            },
          )
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _c),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}

/// ----------------------------------------------------
/// Dein einfacher „Sofortladen“-Screen
/// ----------------------------------------------------
class CustomChargingScreen extends StatefulWidget {
  final WebViewController controller;
  final VoidCallback onBackToWeb;
  const CustomChargingScreen({super.key, required this.controller, required this.onBackToWeb});

  @override
  State<CustomChargingScreen> createState() => _CustomChargingScreenState();
}

class _CustomChargingScreenState extends State<CustomChargingScreen> {
  final TextEditingController _minutesCtrl = TextEditingController(text: '30');
  bool _busy = false;

  Future<void> _startCharging() async {
    final minutes = _minutesCtrl.text.trim();
    if (minutes.isEmpty) return;
    setState(() => _busy = true);

    final js = '''
      (function(){
        try {
          var m = parseInt("$minutes",10); if(isNaN(m)||m<0) m=0;

          // DevExtreme-Form (falls vorhanden)
          try {
            if (window.DevExpress && window.jQuery) {
              var form = jQuery("#parameterform").dxForm("instance");
              if (form && form.updateData) { form.updateData("Minutes", m); }
            }
          } catch(e){}

          // Hidden input (immer vorhanden laut HTML)
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
          var btn = document.querySelector("#PostParametersButton, .dx-button[id='PostParametersButton']");
          if (btn) btn.click();
        } catch(e){ console.log("start charge error", e); }
      })();
    ''';

    try {
      await widget.controller.runJavaScript(js);
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
