// Copy the release review caught saying something the app no longer does
// (24 Sep 2026, owner's "fix all bugs").
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';

void main() {
  // RC-09: Facebook sign-in is switched off (owner, 23 Sep 2026), so nothing
  // a player can read may send them to it. The picture sheet's tooltip for a
  // guest said "Sign in with Google or Facebook to use your own photo."
  for (final lang in AppLang.values) {
    test('no visible line offers Facebook sign-in in ${lang.englishName}', () {
      final t = Strings(lang);
      for (final key in [
        'guestNoSocial',
        'useSocialPicture',
        'useProviderPicture',
      ]) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own, contains('Google'), reason: '${lang.code} "$key"');
        expect(own, isNot(contains('Facebook')), reason: '${lang.code} "$key"');
      }
    });
  }
}
