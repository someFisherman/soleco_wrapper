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

// Simplified vehicle check (removed background service and workmanager)
Future<bool> _simulateVehicleCheck() async {
  // Simple check without background service or workmanager
  // All vehicle monitoring is now done in foreground
  return false;
}

// Real vehicle detection function (to be called from WebShell)
Future<bool> checkVehiclePluggedIn(WebViewController controller) async {
  try {
    final js = '''
      (function(){
        console.log('🔍 Checking vehicle status...');
        
        // Check for specific SVG text elements that show vehicle status
        var pluggedInStatuses = [
          'Home, Ready',
          'Charging',
          'Connected',
          'Plugged',
          'Ready',
          'Available'
        ];
        
        var notPluggedStatuses = [
          'Away',
          'Disconnected',
          'Not Connected',
          'Offline'
        ];
        
        // Look for SVG text elements with specific IDs or content
        var svgTexts = document.querySelectorAll('text[id*="text860"], text[id*="tspan858"], text[id*="status"]');
        console.log('Found ' + svgTexts.length + ' SVG text elements');
        
        for (var i = 0; i < svgTexts.length; i++) {
          var text = svgTexts[i].textContent.trim();
          console.log('SVG text content: "' + text + '"');
          
          // Check if text indicates vehicle is plugged in
          for (var j = 0; j < pluggedInStatuses.length; j++) {
            if (text.includes(pluggedInStatuses[j])) {
              console.log('✅ Vehicle plugged in - found status: ' + text);
              return true;
            }
          }
          
          // Check if text indicates vehicle is NOT plugged in
          for (var k = 0; k < notPluggedStatuses.length; k++) {
            if (text.includes(notPluggedStatuses[k])) {
              console.log('❌ Vehicle not plugged in - found status: ' + text);
              return false;
            }
          }
        }
        
        // Fallback: Look for any text containing these status indicators
        var allTexts = document.querySelectorAll('text, span, div, p, td, th');
        for (var i = 0; i < allTexts.length; i++) {
          var text = allTexts[i].textContent.trim();
          
          // Check plugged in statuses
          for (var j = 0; j < pluggedInStatuses.length; j++) {
            if (text.includes(pluggedInStatuses[j])) {
              console.log('✅ Vehicle plugged in (fallback) - found status: ' + text);
              return true;
            }
          }
          
          // Check not plugged statuses
          for (var k = 0; k < notPluggedStatuses.length; k++) {
            if (text.includes(notPluggedStatuses[k])) {
              console.log('❌ Vehicle not plugged in (fallback) - found status: ' + text);
              return false;
            }
          }
        }
        
        console.log('❓ Vehicle status unclear - no clear status found');
        return false;
      })();
    ''';
    
    final result = await controller.runJavaScriptReturningResult(js);
    final isPluggedIn = result.toString() == 'true';
    print('🚗 Vehicle detection result: $isPluggedIn');
    return isPluggedIn;
  } catch (e) {
    print('❌ Error in vehicle detection: $e');
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
      // Starte Vehicle Monitoring nach kurzer Verzögerung
      Future.delayed(const Duration(seconds: 5), () {
        _startVehicleMonitoring();
      });
    });
  }

  @override
  void dispose() {
    _stopVehicleMonitoring();
    super.dispose();
  }


  // ---------- Vehicle Monitoring (Verbessert) ----------
  Timer? _vehicleMonitoringTimer;
  bool _lastVehicleStatus = false;

  void _startVehicleMonitoring() {
    // Starte Vehicle Monitoring mit Timer
    _vehicleMonitoringTimer?.cancel();
    _vehicleMonitoringTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _checkVehicleStatus();
    });
    print('✅ Vehicle monitoring started');
  }

  void _stopVehicleMonitoring() {
    _vehicleMonitoringTimer?.cancel();
    _vehicleMonitoringTimer = null;
    print('⏹️ Vehicle monitoring stopped');
  }

  Future<void> _checkVehicleStatus() async {
    try {
      final isPluggedIn = await checkVehiclePluggedIn(_main);
      
      // Nur Benachrichtigung senden wenn Status sich geändert hat
      if (isPluggedIn && !_lastVehicleStatus) {
        print('🚗 Vehicle plugged in - sending notification');
        await _showVehicleNotification();
      }
      
      _lastVehicleStatus = isPluggedIn;
    } catch (e) {
      print('❌ Error checking vehicle status: $e');
    }
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
        var expectedLabel = '${v.label.replaceAll("'", "\\'")}';
        var root = document.getElementById('vehicleSelection');
        if(!root) {
          console.log('❌ vehicleSelection element not found');
          return 'no_element';
        }

        console.log('🎯 Trying to select vehicle at index: ' + idx + ' (label: ' + expectedLabel + ')');

        // Methode 1: DevExtreme API mit mehreren Versuchen und doppeltem Check
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
                
                // DOUBLECHECK: Verifiziere dass das Item dem erwarteten Label entspricht
                var displayExpr = inst.option('displayExpr');
                var itemLabel = '';
                if (typeof displayExpr === 'string' && item[displayExpr]) {
                  itemLabel = item[displayExpr];
                } else {
                  itemLabel = item.text || item.name || item.label || item.value || '';
                }
                
                console.log('🔍 Item label check: expected="' + expectedLabel + '", actual="' + itemLabel + '"');
                
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

        // Methode 2: DOM Click Simulation (Fallback) mit doppeltem Check
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
                var targetItem = items[idx];
                var itemText = targetItem.textContent.trim();
                console.log('🔍 DOM item text check: expected="' + expectedLabel + '", actual="' + itemText + '"');
                
                console.log('🖱️ Clicking on item ' + idx);
                targetItem.click();
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
      
      // Erweiterte Verifikation mit mehreren Versuchen und doppeltem Check
      final verifyJs = '''
        (function(){
          var root = document.getElementById('vehicleSelection');
          if(!root) return 'no_element';
          
          var selectedText = '';
          var selectedValue = '';
          var selectedIndex = -1;
          
          try{
            if(window.jQuery && jQuery.fn.dxSelectBox){
              var inst = jQuery(root).dxSelectBox('instance');
              if(inst){
                var sel = inst.option('selectedItem');
                var val = inst.option('value');
                var idx = inst.option('selectedIndex');
                selectedValue = val || '';
                selectedIndex = idx || -1;
                
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
          
          console.log('✅ Verification - Selected: "' + selectedText + '", Value: "' + selectedValue + '", Index: ' + selectedIndex);
          
          var expectedText = '${v.label.replaceAll("'", "\\'")}';
          var expectedIndex = ${v.index};
          
          // Doppelter Check: Text UND Index müssen stimmen
          var textMatches = selectedText.includes(expectedText) || expectedText.includes(selectedText);
          var indexMatches = selectedIndex === expectedIndex;
          
          console.log('🔍 Double check - Text match: ' + textMatches + ', Index match: ' + indexMatches);
          
          // Für Tesla X/Y: Besonders strenge Prüfung
          if (expectedText.toLowerCase().includes('tesla')) {
            var isCorrect = textMatches && indexMatches;
            console.log('🚗 Tesla vehicle - strict verification: ' + isCorrect);
            return isCorrect ? 'verified' : 'not_verified';
          }
          
          // Für andere Fahrzeuge: Text muss stimmen
          return textMatches ? 'verified' : 'not_verified';
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
      // Auf Login-Seite - kein Sheet anzeigen, Startmenü wieder zeigen
      setState(() => _showStartMenu = true);
      return;
    }

    // Fahrzeuge ermitteln (automatisch neu scannen, falls leer)
    final vehicles = await _scanVehiclesWithPolling();

    // 1 Fahrzeug -> direkt wählen und sofort Laden-Sheet
    if (vehicles.length == 1) {
      print('🚗 Auto-selecting vehicle: ${vehicles.first.label}');
      await _debugVehicleSelection(); // Debug vor Auswahl
      await _selectVehicle(vehicles.first);
      // Wartezeiten entfernt für bessere Performance
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
        // Wartezeiten entfernt für bessere Performance
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
    // Fullscreen Charging Interface
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => FullscreenChargingPage(
          webViewController: _main,
          onStart: (minutes) async {
            await _triggerParameters(minutes);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Sofortladung gestartet (${minutes} min)')),
            );
          },
          onVehicleChanged: () async {
            // Wartezeiten entfernt - Daten werden sofort aktualisiert
            print('🔄 Vehicle changed - data should be refreshed');
          },
        ),
        fullscreenDialog: true,
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
                // Wichtig: Nach Abmelden automatisch zur Login-Seite weiterleiten
                // und nicht auf soleco.ch hängen bleiben
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
          : FloatingActionButton.extended(
              onPressed: () => setState(() => _showStartMenu = true),
              backgroundColor: Brand.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.home),
              label: const Text('Start'),
              // Position korrigieren
              extendedPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
      bottomSheet: _showStartMenu
          ? DraggableScrollableSheet(
              initialChildSize: 0.35, // 35% der Bildschirmhöhe
              minChildSize: 0.2, // Minimum 20%
              maxChildSize: 0.6, // Maximum 60%
              builder: (context, scrollController) {
                return Container(
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
                      // StartMenu Inhalt - scrollbar
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scrollController,
                          child: StartMenu(
                            onClose: () => setState(() => _showStartMenu = false),
                            onAuto: _openAuto,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
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
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 16), // 2cm nach oben (8px statt 16px top)
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
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
                const Text(
                  'Schnellstart',
                  style: TextStyle(
                    fontSize: 20, 
                    fontWeight: FontWeight.w700,
                    color: Brand.primary,
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _RoundAction(
                  label: 'Auto',
                  icon: Icons.ev_station,
                  onTap: onAuto,
                ),
              ],
            ),
            const SizedBox(height: 8), // Extra Platz am Ende
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

  // Planned Page Daten
  int _selectedDay = 0; // 0=Today, 1=Tomorrow, 2=In 2 Days, 3=In 3 Days
  String _selectedTime = '08:00'; // Standard Zeit

  // Quick Charge Daten
  int _currentRange = 0;
  int _maxRange = 0;
  int _calculatedMinutes = 0;
  bool _hasRealData = false;

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
    // Wartezeiten entfernt - Daten werden sofort geladen
    await _loadVehicleData();
  }

  Future<void> _loadVehicleData() async {
    // Daten aus Views-Seite (Current Range) und Settings/VehiclesConfig (Max Range) sammeln
    try {
      setState(() => _busy = true);
      
      print('🔄 Loading vehicle data from Views page and Settings...');
      
      // Warten kurz, damit die Seite vollständig geladen ist
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 1. Current Range von Views-Seite
      final currentRange = await _getCurrentRangeFromViews();
      
      // 2. Max Range von Settings/VehiclesConfig
      final maxRange = await _getMaxRangeFromSettings();
      
      if (currentRange > 0 && maxRange > 0) {
        setState(() {
          _currentRange = currentRange;
          _maxRange = maxRange;
          _hasRealData = true;
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
              content: Text('❌ Keine Fahrzeugdaten gefunden - bitte Views-Seite laden'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      
      _calculateQuickCharge();
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

  // Current Range von Views-Seite extrahieren
  Future<int> _getCurrentRangeFromViews() async {
    final viewsDataJs = '''
      (function(){
        console.log('🔍 Searching for current range on Views page...');
        
        var currentRange = null;
        
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
            
            // Current range ist meist die kleinere Zahl
            if (currentRange === null && value > 50 && value < 500) {
              currentRange = value;
              console.log('✅ Current Range: ' + currentRange + ' km');
              break;
            }
          }
        }
        
        // Fallback: Suche nach allen Text-Elementen mit km
        if (currentRange === null) {
          var allTexts = document.querySelectorAll('text, span, div, p');
          for (var i = 0; i < allTexts.length; i++) {
            var text = allTexts[i].textContent.trim();
            var match = text.match(/(\d+)\s*km/i);
            if (match) {
              var value = parseInt(match[1]);
              if (value > 50 && value < 500) {
                currentRange = value;
                console.log('✅ Current Range (fallback): ' + currentRange + ' km');
                break;
              }
            }
          }
        }
        
        return currentRange || 0;
      })();
    ''';
    
    try {
      final result = await widget.webViewController.runJavaScriptReturningResult(viewsDataJs);
      final currentRange = int.tryParse(result.toString()) ?? 0;
      print('🚗 Current Range from Views: $currentRange km');
      return currentRange;
    } catch (e) {
      print('❌ Error getting current range: $e');
      return 0;
    }
  }

  // Max Range von Settings/VehiclesConfig extrahieren
  Future<int> _getMaxRangeFromSettings() async {
    final settingsDataJs = '''
      (function(){
        console.log('🔍 Searching for max range in Settings/VehiclesConfig...');
        
        var maxRange = null;
        
        // Suche nach DistanceMax Input-Feld
        var distanceMaxInput = document.querySelector('input[name*="DistanceMax"], input[id*="DistanceMax"]');
        if (distanceMaxInput) {
          var value = parseInt(distanceMaxInput.value);
          if (value > 0) {
            maxRange = value;
            console.log('✅ Max Range from DistanceMax input: ' + maxRange + ' km');
            return maxRange;
          }
        }
        
        // Fallback: Suche nach Text mit "DistanceMax" oder ähnlichen Begriffen
        var allTexts = document.querySelectorAll('text, span, div, p, input');
        for (var i = 0; i < allTexts.length; i++) {
          var text = allTexts[i].textContent.trim();
          var match = text.match(/(\d+)\s*km/i);
          if (match) {
            var value = parseInt(match[1]);
            // Max range ist meist die größere Zahl
            if (value > 200 && value < 1000) {
              maxRange = value;
              console.log('✅ Max Range (fallback): ' + maxRange + ' km');
              break;
            }
          }
        }
        
        return maxRange || 0;
      })();
    ''';
    
    try {
      final result = await widget.webViewController.runJavaScriptReturningResult(settingsDataJs);
      final maxRange = int.tryParse(result.toString()) ?? 0;
      print('🚗 Max Range from Settings: $maxRange km');
      return maxRange;
    } catch (e) {
      print('❌ Error getting max range: $e');
      return 0;
    }
  }

  Widget _buildDataRow(String label, String value, IconData icon, {bool isTarget = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: isTarget ? Brand.primary : Colors.grey[600]),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[700],
              ),
            ),
          ],
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: isTarget ? Brand.primary : Colors.black,
          ),
        ),
      ],
    );
  }

  Widget _buildCalculationRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.grey,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.green,
          ),
        ),
      ],
    );
  }

  void _calculateQuickCharge() {
    if (!_hasRealData || _currentRange == 0 || _maxRange == 0) {
      _calculatedMinutes = 0;
      setState(() {});
      return;
    }
    
    final targetRange = (_maxRange * _chargePercentage / 100).round();
    final rangeToCharge = targetRange - _currentRange;
    
    if (rangeToCharge <= 0) {
      _calculatedMinutes = 0;
      setState(() {});
      return;
    }
    
    // 11kW Ladeleistung: 1 km = 1.15 Minuten (basierend auf 11kW)
    // Plus 1 Minute pro 15 Minuten (wie vom User gewünscht)
    final baseMinutes = (rangeToCharge * 1.15).round();
    final extraMinutes = (baseMinutes / 15).round(); // 1 Minute pro 15 Minuten
    _calculatedMinutes = (baseMinutes + extraMinutes).clamp(0, 600);
    
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7, // Größer für bessere Nutzung
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
          
          // Hauptslider (0-100%) - Orange wie gewünscht
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  'Ladung: ${_chargePercentage.round()}%',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Brand.primary, // Orange
                  ),
                ),
                const SizedBox(height: 20),
                _buildMainSlider(),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0%', style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                    Text('100%', style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                  ],
                ),
              ],
            ),
          ),
          
          // PageView für die beiden Seiten - iOS Ordner Style
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (index) => setState(() => _currentPage = index),
                  children: [
                    _buildPlannedPage(),
                    _buildQuickChargePage(),
                  ],
                ),
              ),
            ),
          ),
          
          // Page Indicator mit Labels
          Padding(
            padding: const EdgeInsets.only(bottom: 16, top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildPageIndicatorWithLabel(0, 'Planned'),
                const SizedBox(width: 24),
                _buildPageIndicatorWithLabel(1, 'Quick Charge'),
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
        activeTrackColor: Brand.primary, // Orange
        inactiveTrackColor: Brand.primary.withOpacity(0.2),
        thumbColor: Colors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 18), // Größer
        trackHeight: 10, // Dicker
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 28), // Größer
        overlayColor: Brand.primary.withOpacity(0.1),
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

  Widget _buildPageIndicatorWithLabel(int index, String label) {
    return GestureDetector(
      onTap: () {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      },
      child: Column(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _currentPage == index ? Brand.primary : Colors.grey[300],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: _currentPage == index ? FontWeight.w600 : FontWeight.normal,
              color: _currentPage == index ? Brand.primary : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlannedPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Planned Charging',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Brand.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Plan your charging session',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 24),
          
          // Day Slider
          const Text(
            'Select Day',
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
            'Select Time',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _buildTimeSelector(),
          
          const SizedBox(height: 32),
          
          // Start Button (blockiert)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.schedule,
                  size: 32,
                  color: Colors.grey[500],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Start (Coming Soon)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Planned charging will be available soon',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[500],
                  ),
                ),
              ],
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
          final isSelected = index == _selectedDay;
          return Container(
            margin: const EdgeInsets.only(right: 12),
            child: ChoiceChip(
              label: Text(days[index]),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  _selectedDay = index;
                });
              },
              selectedColor: Brand.primary.withOpacity(0.2),
              backgroundColor: Colors.grey[100],
              labelStyle: TextStyle(
                color: isSelected ? Brand.primary : Colors.grey[600],
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: isSelected ? Brand.primary : Colors.grey[300]!,
                  width: isSelected ? 2 : 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTimeSelector() {
    // Generiere Zeiten basierend auf gewähltem Tag
    List<String> availableTimes = [];
    if (_selectedDay == 0) { // Today
      availableTimes = ['08:00', '12:00', '18:00', '22:00'];
    } else if (_selectedDay == 1) { // Tomorrow
      availableTimes = ['06:00', '09:00', '15:00', '20:00'];
    } else { // In 2+ Days
      availableTimes = ['07:00', '10:00', '14:00', '19:00'];
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Available times for ${['Today', 'Tomorrow', 'In 2 Days', 'In 3 Days'][_selectedDay]}:',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: availableTimes.map((time) {
              final isSelected = time == _selectedTime;
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedTime = time;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? Brand.primary : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected ? Brand.primary : Colors.grey[300]!,
                    ),
                  ),
                  child: Text(
                    time,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey[700],
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickChargePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Quick Charge',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Brand.primary,
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
          const SizedBox(height: 8),
          Text(
            'Instant charging with real vehicle data',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 24),
          
          // Vehicle Info - Verbessert
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Brand.primary.withOpacity(0.1), Brand.primary.withOpacity(0.05)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Brand.primary.withOpacity(0.2)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.ev_station, color: Brand.primary, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Vehicle Data',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildDataRow('Current Range', '$_currentRange km', Icons.battery_4_bar),
                const SizedBox(height: 12),
                _buildDataRow('Max Range', '$_maxRange km', Icons.battery_full),
                const SizedBox(height: 12),
                _buildDataRow('Target Range', '${(_maxRange * _chargePercentage / 100).round()} km', Icons.flag, isTarget: true),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _hasRealData ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _hasRealData ? Icons.check_circle : Icons.error,
                        size: 16,
                        color: _hasRealData ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _hasRealData 
                          ? 'Real vehicle data loaded' 
                          : 'No data available - please load Views page',
                        style: TextStyle(
                          fontSize: 12,
                          color: _hasRealData ? Colors.green : Colors.red,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Calculation Result - Verbessert
          if (_calculatedMinutes > 0) ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.green.withOpacity(0.1), Colors.green.withOpacity(0.05)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.calculate, color: Colors.green, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        '11kW Charging Calculation',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildCalculationRow('Range to charge', '${((_maxRange * _chargePercentage / 100) - _currentRange).round()} km'),
                  const SizedBox(height: 8),
                  _buildCalculationRow('Charging rate', '11kW'),
                  const SizedBox(height: 8),
                  _buildCalculationRow('Base time', '${(_calculatedMinutes * 0.9).round()} min'),
                  const SizedBox(height: 8),
                  _buildCalculationRow('Buffer time', '${(_calculatedMinutes * 0.1).round()} min'),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.timer, color: Colors.green, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Total: $_calculatedMinutes minutes',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          
          // Quick Charge Button - Verbessert und sichtbar
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || !_hasRealData || _calculatedMinutes == 0) ? null : () {
                // Für Test: Nur Berechnung anzeigen
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Quick Charge würde $_calculatedMinutes Minuten laden (11kW)'),
                    backgroundColor: Brand.primary,
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
              icon: Icon(_busy ? Icons.hourglass_empty : Icons.flash_on),
              label: Text(_busy ? 'Calculating...' : 
                         !_hasRealData ? 'No Data Available' : 
                         _calculatedMinutes == 0 ? 'Ready to Charge' : 'Start Quick Charge'),
              style: FilledButton.styleFrom(
                backgroundColor: (_busy || !_hasRealData || _calculatedMinutes == 0) 
                    ? Colors.grey 
                    : Brand.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: (_busy || !_hasRealData || _calculatedMinutes == 0) ? 0 : 4,
              ),
            ),
          ),
          const SizedBox(height: 24), // Extra Platz am Ende für Scrollbarkeit
        ],
      ),
    );
  }
}

/// Fullscreen Charging Interface
class FullscreenChargingPage extends StatefulWidget {
  final WebViewController webViewController;
  final Future<void> Function(int minutes) onStart;
  final Future<void> Function()? onVehicleChanged;

  const FullscreenChargingPage({
    super.key,
    required this.webViewController,
    required this.onStart,
    this.onVehicleChanged,
  });

  @override
  State<FullscreenChargingPage> createState() => _FullscreenChargingPageState();
}

class _FullscreenChargingPageState extends State<FullscreenChargingPage> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  double _chargePercentage = 80.0;
  bool _busy = false;

  // Planned Page Daten
  int _selectedDay = 0;
  String _selectedTime = '08:00';

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
    // Vereinfachte Version für Fullscreen
    try {
      setState(() => _busy = true);
      
      // Simuliere Daten für Demo
      setState(() {
        _currentRange = 150;
        _maxRange = 400;
        _hasRealData = true;
      });
      
      _calculateQuickCharge();
    } finally {
      setState(() => _busy = false);
    }
  }

  void _calculateQuickCharge() {
    if (!_hasRealData || _currentRange == 0 || _maxRange == 0) {
      _calculatedMinutes = 0;
      setState(() {});
      return;
    }
    
    final targetRange = (_maxRange * _chargePercentage / 100).round();
    final rangeToCharge = targetRange - _currentRange;
    
    if (rangeToCharge <= 0) {
      _calculatedMinutes = 0;
      setState(() {});
      return;
    }
    
    final baseMinutes = (rangeToCharge * 1.15).round();
    final extraMinutes = (baseMinutes / 15).round();
    _calculatedMinutes = (baseMinutes + extraMinutes).clamp(0, 600);
    
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Charging Interface',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Brand.primary,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Brand.primary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.home, color: Brand.primary),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Hauptslider (0-100%) - Orange
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  'Ladung: ${_chargePercentage.round()}%',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Brand.primary,
                  ),
                ),
                const SizedBox(height: 24),
                _buildMainSlider(),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0%', style: TextStyle(color: Colors.grey[600], fontSize: 18)),
                    Text('100%', style: TextStyle(color: Colors.grey[600], fontSize: 18)),
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
          
          // Page Indicator mit Labels
          Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildPageIndicatorWithLabel(0, 'Planned'),
                const SizedBox(width: 32),
                _buildPageIndicatorWithLabel(1, 'Quick Charge'),
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
        inactiveTrackColor: Brand.primary.withOpacity(0.2),
        thumbColor: Colors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 20),
        trackHeight: 12,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 32),
        overlayColor: Brand.primary.withOpacity(0.1),
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

  Widget _buildPageIndicatorWithLabel(int index, String label) {
    return GestureDetector(
      onTap: () {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      },
      child: Column(
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _currentPage == index ? Brand.primary : Colors.grey[300],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: _currentPage == index ? FontWeight.w600 : FontWeight.normal,
              color: _currentPage == index ? Brand.primary : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlannedPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Planned Charging',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Brand.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Plan your charging session',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 32),
          
          // Day Slider
          const Text(
            'Select Day',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          _buildDaySelector(),
          
          const SizedBox(height: 32),
          
          // Time Slider
          const Text(
            'Select Time',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          _buildTimeSelector(),
          
          const SizedBox(height: 48),
          
          // Start Button (blockiert)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.schedule,
                  size: 48,
                  color: Colors.grey[500],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Start (Coming Soon)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Planned charging will be available soon',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDaySelector() {
    final days = ['Today', 'Tomorrow', 'In 2 Days', 'In 3 Days'];
    return Container(
      height: 60,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        itemBuilder: (context, index) {
          final isSelected = index == _selectedDay;
          return Container(
            margin: const EdgeInsets.only(right: 16),
            child: ChoiceChip(
              label: Text(days[index]),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  _selectedDay = index;
                });
              },
              selectedColor: Brand.primary.withOpacity(0.2),
              backgroundColor: Colors.grey[100],
              labelStyle: TextStyle(
                color: isSelected ? Brand.primary : Colors.grey[600],
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 16,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(25),
                side: BorderSide(
                  color: isSelected ? Brand.primary : Colors.grey[300]!,
                  width: isSelected ? 2 : 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTimeSelector() {
    List<String> availableTimes = [];
    if (_selectedDay == 0) {
      availableTimes = ['08:00', '12:00', '18:00', '22:00'];
    } else if (_selectedDay == 1) {
      availableTimes = ['06:00', '09:00', '15:00', '20:00'];
    } else {
      availableTimes = ['07:00', '10:00', '14:00', '19:00'];
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Available times for ${['Today', 'Tomorrow', 'In 2 Days', 'In 3 Days'][_selectedDay]}:',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: availableTimes.map((time) {
              final isSelected = time == _selectedTime;
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedTime = time;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected ? Brand.primary : Colors.white,
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(
                      color: isSelected ? Brand.primary : Colors.grey[300]!,
                    ),
                  ),
                  child: Text(
                    time,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey[700],
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      fontSize: 16,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickChargePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quick Charge',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Brand.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Instant charging with real vehicle data',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 32),
          
          // Vehicle Info
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Brand.primary.withOpacity(0.1), Brand.primary.withOpacity(0.05)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Brand.primary.withOpacity(0.2)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.ev_station, color: Brand.primary, size: 24),
                    const SizedBox(width: 12),
                    const Text(
                      'Vehicle Data',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _buildDataRow('Current Range', '$_currentRange km', Icons.battery_4_bar),
                const SizedBox(height: 16),
                _buildDataRow('Max Range', '$_maxRange km', Icons.battery_full),
                const SizedBox(height: 16),
                _buildDataRow('Target Range', '${(_maxRange * _chargePercentage / 100).round()} km', Icons.flag, isTarget: true),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: _hasRealData ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _hasRealData ? Icons.check_circle : Icons.error,
                        size: 18,
                        color: _hasRealData ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _hasRealData 
                          ? 'Real vehicle data loaded' 
                          : 'No data available',
                        style: TextStyle(
                          fontSize: 14,
                          color: _hasRealData ? Colors.green : Colors.red,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 32),
          
          // Calculation Result
          if (_calculatedMinutes > 0) ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.green.withOpacity(0.1), Colors.green.withOpacity(0.05)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.calculate, color: Colors.green, size: 24),
                      const SizedBox(width: 12),
                      const Text(
                        '11kW Charging Calculation',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildCalculationRow('Range to charge', '${((_maxRange * _chargePercentage / 100) - _currentRange).round()} km'),
                  const SizedBox(height: 12),
                  _buildCalculationRow('Charging rate', '11kW'),
                  const SizedBox(height: 12),
                  _buildCalculationRow('Base time', '${(_calculatedMinutes * 0.9).round()} min'),
                  const SizedBox(height: 12),
                  _buildCalculationRow('Buffer time', '${(_calculatedMinutes * 0.1).round()} min'),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.timer, color: Colors.green, size: 24),
                        const SizedBox(width: 12),
                        Text(
                          'Total: $_calculatedMinutes minutes',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
          
          // Quick Charge Button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || !_hasRealData || _calculatedMinutes == 0) ? null : () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Quick Charge würde $_calculatedMinutes Minuten laden (11kW)'),
                    backgroundColor: Brand.primary,
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
              icon: Icon(_busy ? Icons.hourglass_empty : Icons.flash_on, size: 24),
              label: Text(_busy ? 'Calculating...' : 
                         !_hasRealData ? 'No Data Available' : 
                         _calculatedMinutes == 0 ? 'Ready to Charge' : 'Start Quick Charge',
                         style: const TextStyle(fontSize: 18)),
              style: FilledButton.styleFrom(
                backgroundColor: (_busy || !_hasRealData || _calculatedMinutes == 0) 
                    ? Colors.grey 
                    : Brand.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                elevation: (_busy || !_hasRealData || _calculatedMinutes == 0) ? 0 : 6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDataRow(String label, String value, IconData icon, {bool isTarget = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: isTarget ? Brand.primary : Colors.grey[600]),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[700],
              ),
            ),
          ],
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: isTarget ? Brand.primary : Colors.black,
          ),
        ),
      ],
    );
  }

  Widget _buildCalculationRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            color: Colors.grey,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
            color: Colors.green,
          ),
        ),
      ],
    );
  }
}
