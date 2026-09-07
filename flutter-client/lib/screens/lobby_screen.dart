import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../widgets/avatar.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/rules_sheet.dart';

/// The lobby: every choice is a card on one horizontal rail, so a phone held in
/// landscape never has to scroll down — swipe sideways instead.
/// Which panel the right-hand drawer is currently showing. A Scaffold has only
/// one end drawer, and both of these belong on that side.
enum _EndPanel { stats, settings }

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  _EndPanel _panel = _EndPanel.stats;

  void _open(BuildContext context, _EndPanel panel) {
    setState(() => _panel = panel);
    Scaffold.of(context).openEndDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final user = state.user;
    // The rail is rebuilt whenever the server changes what it offers, so the
    // entrance animation is keyed off the card's place in the row.
    var slot = 0;
    Widget entering(Widget child) => _Entrance(index: slot++, child: child);

    return Scaffold(
      endDrawer: _panel == _EndPanel.stats
          ? const _StatsDrawer()
          : const _SettingsDrawer(),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _TopBar(user: user, onOpen: _open),
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                    children: [
                      for (final category in state.config.categories)
                        for (final boot in state.config.stakes)
                          entering(_TableCard(category: category, boot: boot)),
                      entering(const _PrivateCard()),
                    ],
                  ),
                ),
              ],
            ),
            // Requirements 26 and 27: the two rewards sit in opposite corners of
            // the screen, so they are always reachable without hunting.
            const Positioned(top: 6, left: 12, child: _BonusChip()),
            const Positioned(bottom: 12, right: 12, child: _MilestoneChip()),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.user, required this.onOpen});

  final User? user;
  final void Function(BuildContext, _EndPanel) onOpen;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(240, 8, 12, 4),
      child: Row(
        children: [
          Tooltip(
            message: 'Change your picture',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _openPicturePicker(context),
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Avatar(
                    url: state.avatarUrl,
                    fallback: user?.displayName ?? '',
                    radius: 20,
                  ),
                  CircleAvatar(
                    radius: 8,
                    backgroundColor: theme.colorScheme.primary,
                    child: Icon(Icons.edit,
                        size: 10, color: theme.colorScheme.onPrimary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(user?.displayName ?? '',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          if (user != null)
            Chip(
              label: Text(user!.provider.toUpperCase()),
              visualDensity: VisualDensity.compact,
              labelStyle: theme.textTheme.labelSmall,
              padding: EdgeInsets.zero,
            ),
          const Spacer(),
          PokerChip(colour: theme.colorScheme.secondary, size: 20),
          const SizedBox(width: 8),
          // The balance counts to its new value rather than snapping, so a
          // reward landing is something you see happen.
          TweenAnimationBuilder<double>(
            tween: Tween(end: (user?.chips ?? 0).toDouble()),
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => Text(
              formatChips(value.round()),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.secondary,
              ),
            ),
          ),
          IconButton(
            tooltip: state.t.yourRecord,
            onPressed: () => onOpen(context, _EndPanel.stats),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: state.t.settings,
            onPressed: () => onOpen(context, _EndPanel.settings),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: state.t.signOut,
            onPressed: state.signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
    );
  }
}

/// A rail card. Everything on the rail shares this shell so the row reads as
/// one set of choices.
class _Rail extends StatelessWidget {
  const _Rail({required this.child, this.width = 300});

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: SizedBox(
        width: width,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: const EdgeInsets.all(20), child: child),
        ),
      ),
    );
  }
}

/// One boot table. Requirement 28: square, and lit by a sweep that runs corner
/// to corner without stopping — the one piece of motion in the lobby.
class _TableCard extends StatelessWidget {
  const _TableCard({required this.category, required this.boot});

  final String category;
  final int boot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final state = context.watch<GameState>();
    final t = state.t;
    final blind = category == TableCategory.blind;
    final accent = blind ? scheme.tertiary : scheme.secondary;

