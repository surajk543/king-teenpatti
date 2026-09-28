import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/server_config.dart';
import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'avatar.dart';
import 'edge_fade.dart';
import 'emoji_shelf.dart';
import 'game_loader.dart';
import 'glass_components.dart';
import 'glass_orb.dart';
import 'glass_panels.dart';
import 'picture_shelf.dart';
import 'poker_chip.dart';
import 'premium_surface.dart';
import 'table_picture_shelf.dart';
import 'table_tax.dart';

/// Where a pack sits in the range. Drives the ribbon across its top edge, and
/// nothing else — the price and the chips are the offer, this is the signpost.
///
/// [crown] is the top of the Premium Packages (owner, 14 Sep 2026): 👑, as
/// [popular] is ⭐ and [bestValue] 🔥.
enum ShelfMark { none, starter, popular, bestValue, premium, crown }

/// The glyph a mark is shown with, or null for a mark that is a word alone:
/// ⭐ popular, 🔥 best value, 👑 the crown. One place, so a mark reads the
/// same on every shelf it appears on.
String? shelfMarkGlyph(ShelfMark mark) => switch (mark) {
  ShelfMark.popular => '⭐',
  ShelfMark.bestValue => '🔥',
  ShelfMark.crown => '👑',
  ShelfMark.none || ShelfMark.starter || ShelfMark.premium => null,
};

/// One purchasable pack.
///
/// Chips are stored as an integer and rendered through [formatChips], never as
/// a baked-in "1.92 Cr" string: a player who has switched to international
/// numbering should read Million and Billion here exactly as they do at the
/// table. In Indian numbering the nine packs come out as the owner specified
/// them — 1.92, 5.28, 12, 35.2, 60, 150, 275, 400 and 500 Crore.
class ChipPack {
  const ChipPack({
    required this.id,
    required this.productId,
    required this.rupees,
    required this.chips,
    this.bonusPercent = 0,
    this.mark = ShelfMark.none,
  });

  final String id;

  /// The Play Console product id. It must match internal/purchase/catalogue.go
  /// exactly — that file, not this one, decides how many chips it is worth.
  final String productId;
  final int rupees;
  final int chips;

  /// 0 on the starter pack, which is the baseline the rest are sold against.
  final int bonusPercent;
  final ShelfMark mark;

  bool get featured =>
      mark == ShelfMark.bestValue ||
      mark == ShelfMark.premium ||
      mark == ShelfMark.crown;
}

/// One Premium Package (owner, 14 Sep 2026): chips, missiles and hammers in
/// one Play purchase, sold on the Chips shelf under its own heading.
///
/// Like [ChipPack], every figure here is for display only: the server's
/// `purchase.Catalogue` decides what a product id is worth, credits all three
/// wallets from one receipt, and answers with what it gave.
class PremiumPack {
  const PremiumPack({
    required this.productId,
    required this.rupees,
    required this.chips,
    required this.missiles,
    required this.hammers,
    this.mark = ShelfMark.none,
  });

  /// The Play Console product id. It must match
  /// internal/purchase/catalogue.go exactly.
  final String productId;
  final int rupees;

  /// Rendered through [formatChips], never as a baked "650 Cr".
  final int chips;
  final int missiles;
  final int hammers;

  /// ⭐ or 👑 beside the chips figure, on the two the owner marked.
  final ShelfMark mark;
}

/// The Premium Packages, cheapest first, as the owner set them: ⭐ on the
/// second-dearest and 👑 on the dearest. 1 Crore is 1,00,00,000 chips.
///
/// The ₹49,999 and ₹99,999 packages were dropped on 22 Sep 2026 (owner) when
/// the Play Console products were created, so the shelf ends at ₹29,999 and
/// the two marks moved down with it — a shelf where nothing is starred looks
/// unfinished beside the chip shelf, which marks four of its nine. Every id
/// here must exist as a managed product in the Play Console, and the server's
/// catalogue (go-server/internal/purchase/catalogue.go) must agree: it is what
/// decides the amounts, and it refuses an id it does not know.
const premiumPacks = <PremiumPack>[
  PremiumPack(
    productId: 'premium_1_9999',
    rupees: 9999,
    chips: 6500000000,
    missiles: 1,
    hammers: 10,
  ),
  PremiumPack(
    productId: 'premium_2_14999',
    rupees: 14999,
    chips: 10500000000,
    missiles: 2,
    hammers: 15,
  ),
  PremiumPack(
    productId: 'premium_3_19999',
    rupees: 19999,
    chips: 15000000000,
    missiles: 4,
    hammers: 21,
    mark: ShelfMark.popular,
  ),
  PremiumPack(
    productId: 'premium_4_29999',
    rupees: 29999,
    chips: 25000000000,
    missiles: 6,
    hammers: 30,
    mark: ShelfMark.crown,
  ),
];

/// One purchasable diamond pack (owner, 13 Sep 2026).
///
/// Like [ChipPack], the count is only for display: `purchase.Catalogue` on the
/// server decides what a product id is worth, and a diamond pack credits
/// `users.diamond`, never chips.
class DiamondPack {
  const DiamondPack({
    required this.productId,
    required this.rupees,
    required this.diamonds,
    this.mark = ShelfMark.none,
  });

  /// The Play Console product id. It must match
  /// internal/purchase/catalogue.go exactly.
  final String productId;
  final int rupees;
  final int diamonds;
  final ShelfMark mark;
}

/// The diamond shelf, cheapest first. ⭐ marks the popular pack, 🔥 the best
/// value, as the owner set them.
const diamondPacks = <DiamondPack>[
  DiamondPack(productId: 'diamonds_1_49', rupees: 49, diamonds: 1),
  DiamondPack(
    productId: 'diamonds_5_199',
    rupees: 199,
    diamonds: 5,
    mark: ShelfMark.popular,
  ),
  DiamondPack(
    productId: 'diamonds_20_699',
    rupees: 699,
    diamonds: 20,
    mark: ShelfMark.bestValue,
  ),
  DiamondPack(productId: 'diamonds_100_2999', rupees: 2999, diamonds: 100),
];

/// One purchasable hammer pack (owner, 13 Sep 2026). A hammer pays for one
/// Force Sideshow at the table.
///
/// Like [DiamondPack], the count is only for display: `purchase.Catalogue` on
/// the server decides what a product id is worth, and a hammer pack credits
/// `users.hammer`, never chips or diamonds.
class HammerPack {
  const HammerPack({
    required this.productId,
    required this.rupees,
    required this.hammers,
    this.mark = ShelfMark.none,
  });

  /// The Play Console product id. It must match
  /// internal/purchase/catalogue.go exactly.
  final String productId;
  final int rupees;
  final int hammers;
  final ShelfMark mark;
}

/// The hammer shelf, cheapest first. ⭐ marks the popular pack and 🔥 the best
/// value, the same treatment as the diamond shelf, on the packs the owner
/// chose: 50 and 100.
const hammerPacks = <HammerPack>[
  HammerPack(productId: 'hammers_20_300', rupees: 300, hammers: 20),
  HammerPack(
    productId: 'hammers_50_699',
    rupees: 699,
    hammers: 50,
    mark: ShelfMark.popular,
  ),
  HammerPack(
    productId: 'hammers_100_1299',
    rupees: 1299,
    hammers: 100,
    mark: ShelfMark.bestValue,
  ),
  HammerPack(productId: 'hammers_250_2999', rupees: 2999, hammers: 250),
];

/// One trade of diamonds for missiles (owner, 14 Sep 2026): from 1 missile for
/// 5 diamonds to 30 for 100, and a missile pays for firing one at the table.
///
/// Not a Play product. Nothing here costs money: the store spends diamonds the
/// player already holds through `POST /api/store/missiles`, and the server
/// holds the packs — these counts are for display, and [packId] is all that is
/// sent.
class MissilePack {
  const MissilePack({
    required this.packId,
    required this.diamonds,
    required this.missiles,
    this.mark = ShelfMark.none,
  });

  /// The server's name for the pack.
  final String packId;

  /// What it costs, in diamonds.
  final int diamonds;

  /// What it gives.
  final int missiles;
  final ShelfMark mark;
}

/// The missile store's base rate: what a single missile costs, and the rate
/// the shelf's blurb states ("15 diamonds = 1 missile"). The bigger packs give
/// more a diamond than this, so no pack is priced from it but the first.
/// Raised from 10 to 15 by the owner on 14 Sep 2026.
const diamondsPerMissile = 15;

/// The missile shelf, cheapest first — the server's `db.MissilePacks`, each
/// named by the missiles it gives (owner, 14 Sep 2026). Not a flat rate: the
/// more diamonds traded at once, the more missiles each one buys.
const missilePacks = <MissilePack>[
  MissilePack(packId: 'missiles_1', diamonds: diamondsPerMissile, missiles: 1),
  MissilePack(packId: 'missiles_5', diamonds: 73, missiles: 5),
  MissilePack(packId: 'missiles_10', diamonds: 140, missiles: 10),
  MissilePack(packId: 'missiles_20', diamonds: 220, missiles: 20),
];

/// The shelf, in the owner's order. Cheapest first, so scrolling right is
/// always "more".
const chipPacks = <ChipPack>[
  ChipPack(
    id: 'A',
    productId: 'chips_a_99',
    rupees: 99,
    chips: 19200000,
    mark: ShelfMark.starter,
  ),
  ChipPack(
    id: 'B',
    productId: 'chips_b_199',
    rupees: 199,
    chips: 52800000,
    bonusPercent: 20,
  ),
  ChipPack(
    id: 'C',
    productId: 'chips_c_399',
    rupees: 399,
    chips: 120000000,
    bonusPercent: 30,
  ),
  ChipPack(
    id: 'D',
    productId: 'chips_d_999',
    rupees: 999,
    chips: 352000000,
    bonusPercent: 40,
    mark: ShelfMark.popular,
  ),
  ChipPack(
    id: 'E',
    productId: 'chips_e_1499',
    rupees: 1499,
    chips: 600000000,
    bonusPercent: 50,
  ),
  ChipPack(
    id: 'F',
    productId: 'chips_f_2999',
    rupees: 2999,
    chips: 1500000000,
    bonusPercent: 55,
    mark: ShelfMark.bestValue,
  ),
  ChipPack(
    id: 'G',
    productId: 'chips_g_4999',
    rupees: 4999,
    chips: 2750000000,
    bonusPercent: 60,
    mark: ShelfMark.popular,
  ),
  ChipPack(
    id: 'H',
    productId: 'chips_h_6900',
    rupees: 6900,
    chips: 4000000000,
    bonusPercent: 65,
    mark: ShelfMark.premium,
  ),
  ChipPack(
    id: 'I',
    productId: 'chips_i_7900',
    rupees: 7900,
    chips: 5000000000,
    bonusPercent: 70,
    mark: ShelfMark.bestValue,
  ),
];

/// The painted height of one line of the type ramp, after the OS text scale
/// (clamped app-wide to 0.9–1.25 in `main.dart`).
///
/// Rounded up, because a paragraph is laid out on whole pixels: the exact
/// product is a fraction short of what the text actually takes, and a Column
/// measured to the fraction overflows by tenths of a pixel.
double _line(TextScaler scaler, double size, double heightFactor) =>
    (scaler.scale(size) * heightFactor).ceilToDouble();

