// UI strings. Chrome follows the controller's language.

class SunonoCopy {
  const SunonoCopy._(this._ar);
  final bool _ar;

  static SunonoCopy of(String lang) => lang == 'en' ? const SunonoCopy._(false) : const SunonoCopy._(true);

  String _t(String ar, String en) => _ar ? ar : en;

  String get title => _t('المساعد', 'Assistant');
  String get inputHint => _t('اكتب رسالتك…', 'Type a message…');
  String get photoCaptionHint => _t('اكتب سؤالك عن الصورة…', 'Ask something about the photo…');
  String get send => _t('إرسال', 'Send');
  String get attachPhoto => _t('أرفق صورة', 'Attach a photo');
  String get removePhoto => _t('شيل الصورة', 'Remove photo');
  String get welcome => _t('أهلين! شو بتدور عليه اليوم؟', 'Hi! What are you looking for today?');
  String get storeTeam => _t('فريق المتجر', 'Store team');
  String get paused => _t('حوّلنا المحادثة لخدمة العملاء 🧑‍💼', 'This conversation was handed to our team 🧑‍💼');
  String get resumed => _t('رجع المساعد الآلي 🤖', 'The assistant is back 🤖');
  String get retry => _t('أعد المحاولة', 'Retry');
  String get recovering => _t('بتأكد إنها وصلت…', 'Checking it went through…');
  String get disabled => _t('المساعد مش متاح هلّق', 'The assistant is unavailable right now');
  String get online => _t('متصل', 'Online');
  String get humanOnline => _t('فريق المتجر معك', 'Store team is with you');

  String error(String? code) => switch (code) {
        'rate_limited' => _t('رسائل كثير ورا بعض، استنى شوي وجرّب', 'Too many messages, wait a moment'),
        'offline' => _t('ما في اتصال بالإنترنت', 'No internet connection'),
        'image_too_large' => _t('الصورة كبيرة كثير', 'That photo is too large'),
        'invalid_image' => _t('ما قدرنا نفتح هالصورة', "We couldn't open that photo"),
        'image_blocked' => _t('ما بنقدر نستخدم هالصورة', "We can't use that photo"),
        _ => _t('ما وصلت الرسالة', "The message didn't go through"),
      };

  // Product card
  String get addToCart => _t('أضف للسلة', 'Add to cart');
  String get details => _t('التفاصيل', 'Details');
  String get unavailable => _t('مش متوفر', 'Unavailable');
  String get from => _t('من', 'From');
  String get sale => _t('عرض', 'Sale');
  String lowStock(int n) => _t('باقي $n بس!', 'Only $n left!');
  String get showMore => _t('شوف أكثر', 'Show more');

  // Cart + checkout
  String get cart => _t('السلة', 'Cart');
  String items(int n) => _ar ? '$n ${n == 1 ? 'قطعة' : 'قطع'}' : '$n ${n == 1 ? 'item' : 'items'}';
  String get completeOrder => _t('كمّل الطلب', 'Complete your order');
  String get collectTitle => _t('بيانات التوصيل', 'Delivery details');
  String get confirmTitle => _t('تأكيد الطلب', 'Confirm your order');
  String get amendTitle => _t('شو حاب تغيّر؟', "What'd you like to change?");
  String get placedTitle => _t('تم الطلب! 🎉', 'Order placed! 🎉');
  String get total => _t('المجموع', 'Total');
  String get delivery => _t('التوصيل', 'Delivery');
  String get freeDelivery => _t('توصيل مجاني', 'Free delivery');
  String get orderNumber => _t('رقم الطلب', 'Order #');
  String get pending => _t('باقي', 'Pending');
  String get savings => _t('وفّرت', 'You save');
  String vatIncluded(String v) => _t('شامل $v ضريبة', 'includes $v VAT');
  String serviceFeeIncluded(String v) => _t('شامل رسوم الخدمة $v', 'includes $v service fee');
}