    // Requirement 30: the cheapest blind table is for smaller stacks. The card
    // says so and refuses the tap, rather than letting the player find out from
    // the server after they have tried.
    final capped = state.cappedOut(boot, category);

    final card = Padding(
      padding: const EdgeInsets.only(right: 16),
      child: AspectRatio(
        aspectRatio: 1,
        child: _Pressable(
          onTap: capped
              ? () {}
              : () => context.read<GameState>().quickJoin(boot, category),
          child: PremiumSurface(
            accent: capped ? scheme.outlineVariant : accent,
            glint: !capped,
            child: Builder(
              builder: (context) {
              return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(10, 7, 16, 7),
                        decoration: BoxDecoration(
                          color: blind
                              ? scheme.tertiaryContainer
                              : scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PokerChip(colour: accent, size: 22),
                            const SizedBox(width: 8),
                            Text(
                              blind ? t.blind : t.seen,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: blind
                                    ? scheme.onTertiaryContainer
                                    : scheme.onSecondaryContainer,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Counts up on first paint, so the stake lands rather
                      // than simply being there.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          ChipStack(
                            size: 26,
                            colours: [
                              scheme.primary,
                              accent,
                              scheme.tertiary,
                            ],
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(end: boot.toDouble()),
                              duration: const Duration(milliseconds: 700),
                              curve: Curves.easeOutCubic,
                              builder: (context, value, _) => FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  formatChips(value.round()),
                                  style: theme.textTheme.displaySmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color:
                                        dark ? scheme.primary : scheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(t.boot,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 14),
                      Text(
                        blind ? t.onlyYourChips : t.everyoneChips,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurface),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Text(
                            t.tapToSit,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_forward,
                              size: 18, color: scheme.primary),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    if (!capped) return card;

    // Faded back and captioned. Translucent rather than opaque, so the stake is
    // still readable — a player should be able to see the table they are being
    // kept out of.
    return Stack(
      children: [
        Opacity(opacity: 0.42, child: card),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 18),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: scheme.error.withValues(alpha: 0.5), width: 1.5),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.block, color: scheme.error, size: 22),
                    const SizedBox(height: 6),
                    Text(
                      t.cappedTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: scheme.error,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.cappedBody.replaceFirst(
                        '{cap}',
                        formatChips(state.config.entryCapMaxChips),
                      ),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PrivateCard extends StatefulWidget {
  const _PrivateCard();

  @override
  State<_PrivateCard> createState() => _PrivateCardState();
}

class _PrivateCardState extends State<_PrivateCard> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final cap = state.config.privateMaxPot;

    return _Rail(
      width: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.lock_outline, size: 20),
            const SizedBox(width: 8),
            Text(state.t.privateTable, style: theme.textTheme.titleLarge),
          ]),
          const SizedBox(height: 8),
          Text(
            'Boot ${formatChips(state.config.privateBoot)}'
            '${cap > 0 ? ', max win ${formatChips(cap)}' : ''}.'
            ' Share the code to fill the seats.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: state.createPrivate,
            child: Text(state.t.create),
          ),
          const SizedBox(height: 14),
          Text(state.t.orJoinCode, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            maxLength: 6,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: state.t.tableCode,
              counterText: '',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => state.joinByCode(_code.text),
            child: Text(state.t.join),
          ),
        ],
      ),
    );
  }
}

/// Requirement 21: the picture is chosen from the top bar, and the server
/// refuses the change once the player is seated at a table.
Future<void> _openPicturePicker(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);

      return Consumer<GameState>(
        builder: (context, state, _) {
          final user = state.user;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Avatar(
                        url: state.avatarUrl,
                        fallback: user?.displayName ?? '',
                        radius: 24,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(state.t.yourPicture,
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800)),
                            Text(
                              user == null || (user.avatarChoice ?? '').isEmpty
                                  ? 'Using your ${user?.provider ?? 'guest'} picture.'
                                  : state.t.pictureLocked,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 88,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final p in state.pictures)
                          _PictureChoice(
                            picture: p,
                            selected: user?.avatarChoice == p.id,
                            onTap: () => state.chooseAvatar(p.id),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // The button is always here, so a guest can see that using
                  // their own photo is something the game does — it just needs
                  // a Google or Facebook account. Hiding it would make the
                  // feature invisible to exactly the people who have not found
                  // it yet.
                  Builder(
                    builder: (context) {
                      final theme = Theme.of(context);
                      final hasPhoto =
                          (user?.providerAvatarUrl ?? '').isNotEmpty;
                      final guest = (user?.provider ?? 'guest') == 'guest';
                      final enabled = hasPhoto && !guest;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed:
                                enabled ? () => state.chooseAvatar(null) : null,
                            icon: const Icon(Icons.account_circle_outlined,
                                size: 18),
                            label: Text(state.t.useSocialPicture),
                          ),
                          if (!enabled) ...[
                            const SizedBox(height: 4),
                            Text(
                              state.t.guestNoSocial,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class _PictureChoice extends StatelessWidget {
  const _PictureChoice({
    required this.picture,
    required this.selected,
    required this.onTap,
  });

  final ProfilePicture picture;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = context.read<GameState>().absoluteUrl(picture.url);

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 3,
            ),
          ),
          child: Avatar(url: url, fallback: picture.id, radius: 32),
        ),
      ),
    );
  }
}

/// The player's record, opened from the info button on the top bar. It is a
/// drawer rather than a card on the rail because it is something you look up,
/// not something you choose between.
class _StatsDrawer extends StatelessWidget {
  const _StatsDrawer();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final user = state.user;
    final t = state.t;
    final theme = Theme.of(context);

    final rows = <(IconData, String, String)>[
      (Icons.style_outlined, t.handsPlayed, formatChips(user?.handsPlayed ?? 0)),
      (Icons.emoji_events_outlined, t.won, formatChips(user?.handsWon ?? 0)),
      (Icons.trending_down, t.lost, formatChips(user?.handsLost ?? 0)),
      (Icons.exit_to_app, t.leftMidHand, formatChips(user?.handsLeftMid ?? 0)),
      (Icons.savings_outlined, t.totalWinnings, formatChips(user?.totalWinnings ?? 0)),
      (Icons.local_fire_department_outlined, t.biggestPot,
          formatChips(user?.biggestPot ?? 0)),
    ];

    return Drawer(
      width: 340,
      child: SafeArea(
        // Landscape leaves very little height, so this scrolls rather than
        // overflowing — which is what was clipping the name off the top.
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      (user?.displayName ?? '?').characters.first.toUpperCase(),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user?.displayName ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        Text(t.yourRecord, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            for (var i = 0; i < rows.length; i++)
              _Entrance(
                index: i,
                axis: Axis.vertical,
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  minLeadingWidth: 24,
                  leading: Icon(rows[i].$1, size: 18),
                  title: Text(rows[i].$2, style: theme.textTheme.bodyMedium),
                  trailing: Text(
                    rows[i].$3,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Text(
                t.playedNote,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings, in the same right-hand drawer as the record.
class _SettingsDrawer extends StatefulWidget {
  const _SettingsDrawer();

  @override
  State<_SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<_SettingsDrawer> {
  late final TextEditingController _name;
  String? _nameError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: context.read<GameState>().user?.displayName ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Requirement 29: renaming happens here, in the lobby. The server has the
  /// final word on what a name may be, so its complaint is what gets shown
  /// rather than a second copy of the rules living in the client.
  Future<void> _save(GameState state) async {
    setState(() {
      _saving = true;
      _nameError = null;
    });

    final error = await state.renameTo(_name.text);
    if (!mounted) return;

    setState(() {
      _saving = false;
      _nameError = error;
    });

    if (error == null) {
      _name.text = state.user?.displayName ?? _name.text;
      state.say(state.t.nameSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final t = state.t;

    return Drawer(
      width: 340,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.settings_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(t.settings,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: TextField(
                controller: _name,
                maxLength: 24,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: t.displayName,
                  prefixIcon: const Icon(Icons.badge_outlined),
                  counterText: '',
                  isDense: true,
                  errorText: _nameError,
                  suffixIcon: _saving
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: t.save,
                          icon: const Icon(Icons.check),
                          onPressed: () => _save(state),
                        ),
                ),
                onSubmitted: (_) => _save(state),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: DropdownButtonFormField<AppLang>(
                initialValue: state.lang,
                decoration: InputDecoration(
                  labelText: t.language,
                  prefixIcon: const Icon(Icons.translate),
                  isDense: true,
                ),
                // Each language names itself, which is the only label a player
                // who does not read the current one can act on.
                items: [
                  for (final l in AppLang.values)
                    DropdownMenuItem(
                      value: l,
                      child: Text(
                        l == AppLang.english
                            ? l.nativeName
                            : '${l.nativeName}  ·  ${l.englishName}',
                      ),
                    ),
                ],
                onChanged: (l) => l == null ? null : state.setLanguage(l),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.menu_book_outlined, size: 20),
              title: Text(t.rules),
              subtitle: Text(t.rulesTitle),
              onTap: () {
                Navigator.pop(context);
                showRules(context);
              },
            ),
            ListTile(
              dense: true,
              leading: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, anim) => RotationTransition(
                  turns: Tween(begin: 0.6, end: 1.0).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Icon(
                  state.themeMode == ThemeMode.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  key: ValueKey(state.themeMode),
                  size: 20,
                ),
              ),
              title: Text(
                state.themeMode == ThemeMode.dark ? t.dayMode : t.nightMode,
              ),
              onTap: state.toggleTheme,
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.logout, color: theme.colorScheme.error),
              title: Text(
                t.signOut,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: state.signOut,
            ),
          ],
        ),
      ),
    );
  }
}

/// Fades and lifts a widget in, staggered by its place in the row, so the
/// lobby assembles itself instead of appearing all at once.
class _Entrance extends StatefulWidget {
  const _Entrance({
    required this.index,
    required this.child,
    this.axis = Axis.horizontal,
  });

  final int index;
  final Widget child;
  final Axis axis;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void initState() {
    super.initState();
    // Capped, so a long rail does not take a noticeable age to finish.
    final delay = Duration(milliseconds: (widget.index * 70).clamp(0, 560));
    Future<void>.delayed(delay, () {
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
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    final from = widget.axis == Axis.horizontal
        ? const Offset(0.14, 0)
        : const Offset(0, 0.25);

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: from, end: Offset.zero).animate(curved),
        child: widget.child,
      ),
    );
  }
}

/// Presses in slightly when touched, so a tap on a big card still feels like a
/// button.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class _BonusChip extends StatelessWidget {
  const _BonusChip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final r = state.user?.rewards;
    if (r == null) return const SizedBox.shrink();

    final ready = r.bonusReady;
    return _CornerChip(
      icon: Icons.hourglass_bottom,
      title: state.t.fourHourBonus,
      subtitle: ready
          ? '${state.t.collect} ${formatChips(r.bonusReward)}'
          : formatCountdown(r.untilBonus),
      enabled: ready,
      onTap: () => state.claimReward('bonus'),
    );
  }
}

class _MilestoneChip extends StatelessWidget {
  const _MilestoneChip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final r = state.user?.rewards;
    if (r == null) return const SizedBox.shrink();

    return _CornerChip(
      icon: Icons.emoji_events_outlined,
      title: state.t.milestone,
      subtitle: r.milestoneAvailable
          ? '${state.t.collect} ${formatChips(r.milestoneReward)}'
          : '${r.handsToNextMilestone} ${state.t.handsToGo}',
      enabled: r.milestoneAvailable,
      onTap: () => state.claimReward('milestone'),
    );
  }
}

class _CornerChip extends StatelessWidget {
  const _CornerChip({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = enabled
        ? theme.colorScheme.secondaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final fg = enabled
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: fg, letterSpacing: 0.6)),
                  Text(subtitle,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: fg, fontWeight: FontWeight.w800)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