/// The tallest line any of [texts] takes in [style], MEASURED, rounded up.
///
/// [_line] is the Latin line, and a line that mixes scripts is taller than
/// it: Inter has no Devanagari, Bengali, Gujarati or Gurmukhi, so a phone
/// draws those words from its own Noto fonts while the spaces, commas and
/// figures between them stay in Inter, and each run is fitted to the style's
/// height in its own font's proportions — the line then takes the larger
/// ascent of the two AND the larger descent. On TP_Small the Hindi Chips
/// blurb ("जितना बड़ा पैक, उतना बड़ा बोनस") overflowed the header by a pixel
/// that way (24 Sep 2026, owner's "fix all bugs"; release review B1).
///
/// Each text is laid out on ONE line with an ellipsis after it: a line of the
/// whole text holds every run any of its wrapped or cut lines can hold, and
/// the ellipsis is the one glyph a cut line adds, so the answer is never short
/// of what the widget draws.
double _measuredLine(
  BuildContext context,
  TextScaler scaler,
  TextStyle style,
  Iterable<String> texts,
) {
  var tallest = 0.0;
  for (final text in texts) {
    final painter = TextPainter(
      text: TextSpan(text: '$text\u2026', style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    tallest = math.max(tallest, painter.height);
    painter.dispose();
  }
  return tallest.ceilToDouble();
}

/// The store's shelves, in the order their keys sit in the header: chip packs,
/// diamond packs, hammer packs, missile trades, the picture catalogue, the
/// table pictures (owner, 15 Sep 2026: the cloths a player lays on their own
/// table) and the emojis (owner, 26 Sep 2026: animated emojis a player sends
/// to the table). Public so a caller can open the store on the shelf it is
/// sending the player to — the table's Force Sideshow key sends a player with
/// no hammers to [hammers], its Missile key one with no missiles to
/// [missiles], and the table's emoji page a locked emoji to [emojis].
enum StoreTab {
  chips,
  diamonds,
  hammers,
  missiles,
  pictures,
  tables,
  emojis,

  /// The badges (owner, 27 Sep 2026: "Add a icon in Store to buy badges"):
  /// the ones Play sells, bought here, and the ones given by hand, whose card
  /// asks the player to contact support.
  badges,
}

/// Where the store's shelf keys stand: how many rows, which keys each row
/// holds, and how wide each key is — worked out once per build from the
/// sheet's width, the language and the text scale ([_StoreTabs.layoutFor]),
/// so the header can measure itself before anything is laid out.
@immutable
class _NavLayout {
  const _NavLayout({
    required this.rows,
    required this.widths,
    required this.keyHeight,
    this.gap = _StoreTabs.gap,
  });

  /// The keys' indices, row by row, in header order.
  final List<List<int>> rows;

  /// Each key's width, by index.
  final List<double> widths;

  /// Every key's height: the touch floor, or what its glyph and word take.
  final double keyHeight;

  /// Between two keys across: [_StoreTabs.gap], or [_StoreTabs.tightGap]
  /// where that is all that keeps the keys in one row.
  final double gap;

  /// The navigation's whole height.
  double get height =>
      rows.length * keyHeight + (rows.length - 1) * _StoreTabs.runGap;
}

/// The store's shelf navigation, under the header: one key a shelf, each its
/// glyph over its word, EVERY shelf on screen at once (owner, 27 Sep 2026: "I
/// do NOT want the user to horizontally scroll the main store navigation ...
/// The user should immediately understand that more store categories exist").
///
/// It used to share the header's row with the title, the balance and the
/// close key, as circles that became a strip which scrolled — six, then eight
/// shelves did not fit a 640dp phone beside the title, so some were a swipe
/// away and nothing said so. It now has a row of the sheet's own, the
/// sheet's whole width, and [layoutFor] decides how the keys stand in it:
///
///  * **one row of equal keys** wherever every word fits a key an equal
///    share of the row wide (at most [maxKeyWidth], so a tablet's keys stay
///    keys and not a banner);
///  * **one row of keys as wide as their words**, the room left shared out
///    between them, where one long word ("Diamonds" at the 1.25 text ceiling
///    on a 592dp phone) is all that stops equal keys;
///  * **balanced rows** — four over four, four over three — only where the
///    words cannot stand in one row at all, never by screen size.
///
/// A glyph over its word rather than beside it: beside, eight words need some
/// 760dp at the 1.25 text scale and would wrap to two rows on every landscape
/// phone, which is height a 360dp screen gives straight out of the products.
///
/// The key that is on is lit in gold — a gold wash, its rim in full champagne,
/// a soft gold light round it and its glyph and word in gold ink, at full
/// size; the others are quiet ink on a faint well, drawn down a touch — and
/// every change between the two takes [Motion.base] (the brief: "category
/// selection 200-250ms", "a subtle scale/glow"). With no scroll view round
/// the keys there is no clip, so the light may fall outside the key.
class _StoreTabs extends StatelessWidget {
  const _StoreTabs({
    required this.value,
    required this.onChanged,
    required this.layout,
    this.animatedOnly = false,
  });

  final StoreTab value;
  final ValueChanged<StoreTab> onChanged;

  /// Where the keys stand ([layoutFor]).
  final _NavLayout layout;

  /// Whether the picture key sells the animated shelf alone, and is named for
  /// it. True at a table (owner, 13 Sep 2026), where a seated player may buy
  /// and wear an animated picture. Every other shelf is on sale at a table
  /// too, so the table's keys are the lobby's with that one renamed.
  final bool animatedOnly;

  /// The glyph in a key, one size on every key (it was 20 beside a word; over
  /// one, 18 keeps the key at the touch floor at the normal text scale).
  static const double iconSize = 18;

  /// Between the glyph and its word.
  static const double iconGap = 2;

  /// A key's rim, one width on and off, so its words never shift as it is
  /// switched on; the key that is on says so by the rim's colour.
  static const double rim = 1.5;

  /// Inside a key: either side of its word, and above and below its glyph and
  /// word. A key is at least [Dim.minTouch] wide whatever its word, so the
  /// narrow inset only ever tightens a long word's key.
  static const double padX = Space.xs;
  static const double padY = Space.xs;

  /// Above and below the glyph and word on a short screen
  /// ([Breaks.isShort]), where every dp the keys take is one the products
  /// lose; the key still never drops under [Dim.minTouch].
  static const double shortPadY = Space.xxs;

  /// The word of the key that is on, by day: a gold deep enough to read at
  /// the smallest label size on the lit face (5.6:1 there; goldDeep, the
  /// glyph's, measured 3.8:1).
  static const Color dayWordInk = Color(0xFF6B5212);

  /// How far a key that is off is drawn down from its full size. Only the
  /// face: its target stays the key's whole box.
  static const double quietScale = 0.96;

  /// Between two keys across, and between two rows.
  static const double gap = Space.sm;
  static const double runGap = Space.sm;

  /// Between two keys across where the usual [gap] is all that would push
  /// the last key to a second row: on a 592dp phone at the 1.25 text ceiling
  /// the table's eight English keys ("Animated" for "Pictures") missed one
  /// row by a single dp.
  static const double tightGap = Space.xs;

  /// The widest a key grows: past it the row stops short of the sheet's
  /// right edge rather than stretching eight keys into a banner.
  static const double maxKeyWidth = 120;

  /// A key's word: the ramp's smallest label (10.5), set solid rather than
  /// tracked — tracked out, eight English words made a row too wide for a
  /// 592dp phone at the 1.25 text ceiling. Measured in the weight of the key
  /// that is on, the heavier, so a key never outgrows its box as it is
  /// switched on.
  static TextStyle labelStyle(ThemeData theme, {bool on = true}) =>
      (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 10.5)).copyWith(
        letterSpacing: 0,
        fontWeight: on ? FontWeight.w700 : FontWeight.w600,
      );

  /// Where the keys stand in a row [width] wide, in this language at this
  /// text scale. Measured, never decided by screen size: whether eight words
  /// fit one row depends on the words and the scale as much as the phone.
  static _NavLayout layoutFor(
    BuildContext context,
    Strings t, {
    required double width,
    required bool animatedOnly,
    bool short = false,
  }) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final style = labelStyle(theme);
    final shelves = _shelves(t, animatedOnly);
    final n = shelves.length;
    var lineH = 0.0;
    final natural = <double>[];
    for (final shelf in shelves) {
      final painter = TextPainter(
        text: TextSpan(text: shelf.label, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      lineH = math.max(lineH, painter.height);
      natural.add(
        math.max(
          Dim.minTouch,
          (painter.width + 2 * padX + 2 * rim).ceilToDouble(),
        ),
      );
      painter.dispose();
    }
    // The tallest word in the fonts the phone draws it in (an Indic word is
    // taller than Inter's line, CLAUDE.md §12.3), under the glyph.
    final keyH = math.max(
      Dim.minTouch,
      (2 * (short ? shortPadY : padY) + 2 * rim + iconSize + iconGap + lineH)
          .ceilToDouble(),
    );
    final widest = natural.reduce(math.max);
    final sum = natural.fold(0.0, (a, b) => a + b);
    final all = [for (var i = 0; i < n; i++) i];

    // One row of equal keys.
    final cell = math.min(maxKeyWidth, (width - gap * (n - 1)) / n);
    if (cell >= widest) {
      return _NavLayout(
        rows: [all],
        widths: List.filled(n, cell.floorToDouble()),
        keyHeight: keyH,
      );
    }
    // One row of keys as wide as their words, the rest shared out — with
    // the gaps between them tightened a step before a second row is let in.
    for (final between in const [gap, tightGap]) {
      if (sum + between * (n - 1) > width) continue;
      final extra = (width - sum - between * (n - 1)) / n;
      return _NavLayout(
        rows: [all],
        widths: [for (final w in natural) (w + extra).floorToDouble()],
        keyHeight: keyH,
        gap: between,
      );
    }
    // Balanced rows of equal keys: as few as hold every word, the first rows
    // one key longer where the keys do not divide evenly.
    for (var count = 2; count <= n; count++) {
      final perRow = (n / count).ceil();
      final cell = math.min(maxKeyWidth, (width - gap * (perRow - 1)) / perRow);
      if (cell < widest && perRow > 1) continue;
      return _NavLayout(
        rows: [
          for (var r = 0; r < count; r++)
            [
              for (var i = r * perRow; i < math.min(n, (r + 1) * perRow); i++)
                i,
            ],
        ]..removeWhere((row) => row.isEmpty),
        widths: List.filled(n, math.max(1.0, cell.floorToDouble())),
        keyHeight: keyH,
      );
    }
    // Unreachable: one key a row always holds its word.
    return _NavLayout(
      rows: [
        for (final i in all) [i],
      ],
      widths: List.filled(n, math.max(1.0, width.floorToDouble())),
      keyHeight: keyH,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;
    final dark = theme.brightness == Brightness.dark;
    final champagne = dark ? AppTheme.goldBright : AppTheme.goldDeep;
    // The word of the key that is on: the glyph's gold by night; by day a
    // deeper one, since goldDeep on the lit face measured under 4:1 and the
    // word is the ramp's smallest label.
    final wordOn = dark ? AppTheme.goldBright : dayWordInk;
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkMed,
    );
    // A key that is off keeps a body of its own — a faint well and the
    // resting hairline — so it still reads as a key on either theme's glass.
    final well = dark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.60);
    // The key that is on is lit OVER that well, never instead of it: by day
    // the wash straight on the grey sheet made the key that is on darker than
    // its neighbours, and its gold word the hardest on the row to read
    // (about 2.5:1; review, 27 Sep 2026).
    final litCentre = Color.alphaBlend(
      dark
          ? AppTheme.gold.withValues(alpha: 0.30)
          : AppTheme.goldBright.withValues(alpha: 0.55),
      well,
    );
    final litEdge = Color.alphaBlend(
      AppTheme.gold.withValues(alpha: dark ? 0.10 : 0.14),
      well,
    );
    final shelves = _shelves(t, animatedOnly);

    Widget key(int index) {
      final shelf = shelves[index];
      final on = shelf.tab == value;
      final face = AnimatedContainer(
        duration: Motion.base,
        curve: Motion.standard,
        width: layout.widths[index],
        height: layout.keyHeight,
        // The glyph and word are centred in the height [layoutFor] gave the
        // key, which already holds their inset above and below.
        padding: const EdgeInsets.symmetric(horizontal: padX),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          // Lit from inside: brightest at the glyph, a whisper of gold at
          // the rim. Off, the same gradient in the well's one colour, so the
          // two lerp into each other.
          gradient: RadialGradient(
            center: const Alignment(0, -0.35),
            radius: 0.9,
            // By day the light is champagne rather than gold: gold over the
            // pale glass read as a tan smudge.
            colors: on ? [litCentre, litEdge] : [well, well],
          ),
          border: Border.all(
            color: on
                ? champagne.withValues(alpha: dark ? 0.90 : 0.80)
                : AppTheme.hairlineColour(theme.brightness),
            width: rim,
          ),
          // A soft gold light round the key that is on: a glow, not a
          // halo — it stays within the gap to the next key. None at all
          // round the others: a shadow is painted blurred whatever its
          // colour, so a transparent one was seven blurs for nothing. The
          // container lerps the list's length, so the light still rises
          // and falls over the change.
          boxShadow: on
              ? [
                  BoxShadow(
                    color: AppTheme.gold.withValues(alpha: dark ? 0.26 : 0.20),
                    blurRadius: 10,
                    spreadRadius: -2,
                  ),
                ]
              : const [],
        ),
        // 0 off, 1 on: the glyph and the word each turn from the quiet ink
        // to their own gold together.
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: on ? 1 : 0),
          duration: Motion.base,
          curve: Motion.standard,
          builder: (context, lit, _) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                shelf.icon,
                size: iconSize,
                color: Color.lerp(quiet, champagne, lit),
              ),
              const SizedBox(height: iconGap),
              Text(
                shelf.label,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                overflow: TextOverflow.visible,
                style: labelStyle(
                  theme,
                  on: on,
                ).copyWith(color: Color.lerp(quiet, wordOn, lit)),
              ),
            ],
          ),
        ),
      );
      final body = PressScale(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('store-tab-${shelf.tab.name}'),
            borderRadius: BorderRadius.circular(Radii.sm),
            enableFeedback: soundOn(context),
            onTap: on
                ? null
                : () {
                    tapHaptic(context);
                    onChanged(shelf.tab);
                  },
            child: AnimatedScale(
              scale: on ? 1 : quietScale,
              duration: Motion.base,
              curve: Motion.standard,
              child: face,
            ),
          ),
        ),
      );
      // A screen reader hears which shelf is on.
      return Semantics(selected: on, button: true, child: body);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (r, row) in layout.rows.indexed) ...[
          if (r > 0) const SizedBox(height: runGap),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, index) in row.indexed) ...[
                if (i > 0) SizedBox(width: layout.gap),
                key(index),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// The keys in header order, with what each one shows.
  static List<({StoreTab tab, IconData icon, String label})> _shelves(
    Strings t,
    bool animatedOnly,
  ) => [
    (tab: StoreTab.chips, icon: Icons.toll_rounded, label: t.storeTabChips),
    (
      tab: StoreTab.diamonds,
      icon: Icons.diamond_rounded,
      label: t.storeTabDiamonds,
    ),
    (tab: StoreTab.hammers, icon: Icons.hardware, label: t.storeTabHammers),
    (tab: StoreTab.missiles, icon: missileIcon, label: t.storeTabMissiles),
    animatedOnly
        ? (
            tab: StoreTab.pictures,
            icon: Icons.auto_awesome_rounded,
            label: t.storeTabAnimated,
          )
        : (
            tab: StoreTab.pictures,
            icon: Icons.face_rounded,
            label: t.storeTabPictures,
          ),
    (
      tab: StoreTab.tables,
      icon: Icons.table_bar_rounded,
      label: t.storeTabTables,
    ),
    // Offered in the lobby and at a table alike: an emoji priced in hammers
    // or diamonds may be bought mid-sitting, and sent at once.
    (
      tab: StoreTab.emojis,
      icon: Icons.emoji_emotions_rounded,
      label: t.storeTabEmojis,
    ),
    // Offered at a table too: a badge moves no chips, and its rate is the
    // seat's from the next hand's end.
    (
      tab: StoreTab.badges,
      icon: Icons.workspace_premium_rounded,
      label: t.storeTabBadges,
    ),
  ];
}

