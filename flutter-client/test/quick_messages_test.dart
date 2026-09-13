import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';

/// The server's CHAT_MAX_LENGTH. It cuts a line to this many UTF-16 code
/// units (`truncateUTF16` in go-server/internal/game/chat.go), which is exactly
/// what Dart's `String.length` counts.
const chatMaxLength = 140;

/// What the server makes of a chat line before anyone sees it, short of the
/// length cut: `SanitizeChat` in go-server/internal/game/chat.go, which ports
/// Node's `text.replace(/[\p{C}]/gu, ' ').replace(/\s+/g, ' ').trim()`.
///
/// Dart's RegExp follows ECMAScript, so these are the very expressions the Go
/// port was written to match. The server turns every format character into a
/// space — the ZWJ and ZWNJ an Indic translation might reach for among them —
/// and closes up runs of spaces anywhere in the line, not only at its ends. A
/// set line carrying either would arrive as something other than what the
/// panel showed, so every line must come through this unchanged.
String serverSanitised(String text) => text
    .replaceAll(RegExp(r'\p{C}', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+', unicode: true), ' ')
    .trim();

/// A line's code points, for a failure message: the characters that break
/// the check above are invisible when printed.
String codePoints(String text) =>
    text.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

void main() {
  group('quick messages', () {
    test("English is the owner's text, word for word", () {
      expect(const Strings(AppLang.english).quickMessages, [
        'Please Play Blind.',
        'Please Play fast.',
        "That's how you win it.",
        'I am unlucky.',
        'You got lucky.',
        "Oops! I shouldn't have played it.",
        'Please take sideshow.',
        'Please take show.',
        'Switch Table.',
        'Please help me.',
      ]);
    });

    // Guards the guard: a character class the VM did not understand would
    // match nothing, and every line below would pass without being checked.
    test('the sanitiser check changes what the server changes', () {
      expect(serverSanitised('मद\u200Cद'), 'मद द'); // ZWNJ
      expect(serverSanitised('मद\u200Dद'), 'मद द'); // ZWJ
      expect(serverSanitised('\uFEFFHi'), 'Hi'); // BOM
      expect(serverSanitised('আমার  ভাগ্য'), 'আমার ভাগ্য');
      expect(serverSanitised(' Hi\t'), 'Hi');
      expect(serverSanitised('Please help me.'), 'Please help me.');
    });

    for (final lang in AppLang.values) {
      group(lang.englishName, () {
        final t = Strings(lang);

        test('has all ten, each arriving exactly as the panel shows it', () {
          expect(t.quickMessages, hasLength(10));
          for (final line in t.quickMessages) {
            expect(line, isNotEmpty);
            expect(serverSanitised(line), line, reason: codePoints(line));
          }
        });

        test('fits in one chat message', () {
          for (final line in t.quickMessages) {
            expect(line.length, lessThanOrEqualTo(chatMaxLength), reason: line);
          }
        });

        test('are all different', () {
          expect(t.quickMessages.toSet(), hasLength(t.quickMessages.length));
        });

        // The lookup's last resort is the key itself, so a key missing from
        // English too would put its own name on the panel. That is not empty,
        // and in every other language it equals "the English", so only asking
        // for the key by name catches it.
        test('has a panel title and a key tooltip of its own', () {
          expect(t.quickMessagesTitle.trim(), isNotEmpty);
          expect(t.quickMessagesTip.trim(), isNotEmpty);
          expect(t.quickMessagesTitle, isNot('quickMessagesTitle'));
          expect(t.quickMessagesTip, isNot('quickMessagesTip'));
        });

        // A key missing from a translation falls back to English rather than
        // failing, so a gap would pass every test above. Every other language
        // is in another script, so its own line can never equal the English.
        if (lang != AppLang.english) {
          test('translates every line rather than falling back', () {
            const en = Strings(AppLang.english);
            for (var i = 0; i < t.quickMessages.length; i++) {
              expect(t.quickMessages[i], isNot(en.quickMessages[i]));
            }
            expect(t.quickMessagesTitle, isNot(en.quickMessagesTitle));
            expect(t.quickMessagesTip, isNot(en.quickMessagesTip));
          });
        }
      });
    }
  });
}
