import 'package:flutter/material.dart';
import 'package:sunono/sunono.dart';

/// Run with your shop's key:
/// `flutter run --dart-define=SUNONO_SHOP_KEY=pk_live_… --dart-define=SUNONO_APP_ORIGIN=https://your-store.example`
/// (first `flutter create .` inside example/ to generate the platform folders).
void main() {
  Sunono.init(
    shopKey: const String.fromEnvironment('SUNONO_SHOP_KEY',
        defaultValue: 'pk_test'),
    appOrigin: const String.fromEnvironment('SUNONO_APP_ORIGIN',
        defaultValue: 'https://shop.example'),
    locale: 'ar',
    // Demo only: forgets the shopper on every launch. Use secure storage in a real app.
    storage: MemoryStorage(),
    // cartBridge: YourMagentoBridge(), // Magento cart sync
    onIntent: (intent) {
      switch (intent) {
        case OpenProductIntent(:final sku, :final title):
          debugPrint('open product $sku ($title)');
        case OpenCartIntent():
          debugPrint('open cart');
        case CheckoutIntent():
          debugPrint('open native checkout');
        case OpenUrlIntent(:final url):
          debugPrint('open $url');
      }
      return true;
    },
  );
  Sunono.events.listen((e) {
    if (e is CartChangedEvent) debugPrint('refresh the app cart');
  });
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF57227D)),
        home: Builder(
          builder: (context) => Scaffold(
            body: _tab == 0
                ? Center(
                    child: FilledButton(
                      onPressed: () => Sunono.open(context,
                          initialMessage: 'شو عندكم عروض اليوم؟'),
                      child: const Text('Ask about a product'),
                    ),
                  )
                : Sunono.view(
                    theme: SunonoTheme.fromMaterial(Theme.of(context),
                        accent: const Color(0xFFF2A900))),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.home_outlined), label: 'Home'),
                NavigationDestination(
                    icon: Icon(Icons.auto_awesome_outlined), label: 'Chat'),
              ],
            ),
          ),
        ),
      );
}