/// Opens the store.
///
/// A bottom sheet, laid out exactly like the picture picker: the same glass
/// panel, the same grab handle, the same header, and the same vertically
/// scrolling body under the same scrollbar. They are the two shelves in this
/// game — one sells pictures, one sells chips — and until now they arrived
/// differently, one rising from the floor and one unfolding in the middle of
/// the screen, which made them feel like two unrelated parts of the app.
///
/// `showGeneralDialog` rather than `showDialog` so the scrim and the entrance
/// are ours. A scrim is always dark, whatever the theme: the ground's own edge
/// is a pale slate in the light scheme, so dimming with it BRIGHTENED the lobby
/// behind the store instead of pushing it back.
///
/// [opensOn] is the shelf showing when it opens: Chips from the Shop key, and
/// Hammers when a Force Sideshow found the player's wallet empty.
Future<void> showChipStore(
  BuildContext context, {
  StoreTab opensOn = StoreTab.chips,
}) {
  // Where the store was opened decides what it sells, and that holds for as
  // long as it is open. Worked out again on every build, a kick while the
  // table's store was up turned it into the lobby's under the player's finger.
  final atTable = context.read<GameState>().screen == Screen.table;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: AppTheme.ink900.withValues(alpha: 0.72),
    transitionDuration: Motion.slow,
    pageBuilder: (_, a, b) => _ChipStore(atTable: atTable, opensOn: opensOn),
    transitionBuilder: (context, anim, _, child) {
      // Rises from the foot of the screen and settles, which is how the
      // picture picker arrives too — the two shelves should not open in two
      // different ways. In [Motion.slow] (300ms; it took 420): the owner's
      // brief of 27 Sep 2026 asks 200-300ms of a drawer's entrance.
      final fade = Motion.standard.transform(anim.value);
      return Opacity(
        opacity: fade,
        child: Transform.translate(
          offset: Offset(0, 40 * (1 - fade)),
          child: child,
        ),
      );
    },
  );
}

class _ChipStore extends StatefulWidget {
  const _ChipStore({required this.atTable, required this.opensOn});

  /// The shelf showing when the store opens.
  final StoreTab opensOn;

  /// Whether the store was opened at a table, where its picture key sells the
  /// animated shelf alone (owner, 13 Sep 2026). Fixed when it opens.
  final bool atTable;

  @override
  State<_ChipStore> createState() => _ChipStoreState();
}

class _ChipStoreState extends State<_ChipStore> {
  /// Play's own prices, in the player's currency. Fetched when the store
  /// opens rather than held on the state: prices are Play's to change, and a
  /// figure cached across sessions could be wrong by the time it is shown.
  Map<String, ProductDetails> _prices = const {};

  /// Built in initState, never lazily: a late controller first read in
  /// dispose() is the teardown trap CLAUDE.md §12.3 documents.
  final ScrollController _scroller = ScrollController();

  /// The body's scroll view, kept — its position and its shelf's entrance —
  /// when the fade over it comes and goes with the shelf.
  final GlobalKey _bodyKey = GlobalKey();

  /// Which shelf is showing. Set from [_ChipStore.opensOn] in initState.
  StoreTab _tab = StoreTab.chips;

  /// The picture shelf's filter, as in the picker; it opens on All. At a table
  /// the shelf is the animated one whatever this says.
  PictureFilter _shelf = PictureFilter.all;

  /// Which way the Pictures tab's prices run (owner, 14 Sep 2026).
  PictureSort _order = PictureSort.lowToHigh;

  /// Back to the top when the shelf under the scrollbar changes, so a switch
  /// never lands part-way down a list the player has not seen.
  void _toTop() {
    if (_scroller.hasClients) _scroller.jumpTo(0);
  }

  /// Moves the store to [next], back to the top of the new shelf. Its key
  /// is always on screen: the navigation never scrolls ([_StoreTabs]).
  void _show(StoreTab next) {
    if (!mounted) return;
    setState(() {
      _tab = next;
      _toTop();
    });
  }

