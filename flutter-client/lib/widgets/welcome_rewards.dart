import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../screens/reward_programs_screen.dart'
    show rewardPrizeIcon, rewardPrizeInk, rewardPrizeLabel;
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/depth.dart';
import '../theme/theme_colors.dart';
import 'glass_components.dart';
import 'premium_surface.dart' show GlassMode;

// The welcome rewards popup (owner, 30 Sep 2026: "WHen user login with new
// account it should show first consent pop up "before you play", then after
// show pop up Welcome Rewards which user must select confirm otherwise not
// able to proceed then Weekly Login pop up").
//
// A NEW account's sign-in is met by three things in a fixed order: the
// no-winnings statement (main.dart's consent gate), then this — what the
// server's welcome grant put in the account, which the player must confirm —
// and only then the weekly login popup (GameState.confirmWelcome →
// offerWeeklyLogin). It took the place of the sign-in's welcome toast, which
// said the same in one line and went by itself.
//
// The consent panel's shape and rule: a layer in the root Stack, not a
// route, so a tap outside does nothing, Back offers to quit as it does under
// the statement (never past this), and the one way on is Confirm. Shown
// while GameState.welcomePending stands and the statement is answered.

/// The popup: the account's welcome rewards, one row each, over a Confirm
/// key. Drawn from [GameState.welcomePending].
class WelcomeRewardsPanel extends StatelessWidget {
  const WelcomeRewardsPanel({super.key});

  /// The narrowest card that lays its wallet rows two to a line: half of
  /// it, less the gap, holds "5 Lakh chips" and "10 hammers" whole at text
  /// x1.25 in every language.
  static const double twoUpFrom = 300;

  /// The grant as rows, in the order the toast named them: each wallet given
  /// (chips, diamonds, hammers, missiles), then each picture, table picture
  /// and emoji by name. A wallet given nothing has no row.
  static List<RewardPrize> prizesOf(WelcomeGrant g) => [
    if (g.chips > 0) RewardPrize(kind: RewardKind.chips, value: g.chips),
    if (g.diamonds > 0)
      RewardPrize(kind: RewardKind.diamond, value: g.diamonds),
    if (g.hammers > 0) RewardPrize(kind: RewardKind.hammer, value: g.hammers),
    if (g.missiles > 0)
      RewardPrize(kind: RewardKind.missile, value: g.missiles),
    for (final p in g.pictures)
      RewardPrize(
        kind: RewardKind.profilePicture,
        refId: '${p.id}',
        picture: p,
      ),
    for (final p in g.tablePictures)
      RewardPrize(
        kind: RewardKind.tablePicture,
        refId: '${p.id}',
        tablePicture: p,
      ),
    for (final e in g.emojis)
      RewardPrize(kind: RewardKind.emoji, refId: '${e.id}', emoji: e),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final glass = GlassColors.of(context);
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final grant = context.select<GameState, WelcomeGrant?>(
      (s) => s.welcomePending,
    );
    final t = Strings(lang);
    final width = MediaQuery.sizeOf(context).width;
    final prizes = grant == null ? const <RewardPrize>[] : prizesOf(grant);
    // What a screen reader hears for the list: the grant in one line.
    final summary = welcomeNotice(t, grant) ?? t.welcomePlain;

    return Stack(
      fit: StackFit.expand,
      children: [
        // A tint, not a blur: the card takes the one blur lease itself, and
        // the lobby's drifting chips behind it would re-blur every frame.
        ColoredBox(
          key: const ValueKey('welcome-rewards-scrim'),
          color: AppTheme.ground(b).withValues(alpha: 0.72),
        ),
        Center(
          // Scrolls: eight rows in Bengali at the 1.25 text-scale ceiling on
          // a 360dp-tall phone is exactly the panel that must not overflow.
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.xl,
              vertical: Space.lg,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Dim.dialogW(width)),
              // The Material stays: this layer lives in the root Stack with
              // no Scaffold above it, and the card itself supplies none.
              child: Material(
                type: MaterialType.transparency,
                child: GlassCard(
                  key: const ValueKey('welcome-rewards-panel'),
                  mode: GlassMode.auto,
                  priority: 20,
                  depth: Elevation.overlay,
                  radius: Radii.lg,
                  padding: const EdgeInsets.all(Space.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.card_giftcard_rounded,
                            size: 22,
                            color: AppTheme.goldInk(b),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Text(
                              t.welcomeRewardsTitle,
                              key: const ValueKey('welcome-rewards-title'),
                              style: AppTheme.label(
                                text.titleMedium ?? const TextStyle(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      Semantics(
                        container: true,
                        excludeSemantics: true,
                        label: summary,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // The lead in full ink: it is what the key below
                            // confirms. A grant of nothing is a plain welcome.
                            Text(
                              prizes.isEmpty
                                  ? t.welcomePlain
                                  : t.welcomeRewardsLead,
                              key: const ValueKey('welcome-rewards-lead'),
                              style: text.bodyMedium?.copyWith(
                                color: glass.textDisplay,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (prizes.isNotEmpty)
                              const SizedBox(height: Space.sm),
                            // The wallet rows two to a line where the card
                            // is wide enough and there are more than three
                            // rows: a full grant is eight, and one under
                            // another on a 360dp-tall phone the key would be
                            // a scroll away. An item's row keeps the whole
                            // width: "Circle Background Pattern table
                            // picture" is cut in half a card at text x1.25.
                            LayoutBuilder(
                              builder: (context, box) {
                                final inner = box.maxWidth;
                                final twoUp =
                                    prizes.length > 3 &&
                                    inner >= WelcomeRewardsPanel.twoUpFrom;
                                final half = (inner - Space.md) / 2;
                                return Wrap(
                                  spacing: Space.md,
                                  children: [
                                    for (var i = 0; i < prizes.length; i++)
                                      SizedBox(
                                        width: twoUp && prizes[i].isWallet
                                            ? half
                                            : inner,
                                        child: _PrizeRow(
                                          key: ValueKey(
                                            'welcome-rewards-item-$i',
                                          ),
                                          label: rewardPrizeLabel(t, prizes[i]),
                                          icon: rewardPrizeIcon(prizes[i]),
                                          ink: rewardPrizeInk(prizes[i], b),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: Space.xl),
                      GlassButton(
                        key: const ValueKey('welcome-rewards-confirm'),
                        style: GlassButtonStyle.primary,
                        expand: true,
                        minimumSize: const Size.fromHeight(52),
                        icon: const Icon(Icons.check_rounded),
                        label: t.welcomeConfirm,
                        onPressed: () =>
                            context.read<GameState>().confirmWelcome(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One reward: its mark in its wallet's ink beside its name — the reward
/// celebration's row.
class _PrizeRow extends StatelessWidget {
  const _PrizeRow({
    super.key,
    required this.label,
    required this.icon,
    required this.ink,
  });

  final String label;
  final IconData icon;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxs),
      child: Row(
        children: [
          Icon(icon, size: 20, color: ink),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              label,
              // Never cut: a long picture name takes a second line.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.money(text.titleSmall!, colour: ink),
            ),
          ),
        ],
      ),
    );
  }
}
