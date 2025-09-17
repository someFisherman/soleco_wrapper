import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() => runApp(const App());

/// =============================================
/// App
/// =============================================
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

/// =============================================
/// Gate: zeigt entweder Credential-Setup (einmalig)
/// oder direkt die WebShell
/// =============================================
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
    _checkCreds();
  }

  Future<void> _checkCreds() async {
    final u = await storage.read(key: 'soleco_user');
    final p = await storage.read(key: 'soleco_pass');
    setState(() => hasCreds = (u?.isNotEmpty == true && p?.isNotEmpty == true));
  }

  @override
  Widget build(BuildContext context) {
    if (hasCreds == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (hasCreds == true) {
      return const WebShell();
    }
    return CredsScreen(onSaved: () => setState(() => hasCreds = true));
  }
}

/// =============================================
/// CredsScreen: Einmal Benutzername/Passwort speichern
/// =============================================
class CredsScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const CredsScreen({super.key, required this.onSaved});
  @override
  State<CredsScreen> createState() => _CredsScreenState();
}

class _CredsScreenState extends State<CredsScreen> {
  final storage = const FlutterSecureStorage();
  final _formKey = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    await storage.write(key: 'soleco_user', value: _user.text.trim());
    await storage.write(key: 'soleco_pass', value: _pass.text);
    setState(() => _busy = false);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).size.width > 500 ? 32.0 : 16.0;
    return Scaffold(
      appBar: AppBar(title: const Text('Soleco Login speichern')),
      body: Padding(
        padding: EdgeInsets.all(pad),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              const Text('Bitte einmalig deine Soleco-Zugangsdaten eingeben. '
                  'Die App loggt dich danach automatisch ein.',
                  style: TextStyle(fontSize: 14)),
              const SizedBox(height: 16),
              TextFormField(
                controller: _user,
                decoration: const InputDecoration(
                  labelText: 'Benutzername / E-Mail',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Benutzername erforderlich' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                decoration: const InputDecoration(
                  labelText: 'Passwort',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
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

/// =============================================
/// WebShell: Lädt Seite, Auto-Login bei Bedarf,
/// zeigt nach Login deine „Sofortladen“-UI.
/// =============================================
class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  static const String startUrl = 'https://soleco-optimizer.ch/VehicleAppointments';
  final storage = const FlutterSecureStorage();
  late final WebViewController _c;

  bool _loading = true;
  bool _showCustomUI = false;

  @override
  void initState() {
    super.initState();

    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (u) => setState(() => _loading = true),
          onPageFinished: (u) async {
            setState(() => _loading = false);

            // 1) Wenn Login-Seite erkannt -> Auto-Login versuchen
            if (_looksLikeLoginUrl(u)) {
              await _tryAutoLogin();
              return;
            }

            // 2) Wenn Zielseite nach Login -> Custom UI zeigen
            if (u.contains('VehicleAppointments')) {
              if (mounted) setState(() => _showCustomUI = true);
            }
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

  bool _looksLikeLoginUrl(String url) {
    final u = url.toLowerCase();
    // sehr großzügig: alles was "login" oder "signin" enthält
    return u.contains('login') || u.contains('signin') || u.contains('account/login');
  }

  Future<void> _tryAutoLogin() async {
    final user = await storage.read(key: 'soleco_user');
    final pass = await storage.read(key: 'soleco_pass');
    if (user == null || pass == null) return;

    // Dieses JS sucht übliche Login-Felder (email/username + password),
    // füllt sie und submit-t das erste Formular.
    final js = '''
      (function(){
        try {
          function setInput(el, val){
            if(!el) return false;
            el.focus();
            el.value = val;
            try {
              el.dispatchEvent(new Event('input', {bubbles:true}));
              el.dispatchEvent(new Event('change', {bubbles:true}));
              var ev = document.createEvent('HTMLEvents'); ev.initEvent('keyup', true, false); el.dispatchEvent(ev);
            } catch(e){}
            return true;
          }

          var u = document.querySelector("input[type='email'], input[name*='user'], input[name*='email'], input[id*='user'], input[id*='email']");
          var p = document.querySelector("input[type='password'], input[name*='pass'], input[id*='pass']");

          var okU = setInput(u, "${_jsEscape(user)}");
          var okP = setInput(p, "${_jsEscape(pass)}");

          // versuche sichtbaren Login-Button
          var btn = document.querySelector("button[type='submit'], input[type='submit'], button[class*='login'], button[id*='login']");
          if(btn){ btn.click(); return; }

          // sonst Formular submitten
          var form = (u && u.form) || (p && p.form) || document.querySelector("form");
          if(form){ form.submit(); }
        } catch(e){ console.log('autologin error', e); }
      })();
    ''';

    await _c.runJavaScript(js);
  }

  String _jsEscape(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('`', r'\`');

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
              // Zugangsdaten löschen und zurück zum Gate
              await storage.delete(key: 'soleco_user');
              await storage.delete(key: 'soleco_pass');
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const Gate()),
                (route) => false,
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

/// =============================================
/// Deine „Sofortladen“-Seite (wie zuvor)
/// =============================================
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

          // DevExtreme-Form
          try {
            if (window.DevExpress && window.jQuery) {
              var form = jQuery("#parameterform").dxForm("instance");
              if (form && form.updateData) { form.updateData("Minutes", m); }
            }
          } catch(e){}

          // Hidden input
          var hidden = document.querySelector("input[name='Minutes']");
          if (hidden) hidden.value = m;

          // sichtbares Feld (Fallback)
          var vis = document.querySelector("input#Minutes, input.dx-texteditor-input");
          if (vis) {
            vis.value = m;
            try {
              vis.dispatchEvent(new Event('input', {bubbles:true}));
              vis.dispatchEvent(new Event('change', {bubbles:true}));
              var ev = document.createEvent('HTMLEvents'); ev.initEvent('keyup', true, false); vis.dispatchEvent(ev);
            } catch(e){}
          }

          // Button
          var btn = document.querySelector("#PostParametersButton, .dx-button");
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
    final pad = MediaQuery.of(context).size.width > 500 ? 24.0 : 16.0;
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
        padding: EdgeInsets.all(pad),
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