  @override
  void initState() {
    super.initState();
    _tab = widget.opensOn;
    _loadPrices();
    // The badges are the server's (GET /api/levels): read them now if they
    // are not on the phone yet, then ask Play what the ones it sells cost.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<GameState>();
      if (state.levelLadder == null) {
        state.loadLevelLadder().then((_) {
          if (mounted) _loadPrices();
        });
      }
    });
  }

  @override
  void dispose() {
    _scroller.dispose();
    super.dispose();
  }

  /// Trades for one missile pack, from its card: asks first, and on the way
  /// out closes the store (it worked), moves it to the Diamonds shelf (the
  /// player could not pay), or leaves it as it is.
  Future<void> _trade(MissilePack pack) async {
    final outcome = await _tradeMissilePack(context, pack);
    if (!mounted) return;
    switch (outcome) {
      case _TradeOutcome.done:
        Navigator.pop(context);
      case _TradeOutcome.toDiamonds:
        _show(StoreTab.diamonds);
      case _TradeOutcome.stay:
        break;
    }
  }

  Future<void> _loadPrices() async {
    // One query for every shelf: Play answers per product id, and a player
    // flicking between the Chips, Diamonds and Hammers tabs should see prices
    // at once. The Premium Packages sit on the Chips shelf.
    final state = context.read<GameState>();
    final got = await state.purchases.priceList({
      ...chipPacks.map((p) => p.productId),
      ...premiumPacks.map((p) => p.productId),
      ...diamondPacks.map((p) => p.productId),
      ...hammerPacks.map((p) => p.productId),
      // The badges Play sells, as far as the ladder on the phone says.
      for (final b in state.levelLadder?.badges ?? const <LadderBadge>[])
        if (b.buyable) b.productId,
    });
    if (mounted && got.isNotEmpty) setState(() => _prices = got);
  }

  /// The space round the shelf inside its scroll view: room on the right for
  /// the scrollbar, and a hair on the left and at the top so the outer cards'
  /// rims and shadows are not cut by the scroll view's clip.
  static const EdgeInsets _bodyPadding = EdgeInsets.fromLTRB(
    Space.xs,
    Space.xs,
    Space.md,
    Space.md,
  );

  /// The strip of scrim left above the sheet: 3% of the screen, from 10dp
  /// on a phone to 40 on a tablet — enough to show the store is laid over
  /// the game, and a place to tap it away.
  static double sheetGap(Size size) =>
      (size.height * 0.03).clamp(Space.md, 40.0);

  /// The sheet's height on a screen of [size] with [safe] insets: the screen
  /// less its safe area, the sheet's margin at its foot and [sheetGap]. It
  /// was 88% of the screen, which on a 360dp phone left 43dp of scrim above
  /// the store and, with the navigation in a row of its own, too little for
  /// a row of products at the 1.25 text scale.
  static double sheetHeight(Size size, EdgeInsets safe) =>
      math.max(0, size.height - safe.vertical - Space.md - sheetGap(size));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<GameState>();
    final t = state.t;
    // At a table the picture key sells the animated shelf alone, with no shelf
    // menu (owner, 13 Sep 2026); the lobby keeps every shelf.
    final atTable = widget.atTable;
    final atPokerRoom = atTable && (state.room?.isPoker ?? false);
    final tab = _tab;
    final onPictures = tab == StoreTab.pictures;
    final onTables = tab == StoreTab.tables;
    final onDiamonds = tab == StoreTab.diamonds;
    final onHammers = tab == StoreTab.hammers;
    final onMissiles = tab == StoreTab.missiles;
    final onChips = tab == StoreTab.chips;
    final onEmojis = tab == StoreTab.emojis;
    final size = MediaQuery.sizeOf(context);
    final scaler = MediaQuery.textScalerOf(context);

    // Every height here is measured from what it holds, and the shelf gets
    // whatever is left. Two rows head the sheet (owner, 27 Sep 2026: "Do not
    // squeeze everything into one row"):
    //
    //  * the HEADER: the shelf's glyph, its title over its blurb, the shelf's
    //    balance and the close key — the title and blurb, or the close key's
    //    touch target, whichever is taller;
    //  * the NAVIGATION under it, the sheet's whole width, every shelf's key
    //    on screen at once ([_StoreTabs]).
    //
    // The balance stands in the header on every screen: it can never meet a
    // key there, and the keys keep the whole width they need. The header row
    // is the screen less the safe area, the sheet's margin and its padding;
    // its fixed parts are the shelf's glyph, a balance, the close key and the
    // gaps between them. A balance is counted on every shelf — the widest of
    // the chips, a diamond or hammer count, the Pictures pair and the Missiles
    // pair — and the widest blurb of all the shelves decides how many lines
    // the blurb takes, so the navigation never moves under a finger on the
    // way from one shelf to the next.
    final safe = MediaQuery.paddingOf(context);
    // A landscape phone: the height is what the store is short of.
    final short = Breaks.isShort(size.height);
    // On a phone the shelf's own controls stand beside its products, not
    // over them ([_ChipStoreState._sideControls]); a tablet has the height.
    final beside = !Breaks.isExpanded(size.width);
    final headerW =
        size.width - safe.left - safe.right - 2 * Space.md - 2 * Space.lg;
    //
    // The Pictures shelf heads with two wallets, diamonds and hammers, in one
    // pill (owner, 14 Sep 2026: the animated pictures cost hammers). It is
    // counted here as it is when stacked — no wider than one balance — and
    // laid out in a row only where the widest blurb still keeps its line
    // beside the row. The Missiles shelf heads the same way with the missiles
    // held and the diamonds a pack is traded for (owner, 24 Sep 2026: "it
    // should also show the user current missile count just like it is
    // showing diamond count"), and is counted and laid out by the same rule.
    const balanceW = 72.0;
    final diamonds = state.user?.diamond ?? 0;
    final hammers = state.user?.hammer ?? 0;
    // Read on every build, under the store's watch, so a pack traded on the
    // shelf counts up here the moment the wallet comes back from the server.
    final missiles = state.user?.missile ?? 0;
    // The chips the Chips shelf heads with (owner, 24 Sep 2026): at a table
    // the seat's own stack — what the drawer's "Your chips" row shows, and
    // where a pack bought there lands — and in the lobby the wallet. Read on
    // every build, under the store's watch, so a pack landing counts up here
    // as it does in the lobby bar.
    final chips = state.room?.you?.chips ?? state.user?.chips ?? 0;
    final walletPairRowW = PictureWalletBalances.width(
      context,
      diamonds: diamonds,
      hammers: hammers,
      stacked: false,
    );
    final missilePairRowW = MissileWalletBalances.width(
      context,
      missiles: missiles,
      diamonds: diamonds,
      stacked: false,
    );
    final walletW = [
      balanceW,
      PictureWalletBalances.width(
        context,
        diamonds: diamonds,
        hammers: hammers,
        stacked: true,
      ),
      MissileWalletBalances.width(
        context,
        missiles: missiles,
        diamonds: diamonds,
        stacked: true,
      ),
      ChipBalance.width(context, chips: chips),
    ].reduce(math.max);
    final fixedW = 22 + Space.md + Space.md + walletW + Space.sm + Dim.minTouch;
    final blurbStyle = theme.textTheme.bodySmall ?? const TextStyle();
    final blurbs = [
      t.storeBlurb,
      t.storeDiamondsBlurb,
      t.storeHammersBlurb,
      t.storeMissilesBlurb,
      atTable ? t.storeAnimatedBlurb : t.storePicturesBlurb,
      t.storeTablesBlurb,
      t.storeEmojisBlurb,
      t.storeBadgesBlurb,
      if (atPokerRoom) t.tablePokerNote,
    ];
    var blurbW = 0.0;
    for (final blurb in blurbs) {
      final painter = TextPainter(
        text: TextSpan(text: blurb, style: blurbStyle),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      blurbW = math.max(blurbW, painter.width.ceilToDouble());
      painter.dispose();
    }
    // How many lines the longest blurb takes when given [width].
    int blurbLinesAt(double width) {
      var most = 1;
      for (final blurb in blurbs) {
        final painter = TextPainter(
          text: TextSpan(text: blurb, style: blurbStyle),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: math.max(1, width));
        most = math.max(most, painter.computeLineMetrics().length);
        painter.dispose();
      }
      return most;
    }

    // What the title and blurb have beside the balance and the close key. It
    // used to share the row with the shelf keys too, and on a 640dp phone the
    // blurb was down to two lines of a narrow column.
    final columnW = headerW - fixedW;
    final blurbLines = blurbLinesAt(columnW).clamp(1, 3);
    // A pair of wallets stands in a row where the widest blurb still keeps
    // its one line beside the row, and stacked otherwise.
    final walletPairInRow = columnW - (walletPairRowW - walletW) >= blurbW;
    final missilePairInRow = columnW - (missilePairRowW - walletW) >= blurbW;
    final nav = _StoreTabs.layoutFor(
      context,
      t,
      width: headerW,
      animatedOnly: atTable,
      short: short,
    );
    // Each line the taller of the Latin line and the tallest the shelves'
    // own words make in the fonts the phone draws them in (_measuredLine), so
    // a Hindi, Bengali, Gujarati or Punjabi header is not a pixel short.
    final titleStyle = AppTheme.label(
      theme.textTheme.titleMedium ?? const TextStyle(),
    );
    final titleLine = math.max(
      _line(scaler, 17, 1.25),
      _measuredLine(context, scaler, titleStyle, [
        t.storeTitle,
        t.storeDiamondsTitle,
        t.storeHammersTitle,
        t.storeMissilesTitle,
        atTable ? t.picturePremiumAnimated : t.storeTabPictures,
        t.storeTablesTitle,
        t.storeEmojisTitle,
        t.storeBadgesTitle,
      ]),
    );
    final blurbLine = math.max(
      _line(scaler, 12, 1.35),
      _measuredLine(context, scaler, blurbStyle, blurbs),
    );
    final headerH = math.max(Dim.minTouch, titleLine + blurbLines * blurbLine);

    // Gold as ink by theme: the champagne the Pictures and Tables glyphs were
    // drawn in on both themes all but vanished on the light sheet.
    final champagne = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;
    final (IconData? glyph, Color glyphInk) = switch (tab) {
      StoreTab.pictures => (Icons.face_rounded, champagne),
      StoreTab.tables => (Icons.table_bar_rounded, champagne),
      StoreTab.emojis => (Icons.emoji_emotions_rounded, champagne),
      StoreTab.badges => (Icons.workspace_premium_rounded, champagne),
      StoreTab.diamonds => (
        Icons.diamond_rounded,
        diamondInkOn(theme.brightness),
      ),
      StoreTab.hammers => (Icons.hardware, hammerInkOn(theme.brightness)),
      StoreTab.missiles => (missileIcon, missileInkOn(theme.brightness)),
      StoreTab.chips => (null, AppTheme.gold),
    };
    final title = switch (tab) {
      StoreTab.pictures =>
        atTable ? t.picturePremiumAnimated : t.storeTabPictures,
      StoreTab.tables => t.storeTablesTitle,
      StoreTab.emojis => t.storeEmojisTitle,
      StoreTab.badges => t.storeBadgesTitle,
      StoreTab.diamonds => t.storeDiamondsTitle,
      StoreTab.hammers => t.storeHammersTitle,
      StoreTab.missiles => t.storeMissilesTitle,
      StoreTab.chips => t.storeTitle,
    };
    final blurb = switch (tab) {
      StoreTab.pictures =>
        atTable ? t.storeAnimatedBlurb : t.storePicturesBlurb,
      // A poker room's felt shows no table picture: the shelf still sells,
      // and says where the cloth will show.
      StoreTab.tables => atPokerRoom ? t.tablePokerNote : t.storeTablesBlurb,
      StoreTab.emojis => t.storeEmojisBlurb,
      StoreTab.badges => t.storeBadgesBlurb,
      StoreTab.diamonds => t.storeDiamondsBlurb,
      StoreTab.hammers => t.storeHammersBlurb,
      StoreTab.missiles => t.storeMissilesBlurb,
      StoreTab.chips => t.storeBlurb,
    };

    // Sits at the foot of the screen like the picture picker's sheet, rather
    // than in the middle of it: the two shelves are the same kind of thing and
    // should arrive in the same place.
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
          // One height whatever the shelf holds, so the header and its keys
          // stay put from Chips to Diamonds to Pictures. Sized to its content,
          // the sheet shrank under the four diamond packs, and a tap aimed at
          // the next key landed on the scrim and closed the store. Only the
          // packs scroll.
          //
          // As tall as the screen allows less a strip of scrim above it
          // ([sheetGap]): the navigation has a row of its own since 27 Sep
          // 2026, and on a 360dp phone the 12% of the screen the sheet left
          // above itself was the products' height, not the scrim's.
          child: SizedBox(
            height: sheetHeight(size, safe),
            child: PremiumGlassPanel(
              // A modal, and the only one of its kind on screen: it may take the
              // app's single blur if nothing louder has claimed it. The blur
              // radius is the theme's own (GlassColors.sigma).
              mode: GlassMode.auto,
              priority: 20,
              radius: Radii.lg,
              // On a short screen every dp over the navigation's own row is
              // a dp of the products', so the sheet there has no grab handle
              // (a mark on a sheet that does not drag, and 16dp of a 360dp
              // phone) and a step less at its foot.
              padding: EdgeInsets.fromLTRB(
                Space.lg,
                short ? Space.md : Space.sm,
                Space.lg,
                short ? Space.md : Space.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The grab handle, at the resting hairline: it marks the
                  // sheet's top edge and asks for nothing (it was at the live
                  // gold, the brightest line on the sheet). Not on a short
                  // screen, above.
                  if (!short) ...[
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.pill),
                          color: AppTheme.hairlineColour(theme.brightness),
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                  ],
                  SizedBox(
                    height: headerH,
                    child: Row(
                      children: [
                        // The shelf's glyph and its name turn over together
                        // when the shelf changes: a fade and a small scale,
                        // quick, never a slide.
                        SizedBox.square(
                          dimension: 22,
                          child: AnimatedSwitcher(
                            duration: Motion.base,
                            switchInCurve: Motion.standard,
                            transitionBuilder: _fadeScale,
                            child: KeyedSubtree(
                              key: ValueKey(tab),
                              child: glyph == null
                                  ? const PokerChip(
                                      colour: AppTheme.gold,
                                      size: 22,
                                    )
                                  : Icon(glyph, size: 22, color: glyphInk),
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: Motion.base,
                            switchInCurve: Motion.standard,
                            transitionBuilder: _fadeScale,
                            layoutBuilder: (current, previous) => Stack(
                              alignment: AlignmentDirectional.centerStart,
                              children: [...previous, ?current],
                            ),
                            child: Column(
                              key: ValueKey(tab),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // The strongest words in the header: the
                                // shelf's name. The line under it is the
                                // quiet tier.
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: titleStyle.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  blurb,
                                  maxLines: blurbLines,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurface.withValues(
                                      alpha: AppTheme.inkLowOn(
                                        theme.brightness,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        // The shelf's balance, beside the close key and away
                        // from the shelf keys, which have a row of their own
                        // under the header: the two can never meet (owner,
                        // 27 Sep 2026: "The balance pill and the icons must
                        // never collide"). Chips heads with the chips
                        // themselves since 24 Sep 2026 (owner: "when user
                        // click on Coins tab, then it is not showing users
                        // current coin on top, just like we show for
                        // hammer"). The Missiles shelf heads with the missiles
                        // held and, since its packs are paid for in diamonds,
                        // the diamonds there are to trade — both since 24 Sep
                        // 2026 (owner: "when user click on Missile tab, then
                        // it should also show the user current missile count
                        // just like it is showing diamond count"); Pictures
                        // with both wallets a picture can cost besides chips.
                        // The Tables and Emojis shelves are priced in the
                        // same three wallets as the pictures, so they head
                        // the same way. The Badges shelf is priced in rupees
                        // and heads with no balance.
                        if (onChips) ChipBalance(chips: chips),
                        if (onPictures || onTables || onEmojis)
                          PictureWalletBalances(
                            diamonds: diamonds,
                            hammers: hammers,
                            stacked: !walletPairInRow,
                          ),
                        if (onDiamonds) DiamondBalance(count: diamonds),
                        if (onMissiles)
                          MissileWalletBalances(
                            missiles: missiles,
                            diamonds: diamonds,
                            stacked: !missilePairInRow,
                          ),
                        if (onHammers) HammerBalance(count: hammers),
                        const SizedBox(width: Space.sm),
                        PressScale(
                          child: IconButton(
                            tooltip: t.close,
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded, size: 22),
                            color: scheme.onSurface.withValues(
                              alpha: AppTheme.inkMed,
                            ),
                            // A Material icon button lays out at 48 whatever its
                            // icon does, which is 4dp more than the header is
                            // tall. The touch floor is Dim.minTouch, so say so.
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              minimumSize: const Size.square(Dim.minTouch),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // A step closer on a short screen, where the products are
                  // short of height: the keys' own rims set them apart.
                  SizedBox(height: short ? Space.xs : Space.sm),
                  // Every shelf's key, all on screen, in rows of their own
                  // the sheet's whole width — one where the words fit it,
                  // balanced rows where they cannot ([_StoreTabs.layoutFor]).
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _StoreTabs(
                      value: tab,
                      layout: nav,
                      animatedOnly: atTable,
                      onChanged: _show,
                    ),
                  ),
                  SizedBox(height: short ? Space.xs : Space.sm),
                  // The Pictures shelf heads its grid with the picture being
                  // worn, beside the shelf's two menus — over the grid on a
                  // tablet, beside it on a phone ([_sideControls]).
                  if (onPictures && !beside) ...[
                    _PicturesHead(
                      atTable: atTable,
                      filter: _shelf,
                      order: _order,
                      onFilter: (f) => setState(() {
                        _shelf = f;
                        _toTop();
                      }),
                      onOrder: (s) => setState(() {
                        _order = s;
                        _toTop();
                      }),
                    ),
                    const SizedBox(height: Space.sm),
                  ],
                  // Expanded, so a short shelf sits at the top of the fixed
                  // body rather than letting the sheet shrink around it.
                  Expanded(
                    child: _sideControls(
                      beside: beside,
                      onPictures: onPictures,
                      onTables: onTables,
                      maxWidth: headerW * _sideShare,
                      pictures: () => _PicturesHead(
                        atTable: atTable,
                        filter: _shelf,
                        order: _order,
                        rail: true,
                        onFilter: (f) => setState(() {
                          _shelf = f;
                          _toTop();
                        }),
                        onOrder: (s) => setState(() {
                          _order = s;
                          _toTop();
                        }),
                      ),
                      body: LayoutBuilder(
                        builder: (context, body) {
                          final grid = _ShelfGeometry.of(
                            width: body.maxWidth - _bodyPadding.horizontal,
                            height: body.maxHeight - _bodyPadding.vertical,
                            screenWidth: size.width,
                          );
                          final scroll = SingleChildScrollView(
                            key: _bodyKey,
                            controller: _scroller,
                            padding: _bodyPadding,
                            // A new shelf fades in with a small scale, at once
                            // — the one it replaces does not linger under it.
                            child: AnimatedSwitcher(
                              duration: Motion.base,
                              switchInCurve: Motion.standard,
                              transitionBuilder: _fadeScale,
                              layoutBuilder: (current, _) =>
                                  current ?? const SizedBox.shrink(),
                              child: KeyedSubtree(
                                key: ValueKey(tab),
                                child: _shelfBody(
                                  context,
                                  state,
                                  grid,
                                  shelfW:
                                      body.maxWidth - _bodyPadding.horizontal,
                                  beside: beside,
                                ),
                              ),
                            ),
                          );
                          return ScrollbarTheme(
                            data: ScrollbarThemeData(
                              thickness: const WidgetStatePropertyAll(4),
                              radius: const Radius.circular(Radii.pill),
                              thumbColor: WidgetStatePropertyAll(
                                AppTheme.hairlineColour(
                                  theme.brightness,
                                  live: true,
                                ),
                              ),
                            ),
                            child: Scrollbar(
                              controller: _scroller,
                              thumbVisibility: true,
                              // A row of packs cut by the foot of the sheet
                              // fades out rather than stopping on a hard line:
                              // there is more below, and it reads as that. Only
                              // on the pack shelves, whose cards stand still: a
                              // mask over the Pictures and Tables shelves, whose
                              // Lotties and chips move every frame, would be an
                              // offscreen pass every frame.
                              child: onPictures || onTables || onEmojis
                                  ? scroll
                                  : EdgeFade(child: scroll),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The most of the header's width a phone's side controls take
  /// ([_sideControls]): enough for the widest order menu at the 1.25 text
  /// scale, and never so much that the tiles beside it lose a column.
  static const double _sideShare = 0.4;

  /// The products' area, with the shelf's own controls — the Pictures
  /// shelf's worn picture and menus, the Tables shelf's day/night switch —
  /// beside it on a phone ([beside]) rather than over it.
  ///
  /// On a 360dp phone at the 1.25 text scale the header and the row of shelf
  /// keys leave the products some 190dp, and a row of faces with two-line
  /// names and a rental's term stands 160dp: with the worn picture's 57dp
  /// head over the grid the first row was cut through its names, with
  /// nothing of the next showing, and the Tables shelf's switch did the same
  /// to its row of tables (review, 27 Sep 2026); at 844x390 and 915x412 the
  /// faces were cut the same way. A landscape phone is short of height and
  /// has width to spare, so there the controls stand in a column of their
  /// own at the side, and the grid under the navigation starts with the
  /// products. A tablet keeps them over the grid.
  Widget _sideControls({
    required bool beside,
    required bool onPictures,
    required bool onTables,
    required double maxWidth,
    required Widget Function() pictures,
    required Widget body,
  }) {
    if (!beside || !(onPictures || onTables)) return body;
    // Level with the first row's top edge, below the body's own inset.
    final top = EdgeInsets.only(top: _bodyPadding.top);
    if (onPictures) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: top,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              // As wide as its widest menu, and no wider than [maxWidth]; a
              // long picture name gives way first, cut short.
              child: IntrinsicWidth(child: pictures()),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(child: body),
        ],
      );
    }
    // The Tables shelf's day/night switch stays at the right, where it
    // stands over the shelf on a taller screen.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: body),
        const SizedBox(width: Space.md),
        Padding(padding: top, child: const DayNightSwitch()),
      ],
    );
  }

  /// What the shelf that is on holds, laid out on [grid], in a shelf
  /// [shelfW] wide; [beside] says the shelf's controls stand at its side
  /// ([_sideControls]).
  Widget _shelfBody(
    BuildContext context,
    GameState state,
    _ShelfGeometry grid, {
    required double shelfW,
    required bool beside,
  }) {
    final prices = _prices;
    final size = MediaQuery.sizeOf(context);
    switch (_tab) {
      case StoreTab.pictures:
        return SizedBox(
          // Full width, so the grid starts under its menu rather than
          // centring in the sheet the way the pack shelf does.
          width: double.infinity,
          child: pictureShelf(
            context: context,
            state: state,
            filter: widget.atTable ? PictureFilter.animated : _shelf,
            sort: _order,
            // The picker's tile size, so a face is the same size wherever it
            // is on sale.
            radius: (size.height * 0.105).clamp(32.0, 52.0),
            // A picture whose wallet is short sends the player to its shelf
            // in this store, not to a second store over it.
            openStore: _show,
          ),
        );
      case StoreTab.tables:
        return SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A day/night switch over the shelf (owner, 16 Sep 2026: "give
              // one button for switching day to dark mode"): every tile
              // previews both halves, and this flips the theme — the felt
              // behind the sheet and the sheet's own glass — so either look is
              // seen whole, as the picture menu's switch does. On a phone it
              // stands beside the shelf instead ([_sideControls]).
              if (!beside)
                const Padding(
                  padding: EdgeInsets.fromLTRB(0, 0, Space.lg, Space.sm),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: DayNightSwitch(),
                  ),
                ),
              tablePictureShelf(
                context: context,
                state: state,
                // The width a pack card had before the pack shelves filled
                // their rows (Dim.packW): a table tile stands a preview, a
                // tag and a name tall, and at the widened width its first
                // row no longer fit a 640x360 phone at the 1.25 text scale.
                // Beside the switch on a narrow phone, the shelf keeps three
                // tables to the row, each at most a tenth narrower.
                width: beside
                    ? math.min(
                        Dim.packW(size.width),
                        math.max(
                          Dim.packW(size.width) * 0.9,
                          ((shelfW - 2 * Space.md) / 3).floorToDouble(),
                        ),
                      )
                    : Dim.packW(size.width),
                openStore: _show,
              ),
            ],
          ),
        );
      case StoreTab.badges:
        return _badgeShelf(context, state, grid);
      case StoreTab.emojis:
        return SizedBox(
          width: double.infinity,
          child: emojiShelf(
            context: context,
            state: state,
            // The picture shelf's tile size, so an emoji stands as large as
            // a face does wherever it is on sale.
            side: 2 * (size.height * 0.105).clamp(32.0, 52.0),
            openStore: _show,
          ),
        );
      case StoreTab.diamonds:
        final figure = _countFigure(context, grid, [
          for (final p in diamondPacks) '${p.diamonds}',
        ]);
        return _packGrid('diamonds', grid, [
          for (final (i, p) in diamondPacks.indexed)
            _CountPackCard.diamonds(
              p,
              index: i,
              prices: prices,
              figure: figure,
            ),
        ]);
      case StoreTab.hammers:
        final figure = _countFigure(context, grid, [
          for (final p in hammerPacks) '${p.hammers}',
        ]);
        return _packGrid('hammers', grid, [
          for (final (i, p) in hammerPacks.indexed)
            _CountPackCard.hammers(p, index: i, prices: prices, figure: figure),
        ]);
      case StoreTab.missiles:
        final figure = _countFigure(context, grid, [
          for (final p in missilePacks) '${p.missiles}',
        ]);
        return _packGrid('missiles', grid, [
          for (final (i, p) in missilePacks.indexed)
            _CountPackCard.missiles(
              p,
              index: i,
              onTrade: () => _trade(p),
              figure: figure,
            ),
        ]);
      case StoreTab.chips:
        final packs = _CardMetrics.of(Size(grid.cardW, grid.cardH));
        final chipFigure = _fitFigures(context, packs, [
          for (final p in chipPacks) (formatChips(p.chips), null),
        ], iconAspect: _chipStackAspect);
        final premium = _CardMetrics.of(Size(grid.cardW, grid.premiumH));
        final premiumFigure = _fitFigures(context, premium, [
          for (final p in premiumPacks)
            (formatChips(p.chips), shelfMarkGlyph(p.mark)),
        ]);
        return Column(
          mainAxisSize: MainAxisSize.min,
          // Both grids hold cards of one width, so their rows line up; the
          // heading starts where they do.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _packGrid('chips', grid, [
              for (final (i, p) in chipPacks.indexed)
                _PackCard(
                  pack: p,
                  index: i,
                  prices: prices,
                  figure: chipFigure,
                ),
            ]),
            // The Premium Packages (owner, 14 Sep 2026): a category of their
            // own under the chip packs, set out after them.
            const SizedBox(height: Space.xl),
            _PremiumHeading(label: state.t.premiumPackages),
            const SizedBox(height: Space.md),
            _packGrid(
              'premium',
              grid,
              [
                for (final p in premiumPacks)
                  _PremiumPackCard(
                    pack: p,
                    prices: prices,
                    figure: premiumFigure,
                  ),
              ],
              height: grid.premiumH,
              first: chipPacks.length,
            ),
          ],
        );
    }
  }

  /// The size every count on a diamond, hammer or missile shelf is set in.
  double _countFigure(
    BuildContext context,
    _ShelfGeometry grid,
    List<String> counts,
  ) => _fitFigures(context, _CardMetrics.of(Size(grid.cardW, grid.cardH)), [
    for (final count in counts) (count, null),
  ], iconAspect: 1);

  /// The Badges shelf: every badge the store lists ([LadderBadge.listed] —
  /// the Royal badges: owner, 27 Sep 2026, "for badges use this entry, not
  /// vips entry"), any Play sells first — each a product card
  /// with its art playing, its price as the figure, its name, rate and how
  /// long it lasts and, where the player holds it, how long theirs has left.
  /// Until the ladder is read, a spinner; where it cannot be, a line and Try
  /// again.
  Widget _badgeShelf(
    BuildContext context,
    GameState state,
    _ShelfGeometry grid,
  ) {
    final ladder = state.levelLadder;
    final theme = Theme.of(context);
    if (ladder == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xl),
        child: Center(
          child: state.levelLadderFailed && !state.levelLadderLoading
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      state.t.levelsUnavailable,
                      style: theme.textTheme.bodySmall,
                    ),
                    TextButton(
                      key: const ValueKey('badges-retry'),
                      onPressed: () => state.loadLevelLadder().then((_) {
                        if (mounted) _loadPrices();
                      }),
                      child: Text(state.t.luckyRetry),
                    ),
                  ],
                )
              : const GameLoader(size: 32),
        ),
      );
    }
    final shown = [
      for (final b in ladder.badges)
        if (b.listed && b.buyable) b,
      for (final b in ladder.badges)
        if (b.listed && !b.buyable) b,
    ];
    // One art size for the shelf, as one figure size is for a pack shelf.
    final figure = _countFigure(context, grid, [
      for (final b in shown) formatTaxRate(b.taxBps ?? 0),
    ]);
    return _packGrid('badges', grid, [
      for (final (i, b) in shown.indexed)
        _BadgeCard(
          key: ValueKey('badge-card-${b.code}'),
          badge: b,
          index: i,
          prices: _prices,
          figure: figure,
        ),
    ]);
  }

  /// A shelf of packs on [grid], set out one stagger apart. Keyed by shelf,
  /// so moving from one pack shelf to another sets the new one out afresh
  /// instead of reusing the last one's cards.
  Widget _packGrid(
    String shelf,
    _ShelfGeometry grid,
    List<Widget> cards, {
    double? height,
    int first = 0,
  }) => Wrap(
    spacing: _ShelfGeometry.gap,
    runSpacing: _ShelfGeometry.gap,
    children: [
      for (final (i, card) in cards.indexed)
        SizedBox(
          key: ValueKey('$shelf-$i'),
          width: grid.cardW,
          height: height ?? grid.cardH,
          child: _PackEntrance(index: first + i, child: card),
        ),
    ],
  );
}

/// A shelf or a header line arriving: a fade and a small scale, from the
/// top, quick (premium store polish, 26 Sep 2026: "Category change: Fade +
/// small scale").
Widget _fadeScale(Widget child, Animation<double> animation) => FadeTransition(
  opacity: animation,
  child: ScaleTransition(
    scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
    alignment: Alignment.topCenter,
    child: child,
  ),
);

/// How a shelf's cards stand in the store's body.
///
/// As many columns as fit at the pack width ([Dim.packW], now the least a
/// card may be), widened to fill the row: at a fixed width a 640dp phone's
/// three cards stood in the middle of the sheet with 95dp empty either side,
/// and a figure like "35.2 Crore" was shrunk to fit a card with room to spare
/// beside it (premium store polish, 26 Sep 2026: "avoid excessive empty
/// space ... product card widths"). A card keeps the lobby card's near-square
/// proportions where the body is tall enough, and is never taller than
/// [glimpse] of the body, so a row of the shelf past the fold always shows —
/// what says the shelf goes on.
@immutable
class _ShelfGeometry {
  const _ShelfGeometry._({
    required this.columns,
    required this.cardW,
    required this.cardH,
    required this.premiumH,
  });

  factory _ShelfGeometry.of({
    required double width,
    required double height,
    required double screenWidth,
  }) {
    final least = Dim.packW(screenWidth);
    final columns = math.max(1, ((width + gap) / (least + gap)).floor());
    // Whole pixels, so a row of cards never adds up to a hair more than the
    // row and wraps its last card.
    final cardW = math
        .max(1.0, (width - (columns - 1) * gap) / columns)
        .floorToDouble();
    final cardH = math
        .max(1.0, math.min(cardW * square, height * glimpse))
        .floorToDouble();
    return _ShelfGeometry._(
      columns: columns,
      cardW: cardW,
      cardH: cardH,
      premiumH: math
          .max(1.0, math.min(cardH * premiumRise, height))
          .floorToDouble(),
    );
  }

  /// Between two cards, across and down.
  static const double gap = Space.md;

  /// The lobby card's proportions: near square.
  static const double square = 1.05;

  /// The most of the body's height one card may take.
  static const double glimpse = 0.80;

  /// A Premium Package's card over a pack's: it has one line more to hold —
  /// the missiles and the hammers under the chips.
  static const double premiumRise = 1.16;

  final int columns;
  final double cardW;
  final double cardH;
  final double premiumH;
}

/// The picture being worn, at the head of the Pictures shelf, between the
/// shelf's two menus: the picture, "Your picture" over its name, and the
/// check that says it is on (premium store polish, 26 Sep 2026: "Current
/// picture → 'Your picture' → Equipped/owned state → Picture catalogue ...
/// avoid making the current picture compete with the entire catalogue").
///
/// It stood above the grid as a 96dp portrait with its name under it, which
/// on a 640dp phone took 105dp of a 206dp body and left the catalogue less
/// than one row; beside its words it is a third of that height.
class _PicturesHead extends StatelessWidget {
  const _PicturesHead({
    required this.atTable,
    required this.filter,
    required this.order,
    required this.onFilter,
    required this.onOrder,
    this.rail = false,
  });

  /// At a table the shelf is the animated one, and has no filter menu.
  final bool atTable;

  /// Whether it stands in a column beside the grid — the worn picture over
  /// the two menus — rather than in a row over it: a phone's layout
  /// ([_ChipStoreState._sideControls]).
  final bool rail;
  final PictureFilter filter;
  final PictureSort order;
  final ValueChanged<PictureFilter> onFilter;
  final ValueChanged<PictureSort> onOrder;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final user = state.user;
    // The picture being worn, when it is one of the catalogue's; null leaves
    // the provider photo or the initial.
    ProfilePicture? worn;
    for (final p in state.pictures) {
      if (p.id == user?.activePictureId) {
        worn = p;
        break;
      }
    }
    final radius = (MediaQuery.sizeOf(context).height * 0.068).clamp(
      22.0,
      34.0,
    );
    final name = worn?.name ?? user?.displayName ?? '';
    final left = worn == null || worn.free
        ? null
        : rentalTagLeft(t, worn.expiresAt, DateTime.now());

    final head = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Avatar(
          url: state.avatarUrl,
          format: worn?.assetFormat,
          fallback: user?.displayName ?? '',
          radius: radius,
          ring: AppTheme.goldBright,
          ringWidth: 2,
          ringGap: 2,
          animate: true,
        ),
        const SizedBox(width: Space.md),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.yourPicture,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.label(
                  theme.textTheme.labelSmall ?? const TextStyle(),
                  colour: glass.textMuted,
                ),
              ),
              if (name.isNotEmpty)
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.label(
                    theme.textTheme.labelLarge ?? const TextStyle(),
                    colour: glass.textDisplay,
                    weight: FontWeight.w700,
                  ),
                ),
              // The check a catalogue picture is worn with; a provider photo
              // or an initial has no state to show.
              if (worn != null) ...[
                const SizedBox(height: Space.xxs),
                _WornTag(label: t.wearing, detail: left),
              ],
            ],
          ),
        ),
      ],
    );

    if (rail) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          head,
          const SizedBox(height: Space.md),
          if (!atTable) ...[
            PictureFilterMenu(
              value: filter,
              counts: {
                for (final f in PictureFilter.menu) f: shelfCount(state, f),
              },
              onChanged: onFilter,
            ),
            const SizedBox(height: Space.sm),
          ],
          PictureSortMenu(value: order, onChanged: onOrder),
        ],
      );
    }

    return Row(
      children: [
        if (!atTable)
          PictureFilterMenu(
            value: filter,
            counts: {
              for (final f in PictureFilter.menu) f: shelfCount(state, f),
            },
            onChanged: onFilter,
          ),
        const SizedBox(width: Space.md),
        Expanded(child: Center(child: head)),
        const SizedBox(width: Space.md),
        // Which way the shelf's prices run, on the right of the row (owner,
        // 14 Sep 2026).
        PictureSortMenu(value: order, onChanged: onOrder),
      ],
    );
  }
}

