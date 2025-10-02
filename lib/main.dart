import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Notification Service
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = 
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    // Initialize notifications
    await _initializeNotifications();
  } catch (e) {
    print('Notification initialization error: $e');
    // App läuft weiter ohne Notifications
  }
  
  runApp(const OptimizerApp());
}

// Initialize notifications
Future<void> _initializeNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}

// Simplified vehicle check (removed background service)
Future<bool> _simulateVehicleCheck() async {
  // Simple check without background service
  return false;
}

// Real vehicle detection function (to be called from WebShell)
Future<bool> checkVehiclePluggedIn(WebViewController controller) async {
  try {
    final js = '''
      (function(){
        // Check for specific SVG text elements that show vehicle status
        var statusTexts = [
          'Home, Ready',
          'Away',
          'Charging',
          'Connected',
          'Plugged'
        ];
        
        // Look for SVG text elements with specific IDs or content
        var svgTexts = document.querySelectorAll('text[id*="text860"], text[id*="tspan858"]');
        
        for (var i = 0; i < svgTexts.length; i++) {
          var text = svgTexts[i].textContent.trim();
          console.log('Found SVG text: "' + text + '"');
          
          // Check if text indicates vehicle is plugged in
          if (text === 'Home, Ready' || text === 'Charging' || text === 'Connected' || text === 'Plugged') {
            return true;
          }
        }
        
        // Fallback: Look for any text containing these status indicators
        var allTexts = document.querySelectorAll('text, span, div, p');
        for (var i = 0; i < allTexts.length; i++) {
          var text = allTexts[i].textContent.trim();
          if (text === 'Home, Ready' || text === 'Charging' || text === 'Connected' || text === 'Plugged') {
            return true;
          }
        }
        
        return false;
      })();
    ''';
    
    final result = await controller.runJavaScriptReturningResult(js);
    print('Vehicle detection result: $result');
    return result.toString() == 'true';
  } catch (e) {
    print('Error in vehicle detection: $e');
    return false;
  }
}

