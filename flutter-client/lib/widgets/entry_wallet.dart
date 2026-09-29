import 'package:flutter/material.dart';

import 'fact_mark.dart';

/// The owner's wallet (29 Sep 2026: "The Entry icon on table card use this
/// animation"): a blue wallet, its back a gradient and its front a frosted
/// pane with a clasp, fanning open and shut twice a loop — the front tilting
/// back 30°, the back forward 22°, about their foot — two seconds a loop.
/// 1080 units square, 60 fps; no 3D, no expressions, no images — a phone
/// plays it as the file has it (CLAUDE.md §12.3).
///
/// The back's blue runs from #7FC0FB to #4088F4, whose deep end stands 4.4:1
/// on the night card and 3.5:1 on the day card, so the wallet's outline and
/// its clasp read on either; the frosted front is a lighter blue by design,
/// lightest by day. On a card it is drawn in that card's colour at the same
/// luminances ([FactMark.tint]), so those figures hold in gold and violet
/// too.
const String entryWalletAsset = 'assets/animations/Wallet.json';

/// Where the wallet sits in its file: at rest it spans 271–891 across and
/// 306–884 down, and its 620-unit width fills the icon's box. Fanned open it
/// reaches 114 across and 978 down — a quarter of the box past its left edge
/// and an eighth past its foot, in the card's margin and the gap under the
/// row.
const FactMarkArt entryWalletArt = FactMarkArt(
  asset: entryWalletAsset,
  canvas: 1080,
  centre: Offset(581, 595),
  extent: 620,
  fallback: Icons.account_balance_wallet_rounded,
  gradient: entryWalletGradient,
);

/// The file's one gradient, on its back, its clasp and the frosted front's
/// glow: #7FC0FB, #5FA4F7, #4088F4.
const List<Color> entryWalletGradient = [
  Color.from(alpha: 1, red: .498, green: .753, blue: .984),
  Color.from(alpha: 1, red: .375, green: .643, blue: .971),
  Color.from(alpha: 1, red: .251, green: .533, blue: .957),
];

/// The Entry row's wallet on a lobby table card, [size] across — the box
/// the fact row's icon had ([FactMark]).
///
/// [still] — a table the player cannot sit at, drawn faded under its padlock
/// — stands the wallet on its first frame, closed; the card's own fade is
/// all the quiet it needs.
class EntryWallet extends StatelessWidget {
  const EntryWallet({
    super.key,
    required this.size,
    required this.fallbackInk,
    this.tint,
    this.still = false,
  });

  final double size;

  /// The colour of the icon drawn instead if the file cannot be read.
  final Color fallbackInk;

  /// The card's colour, laid over the file's ([FactMark.tint]); none for the
  /// file's own.
  final Color? tint;

  final bool still;

  @override
  Widget build(BuildContext context) => FactMark(
    art: entryWalletArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('entry-wallet'),
    tint: tint,
    animate: !still,
  );
}