/// "✓ Wearing", struck in gold — the one solid gold on the shelf — with the
/// time left under it when the picture is a rental: the equipped state said
/// in a word and a glyph, never by a ring's colour alone.
class _WornTag extends StatelessWidget {
  const _WornTag({required this.label, this.detail});

  final String label;

  /// The time left on a rental ([rentalTagLeft]); null otherwise.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final type = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: AppTheme.ink900,
      fontWeight: FontWeight.w700,
      height: 1.15,
      letterSpacing: 0.3,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xs),
        color: AppTheme.gold,
        border: Border.all(color: AppTheme.goldBright.withValues(alpha: 0.9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_rounded, size: 12, color: AppTheme.ink900),
          const SizedBox(width: Space.xxs),
          Flexible(
            child: Text(
              detail == null ? label : '$label · $detail',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type,
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the store goes after a missile trade.
enum _TradeOutcome { done, toDiamonds, stay }

/// Trades diamonds for [pack], asking first (owner, 14 Sep 2026: "Trade 73
/// diamonds for 5 missiles?").
///
/// A player without the diamonds is not asked that — they are offered the
/// Diamonds shelf, which is the only answer that helps — and neither is one
/// the server finds short after all. [context] is the store's.
Future<_TradeOutcome> _tradeMissilePack(
  BuildContext context,
  MissilePack pack,
) async {
  final state = context.read<GameState>();
  if ((state.user?.diamond ?? 0) < pack.diamonds) {
    return await _offerDiamonds(context, pack)
        ? _TradeOutcome.toDiamonds
        : _TradeOutcome.stay;
  }

  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => _TradeDialog(pack: pack),
  );
  if (go != true || !context.mounted) return _TradeOutcome.stay;

  final result = await state.tradeMissiles(pack.packId);
  if (!context.mounted) return _TradeOutcome.stay;
  return switch (result) {
    MissileTradeResult.traded => _TradeOutcome.done,
    MissileTradeResult.notEnoughDiamonds =>
      await _offerDiamonds(context, pack)
          ? _TradeOutcome.toDiamonds
          : _TradeOutcome.stay,
    MissileTradeResult.refused => _TradeOutcome.stay,
  };
}

/// The title row of a store dialog: a glyph in its wallet's ink, and the
/// question.
Widget _storeDialogTitle(
  BuildContext context,
  IconData icon,
  Color ink,
  String text,
) {
  final theme = Theme.of(context);
  return Row(
    children: [
      Icon(icon, size: 20, color: ink),
      const SizedBox(width: Space.md),
      Expanded(
        child: Text(
          text,
          style: AppTheme.label(
            theme.textTheme.titleMedium ?? const TextStyle(),
          ),
        ),
      ),
    ],
  );
}

List<Widget> _storeDialogActions(
  BuildContext context, {
  required String stay,
  required String go,
}) => [
  GlassButton(
    style: GlassButtonStyle.text,
    label: stay,
    onPressed: () => Navigator.pop(context, false),
  ),
  GlassButton(
    style: GlassButtonStyle.primary,
    label: go,
    onPressed: () => Navigator.pop(context, true),
  ),
];

/// "Trade 73 diamonds for 5 missiles?", with what the player holds of both
/// under it — as figures beside their glyphs, so no word has to change with
/// the number.
class _TradeDialog extends StatelessWidget {
  const _TradeDialog({required this.pack});

  final MissilePack pack;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final quiet = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget holding(IconData icon, Color ink, int count) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: ink),
        const SizedBox(width: Space.xs),
        Text('$count', style: quiet?.copyWith(color: ink)),
      ],
    );

    return GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: _storeDialogTitle(
        context,
        missileIcon,
        missileInkOn(brightness),
        t.tradeMissilesTitle,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.tradeMissilesBody(pack.diamonds, pack.missiles)),
          const SizedBox(height: Space.md),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              holding(
                Icons.diamond_rounded,
                diamondInkOn(brightness),
                state.user?.diamond ?? 0,
              ),
              const SizedBox(width: Space.lg),
              holding(
                missileIcon,
                missileInkOn(brightness),
                state.user?.missile ?? 0,
              ),
            ],
          ),
        ],
      ),
      actions: _storeDialogActions(context, stay: t.cancel, go: t.trade),
    );
  }
}