// Show notification when vehicle is plugged in
Future<void> _showVehicleNotification() async {
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    'vehicle_channel',
    'Vehicle Notifications',
    channelDescription: 'Notifications when vehicle is plugged in',
    importance: Importance.max,
    priority: Priority.high,
    icon: '@mipmap/ic_launcher',
  );
  
  const NotificationDetails platformChannelSpecifics =
      NotificationDetails(android: androidPlatformChannelSpecifics);
  
  await flutterLocalNotificationsPlugin.show(
    0,
    'Fahrzeug eingesteckt!',
    'Ihr Fahrzeug wurde erkannt und kann geladen werden.',
    platformChannelSpecifics,
  );
}

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
      // Vehicle monitoring disabled to prevent WebView interference
    });
  }


  // ---------- Vehicle Monitoring (Disabled to prevent WebView issues) ----------
  void _startVehicleMonitoring() {
    // Vehicle monitoring disabled to prevent WebView interference
    print('Vehicle monitoring disabled to prevent WebView issues');
  }

  Future<void> _checkVehicleStatus() async {
    // Vehicle status checking disabled to prevent WebView interference
    print('Vehicle status checking disabled');
  }

  Future<void> _showVehicleNotification() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'vehicle_channel',
      'Vehicle Notifications',
      channelDescription: 'Notifications when vehicle is plugged in',
      importance: Importance.max,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      '🚗 Fahrzeug eingesteckt!',
      'Ihr Fahrzeug wurde erkannt und kann geladen werden.',
      platformChannelSpecifics,
    );
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
    print('🚗 Selecting vehicle: ${v.label} (index: ${v.index})');
    
    final js = '''
      (function(){
        var idx = ${v.index};
        var root = document.getElementById('vehicleSelection');
        if(!root) {
          console.log('❌ vehicleSelection element not found');
          return 'no_element';
        }

        console.log('🎯 Trying to select vehicle at index: ' + idx);

        // Methode 1: DevExtreme API mit mehreren Versuchen
        try{
          if(window.jQuery && jQuery.fn.dxSelectBox){
            var inst = jQuery(root).dxSelectBox('instance');
            if(inst){
              console.log('✅ Found DevExtreme SelectBox instance');
              
              // Hole alle verfügbaren Items
              var ds = inst.option('dataSource');
              var items = inst.option('items');
              var arr = [];
              
              if (Array.isArray(items)) {
                arr = items;
              } else if (ds && typeof ds.items === 'function') {
                arr = ds.items();
              } else if (ds && Array.isArray(ds._items)) {
                arr = ds._items;
              }

              console.log('📋 Available items: ' + arr.length);
              console.log('📋 Items: ' + JSON.stringify(arr));

              if (Array.isArray(arr) && arr.length > idx){
                var item = arr[idx];
                console.log('🎯 Selecting item: ' + JSON.stringify(item));
                
                // Versuche verschiedene Methoden nacheinander
                try {
                  // Methode 1: selectedIndex (oft am zuverlässigsten)
                  inst.option('selectedIndex', idx);
                  console.log('✅ Set selectedIndex: ' + idx);
                  
                  // Methode 2: selectedItem
                  inst.option('selectedItem', item);
                  console.log('✅ Set selectedItem');
                  
                  // Methode 3: value
                var valueExpr = inst.option('valueExpr');
                  if (typeof valueExpr === 'string' && item[valueExpr] !== undefined) {
                  inst.option('value', item[valueExpr]);
                    console.log('✅ Set value: ' + item[valueExpr]);
                  }
                  
                  // Schließe das Dropdown
                  inst.option('opened', false);
                  
                  // Trigger change event manuell
                  var changeEvent = new Event('change', { bubbles: true });
                  root.dispatchEvent(changeEvent);
                  
                  // Zusätzlich: Trigger input event
                  var inputEvent = new Event('input', { bubbles: true });
                  var input = root.querySelector('input');
                  if (input) {
                    input.dispatchEvent(inputEvent);
                  }
                  
                  console.log('✅ All methods applied');
                  return 'success';
                } catch(e) {
                  console.log('❌ Error setting selection: ' + e);
                }
              } else {
                console.log('❌ Not enough items or invalid index');
              }
            }
          }
        } catch(e) {
          console.log('❌ DevExtreme method failed: ' + e);
        }

        // Methode 2: DOM Click Simulation (Fallback)
        try{
          console.log('🖱️ Trying DOM click method');
          
          // Öffne das Dropdown
          var clickEvent = new MouseEvent('click', { bubbles: true });
          root.dispatchEvent(clickEvent);
          
          // Warte und klicke auf das Item
          setTimeout(function(){
            var dropdown = document.querySelector('.dx-selectbox-popup');
            if (dropdown) {
              var items = dropdown.querySelectorAll('.dx-item');
              console.log('📋 Found ' + items.length + ' dropdown items');
              
              if (items.length > idx) {
                console.log('🖱️ Clicking on item ' + idx);
                items[idx].click();
            return 'clicked_dom';
          }
            }
          }, 500);
          
          return 'clicked_dom';
        } catch(e) {
          console.log('❌ DOM click failed: ' + e);
        }
        
        return 'failed';
      })();
    ''';

    try {
      final res = await _main.runJavaScriptReturningResult(js);
      final result = res.toString();
      print('🚗 Vehicle selection result: $result');
      
      // Warte auf Datenaktualisierung
      await Future.delayed(const Duration(milliseconds: 2000));
      
      // Verifikation mit mehreren Versuchen
      final verifyJs = '''
        (function(){
          var root = document.getElementById('vehicleSelection');
          if(!root) return 'no_element';
          
          var selectedText = '';
          var selectedValue = '';
          
          try{
            if(window.jQuery && jQuery.fn.dxSelectBox){
              var inst = jQuery(root).dxSelectBox('instance');
              if(inst){
                var sel = inst.option('selectedItem');
                var val = inst.option('value');
                var idx = inst.option('selectedIndex');
                selectedValue = val || '';
                
                console.log('🔍 Verification - selectedItem: ' + JSON.stringify(sel));
                console.log('🔍 Verification - value: ' + val);
                console.log('🔍 Verification - selectedIndex: ' + idx);
                
                if(sel && typeof sel === 'object'){
                  var displayExpr = inst.option('displayExpr');
                  if (typeof displayExpr === 'string' && sel[displayExpr]) {
                    selectedText = sel[displayExpr];
                  } else {
                    selectedText = sel.text || sel.name || sel.label || sel.value || '';
                  }
                }
              }
            }
          } catch(e) {
            console.log('❌ Error in verification: ' + e);
          }
          
          if(!selectedText){
            var input = root.querySelector('.dx-texteditor-input');
            if(input) selectedText = input.value;
          }
          
          console.log('✅ Verification - Selected: "' + selectedText + '", Value: "' + selectedValue + '"');
          
          var expectedText = '${v.label.replaceAll("'", "\\'")}';
          var isCorrect = selectedText.includes(expectedText) || expectedText.includes(selectedText);
          
          return isCorrect ? 'verified' : 'not_verified';
        })();
      ''';
      
      final verifyRes = await _main.runJavaScriptReturningResult(verifyJs);
      final verifyResult = verifyRes.toString();
      print('✅ Vehicle selection verification: $verifyResult');
      
      return '$result|$verifyResult';
    } catch (e) {
      print('❌ Vehicle selection error: $e');
      return 'error';
    }
  }

  // Debug-Funktion für Fahrzeugauswahl
  Future<void> _debugVehicleSelection() async {
    final debugJs = '''
      (function(){
        var root = document.getElementById('vehicleSelection');
        if(!root) {
          console.log('❌ vehicleSelection element not found');
          return 'no_element';
        }
        
        console.log('🔍 Debug: vehicleSelection element found');
        
        if(window.jQuery && jQuery.fn.dxSelectBox){
          var inst = jQuery(root).dxSelectBox('instance');
          if(inst){
            console.log('✅ DevExtreme instance found');
            var ds = inst.option('dataSource');
            var items = inst.option('items');
            var selectedItem = inst.option('selectedItem');
            var value = inst.option('value');
            var selectedIndex = inst.option('selectedIndex');
            
            console.log('📋 DataSource: ' + JSON.stringify(ds));
            console.log('📋 Items: ' + JSON.stringify(items));
            console.log('📋 Selected Item: ' + JSON.stringify(selectedItem));
            console.log('📋 Value: ' + value);
            console.log('📋 Selected Index: ' + selectedIndex);
            
            return 'debug_success';
          }
        }
        
        return 'no_instance';
      })();
    ''';
    
    try {
      final result = await _main.runJavaScriptReturningResult(debugJs);
      print('🔍 Debug result: $result');
    } catch (e) {
      print('❌ Debug error: $e');
    }
  }

  // ---------- Startmenü-Aktion: nur „Auto" ----------
  Future<void> _openAuto() async {
    setState(() => _showStartMenu = false);
    await _main.loadRequest(Uri.parse(startVehicleUrl));

    // Prüfen ob wir auf der Login-Seite sind
    final currentUrl = await _main.currentUrl();
    if (currentUrl != null && await _isB2CLoginDom()) {
      // Auf Login-Seite - kein Sheet anzeigen
      return;
    }

    // Fahrzeuge ermitteln (automatisch neu scannen, falls leer)
    final vehicles = await _scanVehiclesWithPolling();

    // 1 Fahrzeug -> direkt wählen und sofort Laden-Sheet
    if (vehicles.length == 1) {
      print('🚗 Auto-selecting vehicle: ${vehicles.first.label}');
      await _debugVehicleSelection(); // Debug vor Auswahl
      await _selectVehicle(vehicles.first);
      await Future.delayed(const Duration(milliseconds: 1000)); // Kurz warten
      await _debugVehicleSelection(); // Debug nach Auswahl
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
        print('🚗 User selected vehicle: ${chosen.label}');
        await _debugVehicleSelection(); // Debug vor Auswahl
        await _selectVehicle(chosen);
        await Future.delayed(const Duration(milliseconds: 1000)); // Kurz warten
        await _debugVehicleSelection(); // Debug nach Auswahl
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
      isDismissible: true,
      enableDrag: true,
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
        onVehicleChanged: () async {
          // Warte kurz damit die WebView-Daten aktualisiert werden
          await Future.delayed(const Duration(milliseconds: 1500));
          print('🔄 Vehicle changed - data should be refreshed');
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
              } else if (v == 'test_notification') {
                await _showVehicleNotification();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Test-Benachrichtigung gesendet!')),
                  );
                }
              } else if (v == 'check_status') {
                final isPluggedIn = await checkVehiclePluggedIn(_main);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Fahrzeug Status: ${isPluggedIn ? "Eingesteckt" : "Nicht eingesteckt"}'),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
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
                // Erst abmelden, dann zur Login-Seite weiterleiten
                await _main.loadRequest(
                    Uri.parse('https://soleco-optimizer.ch/Account/SignOut'));
                // Kurz warten und dann zur Login-Seite
                await Future.delayed(const Duration(milliseconds: 1000));
                await _main.loadRequest(Uri.parse(startVehicleUrl));
                _didAutoLogin = false;
                setState(() => _showStartMenu = true);
              }
            },
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'views', child: Text('Zu Ansichten')),
              PopupMenuItem(value: 'vehicle', child: Text('Zu Fahrzeuge')),
              PopupMenuItem(value: 'creds', child: Text('Login speichern/ändern')),
              PopupMenuItem(value: 'test_notification', child: Text('Test Benachrichtigung')),
              PopupMenuItem(value: 'check_status', child: Text('Status prüfen')),
              PopupMenuItem(value: 'logout', child: Text('Abmelden')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _main),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
      floatingActionButton: _showStartMenu
          ? null
          : Container(
              margin: const EdgeInsets.only(bottom: 100), // Höher positionieren
              child: FloatingActionButton.extended(
              onPressed: () => setState(() => _showStartMenu = true),
              backgroundColor: Brand.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.home),
              label: const Text('Start'),
              ),
            ),
      bottomSheet: _showStartMenu
          ? Container(
              height: MediaQuery.of(context).size.height * 0.35, // Feste Höhe, blockiert nicht den ganzen Screen
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  // Handle zum Ziehen
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // StartMenu Inhalt
                  Expanded(
                    child: StartMenu(
                      onClose: () => setState(() => _showStartMenu = false),
              onAuto: _openAuto,
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

/// Startmenü – schwebende Karte unten (nur noch „Auto“)
class StartMenu extends StatelessWidget {
  final VoidCallback? onClose;
  final VoidCallback onAuto;
  
  const StartMenu({
    super.key, 
    this.onClose,
    required this.onAuto,
  });

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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Schnellstart',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if (onClose != null)
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
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
  final Future<void> Function()? onVehicleChanged;
  const ChargingSheet({
    super.key,
    required this.defaultMinutes,
    required this.webViewController,
    required this.onStart,
    this.onVehicleChanged,
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

  @override
  void initState() {
    super.initState();
    // Lade Daten sofort und dann nochmal nach kurzer Verzögerung
    _loadVehicleData();
    // Zusätzlicher Versuch nach 3 Sekunden für den Fall dass die WebView-Daten noch nicht aktualisiert sind
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        print('🔄 Auto-refreshing vehicle data after 3 seconds...');
        _loadVehicleData();
      }
    });
  }

  // Funktion um Daten neu zu laden (wird aufgerufen wenn Fahrzeug gewechselt wird)
  void refreshVehicleData() {
    _loadVehicleData();
  }

  // Erweiterte Funktion um Daten nach Fahrzeugwechsel zu laden
  Future<void> refreshVehicleDataAfterSelection() async {
    print('🔄 Refreshing vehicle data after selection...');
    // Warte länger damit die WebView-Daten vollständig aktualisiert sind
    await Future.delayed(const Duration(milliseconds: 2000));
    await _loadVehicleData();
  }

  Future<void> _loadVehicleData() async {
    // Daten aus der WebView sammeln
    try {
      setState(() => _busy = true);
      
      print('🔄 Loading vehicle data...');
      
      // Warten kurz, damit die Seite vollständig geladen ist
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Current Range aus VehicleAppointments sammeln - erweiterte Suche
      final currentRangeJs = '''
        (function(){
          console.log('🔍 Searching for current range...');
          
          // Zuerst: Aktuell ausgewähltes Fahrzeug ermitteln
          var selectedVehicle = '';
          var vehicleSelection = document.getElementById('vehicleSelection');
          if (vehicleSelection) {
            var input = vehicleSelection.querySelector('.dx-texteditor-input');
            if (input) {
              selectedVehicle = input.value || '';
              console.log('🚗 Currently selected vehicle: ' + selectedVehicle);
            }
          }
          
          // Methode 1: Direkte Input-Felder
          var selectors = [
            'input[name="CurrentRange"]',
            'input[id*="CurrentRange"]',
            'input[aria-valuenow]',
            '.dx-numberbox input[value]',
            'input[type="text"][readonly]',
            'input[type="hidden"][name="CurrentRange"]'
          ];
          
          for (var i = 0; i < selectors.length; i++) {
            var inputs = document.querySelectorAll(selectors[i]);
            console.log('Selector ' + selectors[i] + ' found ' + inputs.length + ' elements');
            for (var j = 0; j < inputs.length; j++) {
              var input = inputs[j];
              var value = input.value || input.getAttribute('aria-valuenow') || input.getAttribute('value');
              if (value && !isNaN(parseInt(value))) {
                var num = parseInt(value);
                if (num > 0 && num < 1000) { // Realistische Range
                  console.log('✅ Current Range gefunden: ' + num + ' with selector: ' + selectors[i]);
                  return num;
                }
              }
            }
          }
          
          // Methode 2: Suche nach Zahlen in der Nähe von "km" Text
          var allElements = document.querySelectorAll('*');
          for (var i = 0; i < allElements.length; i++) {
            var text = allElements[i].textContent || '';
            var match = text.match(/(\d+)\s*km/i);
            if (match && parseInt(match[1]) > 50 && parseInt(match[1]) < 1000) {
              console.log('✅ Current Range aus Text gefunden: ' + match[1]);
              return parseInt(match[1]);
            }
          }
          
          // Methode 3: Suche nach DevExtreme-Werten
          var dxElements = document.querySelectorAll('.dx-numberbox, .dx-textbox');
          for (var i = 0; i < dxElements.length; i++) {
            var input = dxElements[i].querySelector('input');
            if (input) {
              var val = input.value || input.getAttribute('value');
              if (val && !isNaN(parseInt(val)) && parseInt(val) > 0 && parseInt(val) < 1000) {
                console.log('✅ Current Range via DevExtreme: ' + val);
                return parseInt(val);
              }
            }
          }
          
          console.log('❌ No current range found');
          return null;
        })();
      ''';
      
      // Max Range aus Settings/VehiclesConfig sammeln - erweiterte Suche
      final maxRangeJs = '''
        (function(){
          console.log('🔍 Searching for max range...');
          
          // Zuerst: Aktuell ausgewähltes Fahrzeug ermitteln
          var selectedVehicle = '';
          var vehicleSelection = document.getElementById('vehicleSelection');
          if (vehicleSelection) {
            var input = vehicleSelection.querySelector('.dx-texteditor-input');
            if (input) {
              selectedVehicle = input.value || '';
              console.log('🚗 Currently selected vehicle for max range: ' + selectedVehicle);
            }
          }
          
          // Methode 1: Direkte Input-Felder
          var selectors = [
            'input[name="DistanceMax"]',
            'input[id*="DistanceMax"]',
            'input[id*="Max"]',
            'input[aria-valuemax]',
            '.dx-numberbox input[value]',
            'input[type="text"][readonly]',
            'input[type="hidden"][name="DistanceMax"]'
          ];
          
          for (var i = 0; i < selectors.length; i++) {
            var inputs = document.querySelectorAll(selectors[i]);
            console.log('Selector ' + selectors[i] + ' found ' + inputs.length + ' elements');
            for (var j = 0; j < inputs.length; j++) {
              var input = inputs[j];
              var value = input.value || input.getAttribute('aria-valuemax') || input.getAttribute('value');
              if (value && !isNaN(parseInt(value))) {
                var num = parseInt(value);
                if (num > 200 && num < 1000) { // Realistische Max Range
                  console.log('✅ Max Range gefunden: ' + num + ' with selector: ' + selectors[i]);
                  return num;
                }
              }
            }
          }
          
          // Methode 2: Suche nach größeren Zahlen in der Nähe von "km" Text
          var allElements = document.querySelectorAll('*');
          for (var i = 0; i < allElements.length; i++) {
            var text = allElements[i].textContent || '';
            var match = text.match(/(\d+)\s*km/i);
            if (match && parseInt(match[1]) > 200 && parseInt(match[1]) < 1000) {
              console.log('✅ Max Range aus Text gefunden: ' + match[1]);
              return parseInt(match[1]);
            }
          }
          
          // Methode 3: Suche nach DevExtreme-Werten
          var dxElements = document.querySelectorAll('.dx-numberbox, .dx-textbox');
          for (var i = 0; i < dxElements.length; i++) {
            var input = dxElements[i].querySelector('input');
            if (input) {
              var val = input.value || input.getAttribute('value');
              if (val && !isNaN(parseInt(val)) && parseInt(val) > 200 && parseInt(val) < 1000) {
                console.log('✅ Max Range via DevExtreme: ' + val);
                return parseInt(val);
              }
            }
          }
          
          console.log('❌ No max range found');
          return null;
        })();
      ''';
      
      print('🚗 Lade echte Fahrzeugdaten...');
      final currentRangeResult = await widget.webViewController.runJavaScriptReturningResult(currentRangeJs);
      final maxRangeResult = await widget.webViewController.runJavaScriptReturningResult(maxRangeJs);
      
      print('🚗 Current Range Result: $currentRangeResult');
      print('🚗 Max Range Result: $maxRangeResult');
      
      final currentRange = int.tryParse(currentRangeResult.toString()) ?? 0;
      final maxRange = int.tryParse(maxRangeResult.toString()) ?? 0;
      
      // Nur setzen wenn wir echte Werte haben
      if (currentRange > 0 && maxRange > 0) {
        setState(() {
          _currentRange = currentRange;
          _maxRange = maxRange;
        });
        print('✅ Echte Fahrzeugdaten geladen: Current: $currentRange km, Max: $maxRange km');
        
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
        // Fallback zu realistischen Testwerten
        setState(() {
          _currentRange = 184;
          _maxRange = 455;
        });
        print('⚠️ Fallback zu Testwerten: Current: 184 km, Max: 455 km');
        
        // Zeige Warnung
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Testwerte verwendet - echte Daten nicht gefunden'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      
      _calculateQuickCharge();
    } catch (e) {
      print('❌ Fehler beim Laden der Fahrzeugdaten: $e');
      // Fallback zu Testwerten
      setState(() {
        _currentRange = 184;
        _maxRange = 455;
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  void _calculateQuickCharge() {
    final targetRange = (_maxRange * _chargePercentage / 100).round();
    final rangeToCharge = targetRange - _currentRange;
    
    // Einfache Berechnung: 1 km = 2 Minuten (kann angepasst werden)
    _calculatedMinutes = (rangeToCharge * 2).clamp(0, 600);
    
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6, // Kleiner machen
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          
          // Hauptslider (0-100%)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  'Ladung: ${_chargePercentage.round()}%',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Brand.primary,
                  ),
                ),
                const SizedBox(height: 16),
                _buildMainSlider(),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0%', style: TextStyle(color: Colors.grey[600])),
                    Text('100%', style: TextStyle(color: Colors.grey[600])),
                  ],
                ),
              ],
            ),
          ),
          
          // PageView für die beiden Seiten
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) => setState(() => _currentPage = index),
              children: [
                _buildPlannedPage(),
                _buildQuickChargePage(),
              ],
            ),
          ),
          
          // Page Indicator
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildPageIndicator(0),
                const SizedBox(width: 8),
                _buildPageIndicator(1),
              ],
            ),
          ),
        ],
      ),
    );
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
          const SizedBox(height: 24), // Extra Platz am Ende für Scrollbarkeit
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
                  await refreshVehicleDataAfterSelection();
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
                  _currentRange == 184 && _maxRange == 455 
                    ? '⚠️ Testwerte - Daten werden aus WebView geladen...' 
                    : '✅ Echte Fahrzeugdaten geladen',
                  style: TextStyle(
                    fontSize: 12,
                    color: _currentRange == 184 && _maxRange == 455 ? Colors.orange : Colors.green,
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
          
          // Quick Charge Button (ohne Spacer, direkt nach der Berechnung)
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : () {
                // Für Test: Nur Berechnung anzeigen
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Quick Charge würde $_calculatedMinutes Minuten laden'),
                    backgroundColor: Brand.primary,
                  ),
                );
                  },
            icon: const Icon(Icons.flash_on),
              label: Text(_busy ? 'Berechne...' : 'Quick Charge'),
              style: FilledButton.styleFrom(
                backgroundColor: Brand.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
          ),
            ),
          ),
          const SizedBox(height: 24), // Extra Platz am Ende für Scrollbarkeit
        ],
      ),
    );
  }
}
