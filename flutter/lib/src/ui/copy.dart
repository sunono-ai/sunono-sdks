// UI strings. Chrome follows the controller's language.

class SunonoCopy {
  const SunonoCopy._(this._ar);
  final bool _ar;

  static SunonoCopy of(String lang) => lang == 'en' ? const SunonoCopy._(false) : const SunonoCopy._(true);

  String _t(String ar, String en) => _ar ? ar : en;

  String get title => _t('مساعد المتجر', 'Shop assistant');
  String get inputHint => _t('اكتب رسالتك…', 'Type a message…');
  String get photoCaptionHint => _t('اكتب سؤالك عن الصورة…', 'Ask something about the photo…');
  String get send => _t('إرسال', 'Send');
  String get attachPhoto => _t('أرفق صورة', 'Attach a photo');
  String get removePhoto => _t('شيل الصورة', 'Remove photo');
  String get welcome => _t('أهلاً بك! كيف يمكنني مساعدتك اليوم؟', 'Hi! How can I help you today?');
  List<String> get starters => _ar
      ? const ['شو في جديد عندكم؟', 'بدي أتابع طلبي', 'في عروض هلأ؟']
      : const ["What's new?", 'Track my order', 'Any offers?'];
  String get storeTeam => _t('خدمة العملاء', 'Store team');
  String get viewImage => _t('اعرض الصورة', 'View photo');
  String get close => _t('إغلاق', 'Close');
  String get paused => _t('حوّلنا المحادثة لخدمة العملاء 🧑‍💼', 'This conversation was handed to our team 🧑‍💼');
  String get resumed => _t('رجع المساعد الآلي 🤖', 'The assistant is back 🤖');
  String get retry => _t('أعد المحاولة', 'Retry');
  String get recovering => _t('بتأكد إنها وصلت…', 'Checking it went through…');
  String get disabled => _t('المساعد مش متاح هلّق', 'The assistant is unavailable right now');
  String get updateApp => _t('حدّث التطبيق عشان تستخدم المساعد', 'Please update the app to use the assistant');
  String get online => _t('متصل • جاهزين نساعدك', 'Online • Here to help');
  String get humanOnline => _t('فريق المتجر معك', 'Store team is with you');
  String get offline => _t('غير متاح هلّق', 'Unavailable right now');
  String get back => _t('رجوع', 'Back');
  String get moreOptions => _t('خيارات أكثر', 'More options');
  String get talkToTeam => _t('احكي مع الفريق', 'Talk to our team');

  /// Sent (synthetic) by "Talk to our team": the server's escalate intent.
  String get escalatePhrase => _t('بدي أحكي مع حدا من الفريق', "I'd like to talk to someone from your team");
  String get welcomeTitle => _t('أهلاً، كيف بنقدر نساعدك؟', 'Hello, how can we help?');
  String get welcomeSubtitle => _t('اسأل عن المنتجات، العروض أو طلبك.', 'Ask about products, offers or your order.');

  String error(String? code) => switch (code) {
        'rate_limited' => _t('رسائل كثير ورا بعض، استنى شوي وجرّب', 'Too many messages, wait a moment'),
        'offline' => _t('ما في اتصال بالإنترنت', 'No internet connection'),
        'image_too_large' => _t('الصورة كبيرة كثير', 'That photo is too large'),
        'invalid_image' => _t('ما قدرنا نفتح هالصورة', "We couldn't open that photo"),
        'image_unavailable' =>
          _t('الصور مش متاحة هلّق، احكيلي شو بدك بالكلام', "Photos aren't available right now — tell me in words"),
        'customer_blocked' => _t('ما بنقدر نستقبل صور هلّق', "We can't accept photos right now"),
        'image_blocked' => _t('ما بنقدر نستخدم هالصورة', "We can't use that photo"),
        _ => _t('ما وصلت الرسالة', "The message didn't go through"),
      };

  /// Under the composer's preview: [error] for the codes a photo can fail
  /// with, a photo-specific line for anything else.
  String photoError(String code) => switch (code) {
        'rate_limited' ||
        'offline' ||
        'image_too_large' ||
        'invalid_image' ||
        'image_blocked' ||
        'image_unavailable' ||
        'customer_blocked' =>
          error(code),
        _ => _t('ما قدرنا نرفع الصورة', "We couldn't upload that photo"),
      };

  String uploadingPhoto(int percent) => _t('عم نرفع الصورة $percent%', 'Uploading photo $percent%');

  // Product card
  String get addToCart => _t('أضف للسلة', 'Add to cart');
  String get details => _t('التفاصيل', 'Details');
  String detailsOf(String title) => '$details: $title';
  String get unavailable => _t('مش متوفر', 'Unavailable');
  String get from => _t('من', 'From');
  String get sale => _t('عرض', 'Sale');
  String lowStock(int n) => _t('باقي $n بس!', 'Only $n left!');
  String get showMore => _t('شوف أكثر', 'Show more');

  // Cart + checkout
  String get cart => _t('السلة', 'Cart');
  String completeOrder(bool native) =>
      native ? _t('كمّل الطلب', 'Complete your order') : _t('كمّل الطلب بالموقع', 'Complete order on the site');
  String get orderDetails => _t('تفاصيل الطلب', 'Order details');
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