/// The Diamonds shelf, offered to a player who cannot pay for [pack]. True
/// when they took the offer.
Future<bool> _offerDiamonds(BuildContext context, MissilePack pack) async {
  final t = context.read<GameState>().t;
  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: _storeDialogTitle(
        dialogContext,
        Icons.diamond_rounded,
        diamondInkOn(Theme.of(dialogContext).brightness),
        t.notEnoughDiamondsTitle,
      ),
      content: Text(t.notEnoughDiamondsBody(pack.diamonds)),
      actions: _storeDialogActions(
        dialogContext,
        stay: t.cancel,
        go: t.getDiamonds,
      ),
    ),
  );
  return go == true;
}

/// Slides each pack up as the shelf is set out, one stagger apart — a short
/// rise and a fade, no bounce (premium store polish, 26 Sep 2026: "very
/// subtle entrance animation"; it rose 26dp), each in [Motion.base] (the
/// brief of 27 Sep 2026: "product appearance 150-250ms"; it took 420).
class _PackEntrance extends StatefulWidget {
  const _PackEntrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_PackEntrance> createState() => _PackEntranceState();
}

class _PackEntranceState extends State<_PackEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: Motion.base);
    Future<void>.delayed(Motion.stagger * widget.index, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final e = Motion.standard.transform(_c.value);
        return Opacity(
          opacity: _c.value,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - e)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Every size on a product card, from the card's own box: the store's one
/// type and spacing scale for the cards of every shelf (premium store polish,
/// 26 Sep 2026: "Use a consistent typography scale ... Avoid unnecessary
/// font-size differences between similar cards"). The chip, diamond, hammer,
/// missile and premium cards each had their own figure, plate and price sizes.
///
/// [side] is the card's shorter side; the values beside each field are at a
/// 640dp phone's card (side 164), an 891dp phone's (200) and a tablet's (236).
@immutable
class _CardMetrics {
  const _CardMetrics._({
    required this.width,
    required this.height,
    required this.side,
    required this.pad,
    required this.badgeH,
    required this.figure,
    required this.lineFont,
    required this.ctaH,
  });

  factory _CardMetrics.of(Size box) {
    final s = math.min(box.width, box.height);
    return _CardMetrics._(
      width: box.width,
      height: box.height,
      side: s,
      // 12.3 | 14 | 14
      pad: (s * 0.075).clamp(10.0, 14.0),
      // 21.3 | 24 | 24
      badgeH: (s * 0.13).clamp(18.0, 24.0),
      // 29.5 | 30 | 30 — before a shelf fits its widest figure to the card
      figure: (s * 0.18).clamp(20.0, 30.0),
      // 11.8 | 13 | 13
      lineFont: (s * 0.072).clamp(11.0, 13.0),
      // 32.8 | 38 | 38
      ctaH: (s * 0.20).clamp(30.0, 38.0),
    );
  }

  final double width;
  final double height;
  final double side;

  /// The card's inset on every side.
  final double pad;

  /// The badge's height, and the slot kept for it on a card that has none,
  /// so the figures of a row stand level.
  final double badgeH;

  /// The figure's size when nothing on its shelf is too wide for it.
  final double figure;

  /// The secondary lines' type — the bonus, the wallet's name, the missiles
  /// and hammers a package brings.
  final double lineFont;

  /// The purchase key's height.
  final double ctaH;

  /// The width inside the card's padding.
  double get innerW => math.max(0, width - 2 * pad);

  /// Between the product's icon and its figure.
  double get iconGap => Space.sm;

  /// The badge's word.
  double get badgeFont => (badgeH * 0.48).clamp(9.5, 12.0);

  /// The price on the purchase key: its primary content.
  double get priceFont => (ctaH * 0.42).clamp(13.0, 16.0);
}

/// The chip stack beside a chip figure is three chips high: its width over
/// its height ([ChipStack] lifts each chip by 0.22 of its size).
const double _chipStackRise = 1.44;
const double _chipStackAspect = 1 / _chipStackRise;

/// A figure's style: tabular, the display face, at [size].
TextStyle _figureStyle(ThemeData theme, double size) =>
    AppTheme.money(theme.textTheme.displaySmall!, fontSize: size);

/// How tall a product icon stands beside a figure of [size]: the figure's
/// line at this text scale, so the two sit level at every scale.
double _iconHeight(TextScaler scaler, double size) => scaler.scale(size);

/// The ⭐ or 👑 beside a Premium Package's figure: its size and the gap before
/// it, as shares of the figure's.
const double _markShare = 0.8;
const double _markGap = 0.22;

/// The one size every figure on a shelf is set in, so a shelf's cards never
/// differ in size from one to the next — "12 Crore" stood larger than "5.28
/// Crore" beside it, each shrunk on its own to fit (premium store polish,
/// 26 Sep 2026).
///
/// [m]'s figure size when the widest of [figures] — each a figure and the
/// mark beside it, if any — fits the card beside its icon (an icon
/// [iconAspect] as wide as it is tall; 0 for none), and otherwise the size at
/// which it does. Measured at the phone's text scale, as the card draws it;
/// the card still shrinks a figure that comes out wider (a count-up passing
/// through a longer figure) rather than overflow.
double _fitFigures(
  BuildContext context,
  _CardMetrics m,
  Iterable<(String, String?)> figures, {
  double iconAspect = 0,
}) {
  final theme = Theme.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  double measure(String text, double size) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _figureStyle(theme, size)),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  final base = m.figure;
  var widest = 0.0;
  for (final (text, mark) in figures) {
    var width = measure(text, base);
    if (mark != null) {
      width += base * _markGap + measure(mark, base * _markShare);
    }
    widest = math.max(widest, width);
  }
  final gap = iconAspect > 0 ? m.iconGap : 0.0;
  final icon = iconAspect > 0 ? _iconHeight(scaler, base) * iconAspect : 0.0;
  final room = m.innerW - gap;
  final row = widest + icon;
  if (row <= room || row <= 0) return base;
  return math.max(1, base * room / row);
}

/// Sapphire, violet, then gold: the colour a pack's card climbs the shelf in,
/// so a shelf reads from modest to rich at a glance.
TablePalette _rise(ColorScheme scheme, int step) => switch (step) {
  >= 2 => AppTheme.paletteFor(scheme, category: 'seen', bootAmount: 200),
  1 => AppTheme.violetPalette(scheme),
  _ => AppTheme.paletteFor(scheme, category: 'blind', bootAmount: 200),
};

/// The words a pack's mark is badged with — ⭐ POPULAR, 🔥 BEST VALUE,
/// 👑 PREMIUM, STARTER — or null for a pack the owner has not marked, which
/// wears no badge. The glyph comes from [shelfMarkGlyph] on every shelf: the
/// chip packs were the one shelf whose POPULAR and BEST VALUE went without.
String? _markLabel(Strings t, ShelfMark mark) {
  final word = switch (mark) {
    ShelfMark.starter => t.posStarter,
    ShelfMark.popular => t.posPopular,
    ShelfMark.bestValue => t.posBestValue,
    ShelfMark.premium || ShelfMark.crown => t.posPremium,
    ShelfMark.none => null,
  };
  if (word == null) return null;
  final glyph = shelfMarkGlyph(mark);
  return glyph == null ? word : '$glyph $word';
}

/// How loud a badge is.
enum _BadgeTone {
  /// A mark the owner set to sell a pack — ⭐ POPULAR, 🔥 BEST VALUE, PREMIUM,
  /// the Premium Package — in its card's colour.
  feature,

  /// A badge that only informs (STARTER): outlined, in the card's quiet ink.
  quiet,
}

/// The one product card of the store: every pack on the Chips, Diamonds,
/// Hammers and Missiles shelves, and the Premium Packages, is this card with
/// its own content (premium store polish, 26 Sep 2026: "Create/reuse ONE
/// consistent product-card design system ... Badge, Product icon, Main
/// quantity/value, Secondary information, Purchase CTA"). The three cards it
/// replaced each laid the same parts out on their own sizes.
///
/// Top to bottom: the [badge] — or the space for one, so the figures of a row
/// stand level — then the [value] (the product's icon and its figure, the
/// largest thing on the card) with the [lines] of secondary information under
/// it, centred in the space between, and the purchase key along the foot.
/// Frosted glass over a baked orb of the card's colour ([palette]), as
/// before, but the orb is a quarter less of the card and lives in its top
/// right corner, beside the badge and above the figure rather than behind it,
/// and no longer spills past the card's edge as a hard crescent.
///
/// The whole card is the target, as a lobby card is: a tap anywhere buys. It
/// is pressed down to 0.97 ([PressScale]), the ink answers in the store's
/// colour, and the purchase key lights up under the finger.
class _StoreProductCard extends StatefulWidget {
  const _StoreProductCard({
    required this.palette,
    required this.ink,
    required this.value,
    required this.price,
    required this.onTap,
    this.badge,
    this.badgeTone = _BadgeTone.feature,
    this.featured = false,
    this.lines = const [],
    this.priceLeading,
    this.busy = false,
  });

  /// The card's colour where it climbs the shelf: the light behind it, and a
  /// featured badge.
  final TablePalette palette;

  /// The store's own ink — gold on the chip shelves, ice blue on the diamond
  /// one, copper on the hammer one, coral on the missile one — the purchase
  /// key's accent and its ripple.
  final Color ink;
  final String? badge;
  final _BadgeTone badgeTone;

  /// The gold hairline of a pack the owner featured (best value, premium).
  final bool featured;

  /// The icon and the figure, laid out on the card's metrics.
  final Widget Function(_CardMetrics m) value;

  /// The secondary information under the figure, one line each.
  final List<Widget Function(_CardMetrics m)> lines;

  /// The price, as Play or the shelf writes it.
  final String price;

  /// Drawn before the price: the gem on a trade priced in diamonds.
  final Widget Function(_CardMetrics m)? priceLeading;

  /// The purchase is with the server: the key spins and takes no tap.
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_StoreProductCard> createState() => _StoreProductCardState();
}

class _StoreProductCardState extends State<_StoreProductCard> {
  /// The finger is on the card: the purchase key lights up.
  bool _lit = false;

  /// The orb behind the glass, as a share of the card's shorter side (0.62
  /// before), and how much of it the glass lets through by night and by day
  /// (0.62 and 0.46, over a sharp twin behind the card at 1.0 and 0.9).
  static const double _orbShare = 0.54;
  static const double _orbNight = 0.50;
  static const double _orbDay = 0.38;

