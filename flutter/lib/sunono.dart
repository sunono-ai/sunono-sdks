/// Sunono AI shopping assistant for Flutter.
///
/// ```dart
/// Sunono.init(shopKey: 'pk_…', appOrigin: 'https://shop.example', onIntent: route);
/// // In a tab or route:
/// Sunono.view();
/// ```
library;

export 'src/core/api.dart' show SunonoApi, SunonoHttpException, sdkVersion;
export 'src/core/controller.dart' show SunonoChatController, ChatMessage, ChatRole, MessageState, ChatStatus;
export 'src/core/format.dart' show formatJod, formatFils;
export 'src/core/host.dart';
export 'src/core/models.dart'
    show
        ProductCard,
        Cart,
        CartLine,
        ExtraLine,
        Checkout,
        CheckoutCollect,
        CheckoutReview,
        CheckoutPlaced,
        CheckoutField,
        ShopConfig;
export 'src/sunono.dart';
export 'src/ui/chat_view.dart' show SunonoChatView;
export 'src/ui/orb.dart' show PresenceOrb;
export 'src/ui/theme.dart' show SunonoTheme;
