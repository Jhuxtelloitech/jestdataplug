import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JestDataPlugApp());
}

class JestDataPlugApp extends StatelessWidget {
  const JestDataPlugApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _isOffline = false;
  final storage = const FlutterSecureStorage();
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  final String loginUrl =
      "https://data.jhuxtelloitech.com/pages/pages/authentication/login";

  @override
  void initState() {
    super.initState();
    _initWebView();
    _monitorConnectivity();
  }

  Future<void> _initWebView() async {
    late final PlatformWebViewControllerCreationParams params;

    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(false)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) async {
            final url = request.url;

            // Handle external links
            if (url.startsWith("mailto:") ||
                url.startsWith("tel:") ||
                url.startsWith("sms:") ||
                url.startsWith("intent:") ||
                url.contains("wa.me") ||
                url.contains("whatsapp.com")) {
              if (await canLaunchUrl(Uri.parse(url))) {
                await launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                );
                return NavigationDecision.prevent;
              }
            }

            // Handle downloads
            if (url.endsWith(".pdf") ||
                url.endsWith(".doc") ||
                url.endsWith(".docx") ||
                url.endsWith(".xls") ||
                url.endsWith(".xlsx") ||
                url.endsWith(".zip") ||
                url.endsWith(".jpg") ||
                url.endsWith(".png")) {
              _handleFileDownload(url);
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) async {
            setState(() => _isLoading = false);
            _isOffline = false;

            // Capture remember_me cookie
            final cookies = await _controller.runJavaScriptReturningResult(
              "document.cookie",
            );

            if (cookies is String && cookies.contains("remember_me=")) {
              final token = _extractCookieValue(cookies, "remember_me");
              if (token != null) {
                await storage.write(key: 'remember_me', value: token);
              }
            }
          },
          onWebResourceError: (_) async {
            final results = await Connectivity().checkConnectivity();
            if (results == ConnectivityResult.none) {
              setState(() => _isOffline = true);
            } else {
              _controller.reload();
            }
          },
        ),
      );

    _controller = controller;

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    // Inject stored token if exists
    String? token = await storage.read(key: 'remember_me');
    if (token != null) {
      await _controller.runJavaScript(
        "document.cookie='remember_me=$token; path=/; Secure; HttpOnly';",
      );
    }

    _controller.loadRequest(Uri.parse(loginUrl));
  }

  String? _extractCookieValue(String cookies, String name) {
    final match = RegExp('$name=([^;]+)').firstMatch(cookies);
    return match?.group(1);
  }

  void _monitorConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (results.contains(ConnectivityResult.none)) {
        setState(() => _isOffline = true);
      } else {
        if (_isOffline) {
          setState(() => _isOffline = false);
          _controller.reload();
        }
      }
    });
  }

  Future<void> _handleFileDownload(String url) async {
    final status = await Permission.storage.request();
    if (!status.isGranted) return;

    final fileName = url.split('/').last;
    Directory downloadDir;
    if (Platform.isAndroid) {
      downloadDir = Directory('/storage/emulated/0/Download');
    } else {
      downloadDir = await getApplicationDocumentsDirectory();
    }
    if (!await downloadDir.exists()) await downloadDir.create(recursive: true);

    final savePath = "${downloadDir.path}/$fileName";

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Downloading..."),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      await Dio().download(url, savePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Saved to ${downloadDir.path}/$fileName"),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Download failed: $e"),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // ✅ Cleaned null check warning
        final canGoBack = await _controller.canGoBack();
        if (canGoBack) {
          _controller.goBack();
          return false;
        }
        return true;
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              if (_isOffline)
                _buildOfflineScreen()
              else
                WebViewWidget(controller: _controller),
              if (_isLoading && !_isOffline)
                Container(
                  color: Colors.white,
                  child: const Center(
                    child: CircularProgressIndicator(
                      color: Colors.blueAccent,
                      strokeWidth: 3,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineScreen() {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset("assets/images/logo.png", width: 120, height: 120),
          const SizedBox(height: 24),
          const Icon(Icons.wifi_off, size: 60, color: Colors.grey),
          const SizedBox(height: 20),
          const Text(
            "You're Offline",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          const Text(
            "Please check your internet connection.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