  /// In the card's top right corner, over the badge's row and above the
  /// figure, and clipped by the card's own edge.
  static Rect _orb(_CardMetrics m) => Rect.fromCenter(
    center: Offset(m.width * 0.86, m.height * 0.16),
    width: m.side * _orbShare,
    height: m.side * _orbShare,
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final busy = widget.busy;
    return PressScale(
      enabled: !busy,
      // The tap below gives the haptic, and only when the card acts.
      haptic: false,
      child: LayoutBuilder(
        builder: (context, box) {
          final m = _CardMetrics.of(box.biggest);
          final orb = _orb(m);
          return PremiumGlassPanel(
            mode: GlassMode.tinted,
            radius: Radii.lg,
            live: widget.featured,
            padding: EdgeInsets.zero,
            tint: Colors.white,
            behind: Stack(
              children: [
                Positioned.fromRect(
                  rect: orb,
                  child: GlassOrb(
                    colours: orbColours(widget.palette.accent),
                    size: orb.width,
                    soft: true,
                    opacity: dark ? _orbNight : _orbDay,
                  ),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                // Material's own click, gated on the player's Sound switch —
                // otherwise a silenced game would still tick on every tap.
                enableFeedback: soundOn(context),
                borderRadius: BorderRadius.circular(Radii.lg),
                onTap: busy
                    ? null
                    : () {
                        tapHaptic(context);
                        widget.onTap();
                      },
                onHighlightChanged: (on) {
                  if (on != _lit) setState(() => _lit = on);
                },
                splashColor: widget.ink.withValues(alpha: 0.12),
                highlightColor: widget.ink.withValues(alpha: 0.05),
                child: Padding(
                  padding: EdgeInsets.all(m.pad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: m.badgeH,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: widget.badge == null
                              ? null
                              : _StoreBadge(
                                  label: widget.badge!,
                                  palette: widget.palette,
                                  height: m.badgeH,
                                  tone: widget.badgeTone,
                                ),
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      // The figure and its lines, centred between the badge
                      // and the key. Scaled down as one only where a phone's
                      // text size and script ask more height than the card
                      // has — never cut, never overflowing.
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: SizedBox(
                              width: m.innerW,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  widget.value(m),
                                  for (final line in widget.lines) ...[
                                    const SizedBox(height: Space.xs),
                                    line(m),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      _PriceButton(
                        label: widget.price,
                        leading: widget.priceLeading?.call(m),
                        height: m.ctaH,
                        font: m.priceFont,
                        ink: widget.ink,
                        busy: busy,
                        lit: _lit,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A pack's badge, one shape on every shelf: one height, corner, padding,
/// type and edge (premium store polish, 26 Sep 2026: "Marketing badges should
/// have consistent: Height, Radius, Padding, Font size, Icon size, Border
/// treatment"). A [_BadgeTone.feature] badge is filled in its card's colour
/// and edged in its accent; a [_BadgeTone.quiet] one is only outlined, so the
/// packs the owner marked are the ones that call out.
///
/// It replaces the lobby's category plate, still, with a poker chip on it —
/// which on the diamond, hammer and missile shelves put a chip on a plate
/// that said DIAMONDS. The mark's own glyph (⭐, 🔥, 👑) is its icon now.
/// Shrunk as a whole rather than cut, so "PREMIUM PACKAGE" is never
/// "PREMIUM PACKA…".
class _StoreBadge extends StatelessWidget {
  const _StoreBadge({
    required this.label,
    required this.palette,
    required this.height,
    this.tone = _BadgeTone.feature,
  });

  final String label;
  final TablePalette palette;
  final double height;
  final _BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final feature = tone == _BadgeTone.feature;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: height * 0.40),
      decoration: BoxDecoration(
        color: feature ? palette.container : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: feature
              ? palette.accent.withValues(alpha: dark ? 0.55 : 0.45)
              : glass.cardBorder,
          width: Dim.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                // label, not smallCaps: these words are translated, and
                // tracking pulls Gujarati or Gurmukhi apart.
                style: AppTheme.label(
                  theme.textTheme.labelLarge!,
                  fontSize: (height * 0.48).clamp(9.5, 12.0),
                  colour: feature ? palette.onContainer : glass.textBody,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The purchase key along a card's foot: the price, and a disc with an arrow
/// in the store's ink — a key that reads as a key, raised off the card and
/// edged in the store's colour, where the grey glass capsule it replaced read
/// as switched off on the light theme (premium store polish, 26 Sep 2026:
/// "Strong contrast, consistent height, consistent radius, clear price, clear
/// arrow/action icon, subtle category accent, strong touch feedback" — and
/// "without turning them into oversized gold buttons").
///
/// Not a button of its own: the whole card is the target. [lit] is the finger
/// on the card, which brightens the key's wash and rim.
class _PriceButton extends StatelessWidget {
  const _PriceButton({
    required this.label,
    required this.height,
    required this.font,
    required this.ink,
    this.leading,
    this.busy = false,
    this.lit = false,
  });

  final String label;
  final double height;

  /// The price's size ([_CardMetrics.priceFont]).
  final double font;

  /// The store's ink ([_StoreProductCard.ink]).
  final Color ink;

  /// Drawn before the price: the gem on a price in diamonds.
  final Widget? leading;

  /// A spinner in place of the price, while the purchase is with the server.
  final bool busy;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final text = GlassColors.of(context).textDisplay;
    // A step lighter than the card by night and a step off white by day,
    // with a breath of the store's ink in it — the colour is the rim's and
    // the disc's — and more of it under the finger.
    final wash = lit ? 0.18 : 0.06;
    final top = dark
        ? Color.alphaBlend(
            ink.withValues(alpha: wash + 0.02),
            const Color(0xFF3B4047),
          )
        : Color.alphaBlend(ink.withValues(alpha: wash * 0.6), Colors.white);
    final bottom = dark
        ? Color.alphaBlend(ink.withValues(alpha: wash), const Color(0xFF272B30))
        : Color.alphaBlend(
            ink.withValues(alpha: wash),
            const Color(0xFFF4F5F7),
          );
    final disc = height * 0.64;
    final arrow = ThemeData.estimateBrightnessForColor(ink) == Brightness.dark
        ? Colors.white
        : AppTheme.ink900;

    return AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.standard,
      height: height,
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: height * 0.22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
        border: Border.all(
          color: ink.withValues(alpha: lit ? 0.9 : 0.55),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.shadowFor(
              theme.brightness,
            ).withValues(alpha: dark ? 0.42 : 0.14),
            offset: const Offset(0, 2),
            blurRadius: 8,
            spreadRadius: -2,
          ),
        ],
      ),
      child: busy
          ? Center(
              child: GameLoaderRing(size: height * 0.44, ink: ink),
            )
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: Space.xs),
                  ],
                  Text(
                    label,
                    maxLines: 1,
                    style: AppTheme.money(
                      theme.textTheme.titleSmall!,
                      fontSize: font,
                      colour: text,
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Container(
                    width: disc,
                    height: disc,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ink,
                    ),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: disc * 0.66,
                      color: arrow,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// A product's icon beside its figure, level with it; the figure shrinks
/// rather than wraps or ellipsises where the card is narrower than a
/// shelf-wide size allowed for.
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.figure, this.icon, this.gap = Space.sm});

  final Widget? icon;
  final Widget figure;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (icon != null) ...[icon!, SizedBox(width: gap)],
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: figure,
        ),
      ),
    ],
  );
}

/// One line of secondary information: a glyph, what it is, and — pushed to
/// the line's end — what it is set to, in the lobby card's fact layout. The
/// value takes [ink] where it is the reason to buy (a chip pack's bonus).
class _FactLine extends StatelessWidget {
  const _FactLine({
    required this.metrics,
    required this.icon,
    required this.label,
    required this.value,
    this.ink,
  });

  final _CardMetrics metrics;
  final IconData icon;
  final String label;
  final String value;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final glass = GlassColors.of(context);
    final size = metrics.lineFont;
    return Row(
      children: [
        Icon(
          icon,
          size: MediaQuery.textScalerOf(context).scale(size) * 1.15,
          color: glass.textMuted,
        ),
        const SizedBox(width: Space.xs),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(
              fontSize: size,
              color: glass.textBody,
            ),
          ),
        ),
        const SizedBox(width: Space.xs),
        Text(
          value,
          maxLines: 1,
          style: AppTheme.money(
            text.labelLarge!,
            fontSize: size,
            colour: ink ?? glass.textDisplay,
          ),
        ),
      ],
    );
  }
}

/// One more thing a card brings besides its figure — "+1 Missile", "+10
/// Hammers" — beside the glyph the table's wallet pill marks that wallet
/// with, in the wallet's own ink; or, with no [icon], a wallet's name under
/// its count in the card's body ink. Shrunk rather than cut: the line is a
/// count, and at the 1.25 text ceiling in Punjabi it is still one line.
class _CardLine extends StatelessWidget {
  const _CardLine({
    required this.metrics,
    required this.label,
    this.icon,
    this.ink,
  });

  final _CardMetrics metrics;
  final String label;
  final IconData? icon;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final glass = GlassColors.of(context);
    final size = metrics.lineFont;
    final words = Text(
      label,
      maxLines: 1,
      style: icon == null
          ? text.bodySmall?.copyWith(fontSize: size, color: glass.textBody)
          : AppTheme.money(
              text.labelLarge!,
              fontSize: size,
              colour: ink ?? glass.textDisplay,
            ),
    );
    return Row(
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: MediaQuery.textScalerOf(context).scale(size) * 1.15,
            color: ink,
          ),
          const SizedBox(width: Space.xs),
        ],
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: words,
          ),
        ),
      ],
    );
  }
}

/// Buys [productId] through Play, or says plainly that it cannot: Play is the
/// only thing that can take money, and it is not always there — an emulator
/// without Play Services, a side-loaded build, a device signed out of Play.
/// The store closes either way. The result arrives on the purchase stream,
/// not from this call (net/purchases.dart): a purchase that completes minutes
/// later is still credited and still celebrated.
void _buyFromPlay(
  BuildContext context,
  String productId,
  Map<String, ProductDetails> prices,
) {
  final state = context.read<GameState>();
  final details = prices[productId];
  if (!state.purchases.available || details == null) {
    state.notice = state.t.storeNotLive;
    Navigator.pop(context);
    return;
  }
  state.purchases.buy(details);
  Navigator.pop(context);
}

/// One chip pack: the chip stack and the figure, the pack's bonus under it,
/// and its price.
///
/// Chips are rendered through [formatChips], never as a baked-in string, so
/// a player on international numbering reads Million and Billion here as at
/// the table. Only a pack the owner marked wears a badge; the others said
/// their bonus twice, on a plate and on the line under the figure.
class _PackCard extends StatelessWidget {
  const _PackCard({
    required this.pack,
    required this.index,
    required this.prices,
    required this.figure,
  });

  final ChipPack pack;

  /// Where the pack sits in the range, which decides its colour.
  final int index;

  /// What Play says these cost, keyed by product id. Empty when Play is
  /// unavailable or has not answered yet, and then the card falls back to the
  /// list price — an approximate figure beats an empty shelf, and the real one
  /// is always shown on Play's own sheet before anyone is charged.
  final Map<String, ProductDetails> prices;

  /// The size every chip figure on the shelf is set in ([_fitFigures]).
  final double figure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;
    final p = pack;
    final palette = _rise(
      theme.colorScheme,
      index >= 6
          ? 2
          : index >= 3
          ? 1
          : 0,
    );
    final gold = AppTheme.goldInk(theme.brightness);
    final stack = _iconHeight(MediaQuery.textScalerOf(context), figure);

    return _StoreProductCard(
      palette: palette,
      ink: gold,
      badge: _markLabel(t, p.mark),
      badgeTone: p.mark == ShelfMark.starter
          ? _BadgeTone.quiet
          : _BadgeTone.feature,
      featured: p.featured,
      value: (m) => _ValueRow(
        gap: m.iconGap,
        icon: ChipStack(
          size: stack / _chipStackRise,
          colours: [
            palette.accent,
            Color.lerp(palette.accent, AppTheme.ink900, 0.35)!,
            palette.accent,
          ],
        ),
        figure: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: p.chips.toDouble()),
            duration: const Duration(milliseconds: 700),
            curve: Motion.standard,
            builder: (context, value, _) => Text(
              formatChips(value.round()),
              maxLines: 1,
              style: _figureStyle(theme, figure).copyWith(color: gold),
            ),
          ),
        ),
      ),
      lines: [
        (m) => _FactLine(
          metrics: m,
          icon: Icons.redeem_rounded,
          label: t.storeBonus,
          value: p.bonusPercent == 0 ? '—' : '${p.bonusPercent}%',
          ink: p.bonusPercent > 0 ? palette.ink : null,
        ),
      ],
      price: prices[p.productId]?.price ?? '₹${_grouped(p.rupees)}',
      onTap: () => _buyFromPlay(context, p.productId, prices),
    );
  }
}

