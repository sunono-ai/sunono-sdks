import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/host.dart';
import 'copy.dart';
import 'theme.dart';

/// The bottom bar: an outlined `+` (attachments), a rounded input and a
/// round send button, with the photo preview and its error rows above them.
/// The bar runs under the home indicator; its content stays inside the safe area.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.theme,
    required this.controller,
    required this.focus,
    required this.hint,
    required this.canSend,
    required this.onSend,
    required this.onPickPhoto,
    required this.photo,
    required this.image,
    required this.needCaption,
    required this.onRemovePhoto,
    required this.onRetryPhoto,
    required this.copy,
    this.autofocus = false,
    this.onMic,
  });

  final SunonoTheme theme;
  final bool autofocus;
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final bool canSend;
  final VoidCallback onSend;

  /// The host's photo picker; null (no hook) hides the `+` entirely.
  final VoidCallback? onPickPhoto;
  final PhotoState photo;
  final SunonoImage? image;
  final bool needCaption;
  final VoidCallback onRemovePhoto;
  final VoidCallback onRetryPhoto;
  final SunonoCopy copy;

  /// Starts a voice note. When set, the send slot shows the mic while the
  /// input is empty and no photo is attached.
  final VoidCallback? onMic;

  /// The attachment sheet. Only photos today; one row per attachment type.
  Future<void> _openAttachments(BuildContext context) async {
    final dir = Directionality.of(context);
    final photo = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: theme.surface,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        // The sheet opens in the app's overlay: keep the chat's direction.
        textDirection: dir,
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: Icon(Icons.photo_outlined, color: theme.primaryText),
              title: Text(copy.photo, style: theme.text(size: 16)),
              onTap: () => Navigator.of(ctx).pop(true),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (photo == true) onPickPhoto?.call();
  }

  /// Hardware keyboard: Enter sends, Shift+Enter breaks the line. An IME
  /// still composing (e.g. CJK) keeps its Enter.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent ||
        (e.logicalKey != LogicalKeyboardKey.enter && e.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      final v = controller.value;
      final at = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
      controller.value = v.replaced(at, '\n');
    } else if (e is KeyDownEvent) {
      onSend();
    }
    return KeyEventResult.handled;
  }

  /// A 48 dp outlined circle (`+`, mic).
  Widget _outlined(IconData icon, String label, VoidCallback onPressed) => IconButton.outlined(
        onPressed: onPressed,
        tooltip: label,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(48),
          side: BorderSide(color: theme.outline),
          foregroundColor: theme.onSurface,
        ),
        icon: Icon(icon, color: theme.onSurface),
      );

  @override
  Widget build(BuildContext context) {
    final mic = onMic != null && photo is PhotoIdle && controller.text.trim().isEmpty;
    final radius = BorderRadius.circular(24);
    return DecoratedBox(
      decoration: BoxDecoration(color: theme.surface, border: Border(top: BorderSide(color: theme.outline))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (photo is! PhotoIdle && image != null) ..._preview(),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (onPickPhoto != null) ...[
                _outlined(Icons.add_rounded, copy.attach, () => _openAttachments(context)),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onKey,
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    autofocus: autofocus,
                    minLines: 1,
                    maxLines: 5, // then it scrolls
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    style: theme.text(size: 15),
                    cursorColor: theme.primaryText,
                    decoration: InputDecoration(
                      hintText: hint,
                      hintMaxLines: 1, // a wrapped hint at 200% text would eat the screen
                      hintStyle: theme.text(size: 15, color: theme.muted),
                      filled: true,
                      fillColor: theme.surface,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      enabledBorder:
                          OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: theme.outline)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: radius, borderSide: BorderSide(color: theme.primaryText, width: 1.5)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (mic)
                _outlined(Icons.mic_none_rounded, copy.recordVoice, onMic!)
              else
                IconButton.filled(
                  onPressed: canSend ? onSend : null,
                  tooltip: copy.send,
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(48),
                    backgroundColor: theme.userBubble,
                    disabledBackgroundColor: theme.userBubble.withValues(alpha: 0.4),
                  ),
                  // Up in both directions: nothing to mirror.
                  icon: Icon(Icons.arrow_upward_rounded,
                      color: canSend ? theme.onUserBubble : theme.onUserBubble.withValues(alpha: 0.7)),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  List<Widget> _preview() => [
        Align(
          alignment: AlignmentDirectional.centerStart,
          // The 6 dp margin is inside the Stack so the remove button's
          // 48 dp target (which overhangs the preview) is hit-testable.
          child: Stack(children: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  image!.bytes,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  // Magic bytes pass but the pixels may not decode: still removable.
                  errorBuilder: (_, __, ___) =>
                      SizedBox(width: 64, height: 64, child: Icon(Icons.broken_image_outlined, color: theme.muted)),
                ),
              ),
            ),
            if (photo case PhotoUploading(:final progress))
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ColoredBox(
                      color: Colors.black38,
                      child: Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 3,
                            color: Colors.white,
                            semanticsLabel: copy.uploadingPhoto((progress * 100).round()),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            PositionedDirectional(
              top: 0,
              end: 0,
              // 48 dp to touch, the same small circle to see.
              child: Semantics(
                button: true,
                label: copy.removePhoto,
                onTap: onRemovePhoto,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemovePhoto,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Align(
                      alignment: AlignmentDirectional.topEnd,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(top: 2, end: 2),
                        child: IconButton.filledTonal(
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            backgroundColor: theme.surface,
                            foregroundColor: theme.onSurface,
                            side: BorderSide(color: theme.outline),
                          ),
                          iconSize: 14,
                          tooltip: copy.removePhoto,
                          onPressed: onRemovePhoto,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
        if (photo case PhotoFailed(:final code, :final retryable))
          _note(Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            Text(copy.photoError(code), style: theme.text(size: 13, color: theme.danger)),
            if (retryable)
              TextButton(
                  onPressed: onRetryPhoto,
                  style: TextButton.styleFrom(foregroundColor: theme.primaryText),
                  child: Text(copy.retry)),
          ])),
        if (needCaption) _note(Text(copy.photoCaptionHint, style: theme.text(size: 13, color: theme.danger))),
      ];

  /// A live-region line under the preview.
  Widget _note(Widget child) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 10, 4),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(liveRegion: true, child: child),
        ),
      );
}