/// The heading over the Premium Packages on the Chips shelf: the crowned
/// badge and the words, in champagne, and a hairline running on to the
/// shelf's edge that closes the chip packs off above it.
class _PremiumHeading extends StatelessWidget {
  const _PremiumHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final champagne = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;
    return Semantics(
      header: true,
      child: Row(
        children: [
          Icon(Icons.workspace_premium_rounded, size: 20, color: champagne),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(
                theme.textTheme.titleMedium ?? const TextStyle(),
                colour: champagne,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Container(
              height: Dim.hairline,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.hairlineColour(theme.brightness, live: true),
                    AppTheme.hairlineColour(
                      theme.brightness,
                    ).withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One Premium Package (owner, 14 Sep 2026): chips, missiles and hammers in
/// one Play purchase, sold on the Chips shelf under its own heading.
///
/// The store's product card with what a package holds: the badge reads
/// "Premium Package" on every one, the figure carries ⭐ or 👑 beside it on
/// the two the owner marked, two lines under it name the missiles and hammers
/// that come with the chips — each beside the glyph the table's wallet pill
/// marks that wallet with — and the card is gold with a live hairline, the top
/// of the range the chip shelf climbs to. Like [ChipPack], every figure is for
/// display only: the server's `purchase.Catalogue` decides what a product id
/// is worth and credits all three wallets from one receipt.
class _PremiumPackCard extends StatelessWidget {
  const _PremiumPackCard({
    required this.pack,
    required this.prices,
    required this.figure,
  });

  final PremiumPack pack;

  /// Play's prices by product id; empty until Play answers, when the card
  /// falls back to the list price, as a chip pack does.
  final Map<String, ProductDetails> prices;

  /// The size every package's figure is set in ([_fitFigures]).
  final double figure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final t = context.read<GameState>().t;
    final p = pack;
    final gold = AppTheme.goldInk(brightness);
    final glyph = shelfMarkGlyph(p.mark);

    return _StoreProductCard(
      // The top of the range, where the chip shelf's colour ends: gold.
      palette: _rise(theme.colorScheme, 2),
      ink: gold,
      badge: t.posPremiumPackage,
      featured: true,
      value: (m) => _ValueRow(
        figure: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: p.chips.toDouble()),
            duration: const Duration(milliseconds: 700),
            curve: Motion.standard,
            builder: (context, value, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatChips(value.round()),
                  maxLines: 1,
                  style: _figureStyle(theme, figure).copyWith(color: gold),
                ),
                if (glyph != null) ...[
                  SizedBox(width: figure * _markGap),
                  Text(
                    glyph,
                    maxLines: 1,
                    style: TextStyle(fontSize: figure * _markShare, height: 1),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      lines: [
        (m) => _CardLine(
          metrics: m,
          icon: missileIcon,
          ink: missileInkOn(brightness),
          label: t.plusMissiles(p.missiles),
        ),
        (m) => _CardLine(
          metrics: m,
          icon: Icons.hardware,
          ink: hammerInkOn(brightness),
          label: t.plusHammers(p.hammers),
        ),
      ],
      price: prices[p.productId]?.price ?? '₹${_grouped(p.rupees)}',
      onTap: () => _buyFromPlay(context, p.productId, prices),
    );
  }
}

/// "1,499" — the Indian grouping for a rupee figure, which is a price and so
/// never abbreviated the way a chip balance is.
String _grouped(int n) {
  final s = n.toString();
  if (s.length <= 3) return s;
  final head = s.substring(0, s.length - 3);
  final tail = s.substring(s.length - 3);
  final buf = StringBuffer();
  for (var i = 0; i < head.length; i++) {
    if (i > 0 && (head.length - i) % 2 == 0) buf.write(',');
    buf.write(head[i]);
  }
  return '$buf,$tail';
}

/// One diamond, hammer or missile pack: the store's product card with the
/// wallet's own glyph beside the count, both in the wallet's own ink, the
/// wallet's name under it, and the price along the foot — so the three
/// shelves differ in nothing but the glyph, the ink and the word, and each
/// keeps its own colour (ice blue, copper, coral) apart from the chips' gold.
/// The card's light climbs the shelf the way it climbs the chip packs —
/// sapphire, sapphire, violet, gold — so the shelves read as one store.
class _CountPackCard extends StatelessWidget {
  const _CountPackCard({
    required this.productId,
    required this.rupees,
    required this.count,
    required this.mark,
    required this.icon,
    required this.inkOn,
    required this.unit,
    required this.index,
    required this.prices,
    required this.figure,
    this.diamondCost,
    this.onTrade,
  });

  _CountPackCard.diamonds(
    DiamondPack pack, {
    required int index,
    required Map<String, ProductDetails> prices,
    required double figure,
  }) : this(
         productId: pack.productId,
         rupees: pack.rupees,
         count: pack.diamonds,
         mark: pack.mark,
         icon: Icons.diamond_rounded,
         inkOn: diamondInkOn,
         unit: _diamondsWord,
         index: index,
         prices: prices,
         figure: figure,
       );

  _CountPackCard.hammers(
    HammerPack pack, {
    required int index,
    required Map<String, ProductDetails> prices,
    required double figure,
  }) : this(
         productId: pack.productId,
         rupees: pack.rupees,
         count: pack.hammers,
         mark: pack.mark,
         icon: Icons.hardware,
         inkOn: hammerInkOn,
         unit: _hammersWord,
         index: index,
         prices: prices,
         figure: figure,
       );

  /// A missile trade: priced in diamonds rather than rupees, and tapped
  /// through [onTrade] rather than Play.
  _CountPackCard.missiles(
    MissilePack pack, {
    required int index,
    required VoidCallback onTrade,
    required double figure,
  }) : this(
         productId: pack.packId,
         rupees: 0,
         count: pack.missiles,
         mark: pack.mark,
         icon: missileIcon,
         inkOn: missileInkOn,
         unit: _missilesWord,
         index: index,
         prices: const {},
         figure: figure,
         diamondCost: pack.diamonds,
         onTrade: onTrade,
       );

  /// The Play Console product id, which is also the key into [prices].
  final String productId;

  /// The list price, shown until Play answers with its own.
  final int rupees;
  final int count;
  final ShelfMark mark;

  /// The wallet's glyph beside the figure.
  final IconData icon;

  /// The wallet's ink on the store's glass, by brightness.
  final Color Function(Brightness) inkOn;

  /// The wallet's name in the player's language, under the figure, given the
  /// card's [count] so a single missile is not "1 Missiles".
  final String Function(Strings t, int count) unit;
  final int index;

  /// Play's prices by product id; empty until Play answers, when the card
  /// falls back to the list price.
  final Map<String, ProductDetails> prices;

  /// The size every count on the shelf is set in ([_fitFigures]).
  final double figure;

  /// What a missile trade costs in diamonds, which the key shows in place of
  /// a price; null for a pack Play sells.
  final int? diamondCost;

  /// Called instead of Play when the card is tapped: a missile trade.
  final VoidCallback? onTrade;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<GameState>();
    final t = state.t;
    // Sapphire, sapphire, violet, gold (see _PackCard).
    final palette = _rise(
      theme.colorScheme,
      index >= 3
          ? 2
          : index >= 2
          ? 1
          : 0,
    );
    final ink = inkOn(theme.brightness);
    final cost = diamondCost;
    // This card's trade is with the server: its key spins and it takes no
    // second tap until the answer is in.
    final busy = cost != null && state.tradingMissiles == productId;
    final glyph = _iconHeight(MediaQuery.textScalerOf(context), figure);

    return _StoreProductCard(
      palette: palette,
      ink: ink,
      badge: _markLabel(t, mark),
      featured: mark == ShelfMark.bestValue,
      value: (m) => _ValueRow(
        gap: m.iconGap,
        icon: Icon(icon, size: glyph, color: ink),
        figure: Text(
          '$count',
          maxLines: 1,
          style: _figureStyle(theme, figure).copyWith(color: ink),
        ),
      ),
      lines: [(m) => _CardLine(metrics: m, label: unit(t, count))],
      // A trade is priced in diamonds: a gem and the count, never a rupee
      // sign.
      price: cost != null
          ? '$cost'
          : prices[productId]?.price ?? '₹${_grouped(rupees)}',
      priceLeading: cost == null
          ? null
          : (m) => Icon(
              Icons.diamond_rounded,
              size: MediaQuery.textScalerOf(context).scale(m.priceFont),
              color: diamondInkOn(theme.brightness),
            ),
      busy: busy,
      onTap: onTrade ?? () => _buyFromPlay(context, productId, prices),
    );
  }
}

String _diamondsWord(Strings t, int count) => t.storeTabDiamonds;
String _hammersWord(Strings t, int count) => t.storeTabHammers;
String _missilesWord(Strings t, int count) =>
    count == 1 ? t.missile : t.storeTabMissiles;

/// One badge on the Badges shelf (owner, 27 Sep 2026: "Add a icon in Store to
/// buy badges, and for all type of royal badges Add a button to contact
/// support in store"; "for badges use this entry … Add this in UI store and
/// with their lottie animation"; "for all badges i have given u price 499,
/// 999, 1799, these should be shown in button not the text contact
/// support"): the store's product card — the badge's art playing beside its
/// name, its rate ("0% winning tax") and how long it lasts under them, and
/// its PRICE on the key; where the player holds it, an Owned badge and how
/// long theirs has left. A badge Play sells ([LadderBadge.buyable]) is bought
/// through Play at Play's price; the key of every other — every Royal badge,
/// as seeded — asks for it through support ([showBadgeSupport]).
class _BadgeCard extends StatelessWidget {
  const _BadgeCard({
    super.key,
    required this.badge,
    required this.index,
    required this.prices,
    required this.figure,
  });

  final LadderBadge badge;
  final int index;
  final Map<String, ProductDetails> prices;
  final double figure;

  /// What the card's key says: the price — Play's, where Play sells the
  /// badge and has answered, else the rupees (always INR); for a badge with
  /// no price, the support it is asked for through.
  static String priceOf(
    Strings t,
    LadderBadge badge,
    Map<String, ProductDetails> prices,
  ) {
    final play = badge.buyable ? prices[badge.productId]?.price : null;
    if (play != null) return play;
    final rupees = badge.priceInr;
    return rupees == null ? t.badgeContactSupport : '₹${_grouped(rupees)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    final buyable = badge.buyable;
    // The house's gold for a royal badge; violet for one Play sells.
    final palette = _rise(theme.colorScheme, buyable ? 1 : 2);
    final ink = AppTheme.goldInk(theme.brightness);
    PlayerBadge? held;
    for (final b in state.user?.badges ?? const <PlayerBadge>[]) {
      if (b.code == badge.code) held = b;
    }
    final left = held?.leftAt(DateTime.now());
    // The art stands as tall as a figure and a line together, so the Lottie
    // reads as the card's picture rather than a bullet.
    final art = MediaQuery.textScalerOf(context).scale(figure) * 1.9;
    return _StoreProductCard(
      palette: palette,
      ink: ink,
      badge: held == null ? null : '✓ ${t.pictureOwned}',
      featured: !buyable,
      value: (m) => Row(
        children: [
          BadgeArt.of(badge, size: art),
          SizedBox(width: m.iconGap),
          Flexible(
            child: Text(
              badge.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: ink,
                height: 1.15,
              ),
            ),
          ),
        ],
      ),
      lines: [
        (m) => _CardLine(
          metrics: m,
          label: t.badgeTaxLine(formatTaxRate(badge.taxBps ?? 0)),
          icon: winningTaxIcon,
          ink: TableInk.taxOn(theme.brightness),
        ),
        (m) => _CardLine(
          metrics: m,
          label: switch (left) {
            final left? => badgeLeftOf(
              t,
              left,
              DateTime.fromMillisecondsSinceEpoch(held!.expiresAt),
            ),
            null when badge.validityDays > 0 => t.badgeLasts(
              badge.validityDays,
            ),
            null => t.badgeLifetime,
          },
          icon: Icons.schedule_rounded,
        ),
      ],
      price: priceOf(t, badge, prices),
      onTap: buyable
          ? () => _buyFromPlay(context, badge.productId, prices)
          : () => showBadgeSupport(context, badge),
    );
  }
}

/// A badge the store does not sell through Play — given by the team —
/// asked for through support: a popup naming the badge and the support
/// address, which the player may copy, and a key that opens their mail app
/// on a message to it. A phone with no mail app to open copies the address
/// instead and says so.
Future<void> showBadgeSupport(BuildContext context, LadderBadge badge) {
  final state = context.read<GameState>();
  final t = state.t;
  final name = levelTitle(badge.icon, badge.title);
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final body = theme.textTheme.bodyMedium ?? const TextStyle();
      return AlertDialog(
        key: const ValueKey('badge-support'),
        title: Text(t.badgeContactTitle(name)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // What it costs and how long it lasts, as its card says.
            Text(
              [
                if (badge.priceInr case final rupees?) '₹${_grouped(rupees)}',
                if (badge.validityDays > 0) t.badgeLasts(badge.validityDays),
              ].join(' · '),
              key: const ValueKey('badge-support-terms'),
              style: body.copyWith(
                fontWeight: FontWeight.w700,
                color: AppTheme.goldInk(theme.brightness),
              ),
            ),
            const SizedBox(height: Space.sm),
            Text(
              t.badgeContactBody(name),
              style: body.copyWith(
                color: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
              ),
            ),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                Icon(
                  Icons.mail_outline_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: Space.sm),
                Flexible(
                  child: SelectableText(
                    ServerConfig.supportEmail,
                    style: body.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('badge-support-copy'),
            onPressed: () async {
              await Clipboard.setData(
                const ClipboardData(text: ServerConfig.supportEmail),
              );
              state.say(t.addressCopied);
            },
            child: Text(t.copyAddress),
          ),
          FilledButton(
            key: const ValueKey('badge-support-mail'),
            onPressed: () async {
              final navigator = Navigator.of(context);
              final uri = Uri.parse(
                'mailto:${ServerConfig.supportEmail}'
                '?subject=${Uri.encodeComponent(t.badgeMailSubject(badge.title))}',
              );
              var opened = false;
              try {
                opened = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
              } catch (_) {
                opened = false;
              }
              if (!opened) {
                await Clipboard.setData(
                  const ClipboardData(text: ServerConfig.supportEmail),
                );
                state.say(t.addressCopied);
              }
              navigator.pop();
            },
            child: Text(t.badgeContactSupport),
          ),
        ],
      );
    },
  );
}
