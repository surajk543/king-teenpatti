using KingTeenPatti.Models;
using UnityEngine;
using UnityEngine.UI;

namespace KingTeenPatti.UI
{
    /// <summary>
    /// One player's place at the table.
    ///
    /// The shape follows the arrangement players already know from every other
    /// Teen Patti app: a portrait pod with the name across the top, a picture in
    /// the middle and the stack on a pill underneath, its own three face-down
    /// cards alongside, and the chips it has put in this hand floating between
    /// the pod and the pot. Colour comes from the palette, so it works in both
    /// themes; only the arrangement is borrowed.
    /// </summary>
    public class SeatView
    {
        private Image _pod;
        private Image _ring;
        private Image _turnFill;
        /// <summary>Where the chip sits with, and without, card backs beside it.</summary>
        private Vector2 _betFar;
        private Vector2 _betClose;
        private Vector2 _statusFar;
        private Vector2 _statusClose;
        private Vector2 _pillSize;
        private Image _avatar;
        private Text _avatarGlyph;
        private Text _name;
        private Image _chipsPill;
        private Text _chips;
        private Text _status;
        private Image _dealerBadge;
        private Text _dealer;
        private Image _betPill;
        private Text _bet;
        private readonly Image[] _cardBacks = new Image[3];

        private static Color Idle => UiFactory.Scheme.Surface2;
        private static Color OnTurn => UiFactory.Scheme.SecondaryContainer;
        private static Color Winner => UiFactory.Scheme.PrimaryContainer;

        /// <summary>True while this seat is the one on turn, so it pulses.</summary>
        private bool _isOnTurn;

        /// A card back is the same red in either theme, like the cards themselves.
        private static readonly Color CardBack = new Color(0.52f, 0.16f, 0.16f);

        /// <summary>
        /// Builds a pod centred on <paramref name="centre"/> (a fraction of the
        /// felt). Everything that belongs to the seat but sits outside the pod —
        /// its cards, its status, its bet — is laid out towards the middle of
        /// the table, so a seat at the top reads downwards and one at the bottom
        /// reads upwards.
        /// </summary>
        public static SeatView Create(Transform parent, int index, Vector2 centre, Vector2 half)
        {
            var view = new SeatView();

            // Which way the middle of the table lies from this pod. A pod on
            // the left or right edge lays its cards and chips out sideways: the
            // table is an oval, and stacking them downwards there walks them
            // straight off the curved rim.
            var isSide = centre.x < 0.2f || centre.x > 0.8f;
            var inward = isSide
                ? (centre.x < 0.5f ? 1f : -1f)
                : (centre.y < 0.5f ? 1f : -1f);
            var edge = isSide
                ? (inward > 0f ? centre.x + half.x : centre.x - half.x)
                : (inward > 0f ? centre.y + half.y : centre.y - half.y);

            // A slot at a given distance out from the pod. Distances are in
            // fractions of whichever axis it runs along, so the two cases take
            // different numbers: the felt is far wider than it is tall.
            // Everything that hangs off the pod is anchored to the middle of
            // the pod's inward edge and then offset in canvas units. Sizing in
            // fractions of the felt made a card's size depend on which way its
            // seat happened to lay out, so no two players' cards matched.
            var anchor = isSide ? new Vector2(edge, centre.y) : new Vector2(centre.x, edge);

            void Place(RectTransform rect, Vector2 size, float reach, float cross)
            {
                rect.anchorMin = anchor;
                rect.anchorMax = anchor;
                rect.pivot = new Vector2(0.5f, 0.5f);
                rect.sizeDelta = size;
                rect.anchoredPosition = isSide
                    ? new Vector2(inward * reach, cross)
                    : new Vector2(cross, inward * reach);
            }

            // Three cards, edge to edge. The row is exactly three card widths,
            // so there is nothing left over to show up as a gap.
            var deckSize = new Vector2(3f * UiFactory.CardWidth, UiFactory.CardHeight);
            var deckReach = (isSide ? deckSize.x : deckSize.y) * 0.5f + 12f;

            var pillSize = new Vector2(210f, 54f);
            // Past the cards when they are drawn...
            var farReach = isSide ? deckReach : deckReach + deckSize.y * 0.5f + 10f + pillSize.y * 0.5f;
            var farCross = isSide ? -(deckSize.y * 0.5f + 10f + pillSize.y * 0.5f) : 0f;
            // ...and tucked against the pod when they are not, which is the
            // viewer's own seat: their hand is in the tray, not here.
            var nearReach = pillSize.y * 0.5f + 12f;

            view._ring = UiFactory.CreateRounded($"Ring{index}", parent,
                UiFactory.Alpha(UiFactory.Good, 0f), UiFactory.ShapeLarge);
            UiFactory.Anchor(view._ring.rectTransform,
                new Vector2(centre.x - half.x, centre.y - half.y),
                new Vector2(centre.x + half.x, centre.y + half.y),
                new Vector2(-6, -6), new Vector2(6, 6));

            view._pod = UiFactory.CreateRounded($"Seat{index}", parent, Idle, UiFactory.ShapeLarge);

            UiFactory.Anchor(view._pod.rectTransform,
                new Vector2(centre.x - half.x, centre.y - half.y),
                new Vector2(centre.x + half.x, centre.y + half.y),
                Vector2.zero, Vector2.zero);

            var root = view._pod.transform;

            // The turn clock, drawn as the pod filling up from the bottom. When
            // it is full the player has run out of time, so the countdown is
            // read from the seat itself rather than from a bar somewhere else.
            view._turnFill = UiFactory.CreateRounded("TurnFill", root,
                UiFactory.Alpha(UiFactory.Good, 0.34f), UiFactory.ShapeLarge);
            UiFactory.Stretch(view._turnFill.rectTransform);
            view._turnFill.type = Image.Type.Filled;
            view._turnFill.fillMethod = Image.FillMethod.Vertical;
            view._turnFill.fillOrigin = (int)Image.OriginVertical.Bottom;
            view._turnFill.fillAmount = 0f;
            view._turnFill.raycastTarget = false;

            // --- name plate across the top
            var plate = UiFactory.CreateRounded("Plate", root, UiFactory.Scheme.Surface3,
                UiFactory.ShapeSmall);
            UiFactory.Anchor(plate.rectTransform, new Vector2(0.06f, 0.78f), new Vector2(0.72f, 0.96f),
                Vector2.zero, Vector2.zero);

            view._name = UiFactory.CreateText("Name", plate.transform, string.Empty, 22,
                TextAnchor.MiddleCenter, UiFactory.Ink, FontStyle.Bold);
            UiFactory.Stretch(view._name.rectTransform, 4f);

            // --- picture
            view._avatar = UiFactory.CreateRounded("Avatar", root, UiFactory.Scheme.SurfaceVariant,
                UiFactory.ShapeMedium);
            UiFactory.Anchor(view._avatar.rectTransform, new Vector2(0.1f, 0.3f),
                new Vector2(0.9f, 0.75f), Vector2.zero, Vector2.zero);

            view._avatarGlyph = UiFactory.CreateText("Glyph", view._avatar.transform, string.Empty, 40,
                TextAnchor.MiddleCenter, UiFactory.Scheme.OnSurfaceVariant, FontStyle.Bold);
            UiFactory.Stretch(view._avatarGlyph.rectTransform, 4f);

            // --- stack, on a pill along the bottom edge
            view._chipsPill = UiFactory.CreateRounded("ChipsPill", root, UiFactory.Gold, 18);
            UiFactory.Anchor(view._chipsPill.rectTransform, new Vector2(0.04f, 0.04f),
                new Vector2(0.96f, 0.26f), Vector2.zero, Vector2.zero);

            view._chips = UiFactory.CreateText("Chips", view._chipsPill.transform, string.Empty, 20,
                TextAnchor.MiddleCenter, UiFactory.OnGold, FontStyle.Bold);
            UiFactory.Stretch(view._chips.rectTransform, 3f);

            // --- dealer button, tucked into the top-right corner
            view._dealerBadge = UiFactory.CreateRounded("DealerBadge", root,
                UiFactory.Scheme.TertiaryContainer, 22);
            UiFactory.Anchor(view._dealerBadge.rectTransform, new Vector2(0.74f, 0.78f),
                new Vector2(1.02f, 0.98f), Vector2.zero, Vector2.zero);

            view._dealer = UiFactory.CreateText("Dealer", view._dealerBadge.transform, "D", 20,
                TextAnchor.MiddleCenter, UiFactory.Scheme.OnTertiaryContainer, FontStyle.Bold);
            UiFactory.Stretch(view._dealer.rectTransform, 2f);

            // --- the three face-down cards, between the pod and the table
            var deck = UiFactory.CreateRect($"Cards{index}", parent);
            Place(deck, deckSize, deckReach, 0f);

            var spread = deck.gameObject.AddComponent<HorizontalLayoutGroup>();
            spread.spacing = 0f;
            spread.childAlignment = TextAnchor.MiddleCenter;
            spread.childControlWidth = true;
            spread.childControlHeight = true;
            spread.childForceExpandWidth = true;
            spread.childForceExpandHeight = true;

            for (var i = 0; i < 3; i++)
            {
                var back = UiFactory.CreateRounded($"Back{index}_{i}", deck, CardBack,
                    UiFactory.ShapeSmall);
                UiFactory.ApplyCardBack(back);
                view._cardBacks[i] = back;
            }

            // --- what this seat has put in, on a chip-coloured pill
            view._betPill = UiFactory.CreateRounded($"BetPill{index}", parent,
                UiFactory.Scheme.SecondaryContainer, 20);
            Place(view._betPill.rectTransform, pillSize, farReach, farCross);

            view._pillSize = pillSize;
            view._betFar = view._betPill.rectTransform.anchoredPosition;
            Place(view._betPill.rectTransform, pillSize, nearReach, 0f);
            view._betClose = view._betPill.rectTransform.anchoredPosition;
            view._betPill.rectTransform.anchoredPosition = view._betFar;

            view._bet = UiFactory.CreateText($"Bet{index}", view._betPill.transform, string.Empty, 19,
                TextAnchor.MiddleCenter, UiFactory.Scheme.OnSecondaryContainer, FontStyle.Bold);
            UiFactory.Stretch(view._bet.rectTransform, 3f);

            // --- packed / offline, called out under the name like the reference
            view._status = UiFactory.CreateText($"Status{index}", parent, string.Empty, 20,
                TextAnchor.MiddleCenter, UiFactory.OnFelt, FontStyle.Bold);
            // The status shares the chip's slot: a seat that is packed, waiting
            // or offline has nothing in the pot, so the two never both show.
            Place(view._status.rectTransform, pillSize, farReach, farCross);
            view._statusFar = view._status.rectTransform.anchoredPosition;
            Place(view._status.rectTransform, pillSize, nearReach, 0f);
            view._statusClose = view._status.rectTransform.anchoredPosition;

            return view;
        }

        /// <param name="chipsHidden">
        /// True on a blind table, where only the viewer's own stack was sent.
        /// </param>
        public void Render(SeatDto seat, bool isOnTurn, bool isDealer, string myUserId,
            bool chipsHidden = false)
        {
            // An empty chair shows nothing: a row of blank pods reads as broken
            // rather than as free seats.
            if (seat == null || !seat.IsOccupied)
            {
                SetVisible(false);
                return;
            }

            SetVisible(true);

            var isMe = seat.userId == myUserId;
            _name.text = isMe ? "YOU" : Truncate(seat.displayName, 10);
            _name.color = isMe ? UiFactory.Gold : UiFactory.Ink;

            // No picture has been downloaded here, so the pod shows the initial —
            // enough to tell players apart at a glance.
            _avatarGlyph.text = string.IsNullOrEmpty(seat.displayName)
                ? "?"
                : seat.displayName.Substring(0, 1).ToUpperInvariant();

            // On a blind table another player's stack was never sent, so show it
            // as withheld rather than printing the 0 that JsonUtility left behind.
            if (seat.ChipsKnown(chipsHidden, myUserId))
            {
                _chips.text = seat.chips.ToString("N0");
            }
            else
            {
                _chips.text = "•••";
            }

            _dealerBadge.gameObject.SetActive(isDealer);

            // The chips this seat has in the pot, labelled the way it was bet.
            var hasBet = seat.contributed > 0
                         && seat.status != SeatState.Packed
                         && seat.status != SeatState.Lost;
            _betPill.gameObject.SetActive(hasBet);
            if (hasBet)
            {
                _bet.text = (seat.isBlind ? "Blind  " : "Seen  ") + seat.contributed.ToString("N0");

                _betPill.rectTransform.anchoredPosition = isMe ? _betClose : _betFar;
            }

            _status.text = isMe ? string.Empty : DescribeStatus(seat);
            _status.rectTransform.anchoredPosition = seat.cardCount > 0 ? _statusFar : _statusClose;
            _status.color = seat.connected ? UiFactory.OnFelt : UiFactory.Danger;

            if (seat.status == SeatState.Won) _pod.color = Winner;
            else if (isOnTurn) _pod.color = OnTurn;
            else _pod.color = Idle;

            _isOnTurn = isOnTurn;
            if (!isOnTurn)
            {
                _ring.color = UiFactory.Alpha(UiFactory.Good, 0f);
                _turnFill.fillAmount = 0f;
            }

            // A packed player's card backs are dimmed rather than removed, so the
            // seat still reads as "was in this hand".
            // The viewer's own hand is shown full size in the tray, so their pod
            // does not repeat it as three backs.
            var alpha = seat.status == SeatState.Packed || seat.status == SeatState.Lost ? 0.22f : 1f;
            SetCardBacks(isMe ? 0 : seat.cardCount, alpha);
        }

        private void SetVisible(bool visible)
        {
            _pod.gameObject.SetActive(visible);
            _ring.gameObject.SetActive(visible);
            _status.gameObject.SetActive(visible);

            if (!visible)
            {
                _dealerBadge.gameObject.SetActive(false);
                _betPill.gameObject.SetActive(false);
                SetCardBacks(0);
            }
        }

        /// <summary>
        /// Pulses the ring around the seat on turn. Called every frame; a seat
        /// that is not on turn does nothing.
        /// </summary>
        /// <param name="elapsed">
        /// How much of this player's turn has gone, 0 to 1. The pod fills as it
        /// climbs, and a full pod means the clock has run out. Negative when no
        /// deadline is known, which just leaves the pod blinking.
        /// </param>
        public void TickHighlight(float elapsed = -1f)
        {
            if (_ring == null) return;
            if (!_isOnTurn) return;

            // A slow sine so it reads as a heartbeat rather than a flicker.
            var pulse = 0.25f + 0.75f * Mathf.Abs(Mathf.Sin(Time.realtimeSinceStartup * 3f));

            // The blink starts green and bleeds to red as the clock empties, so
            // the colour alone says how long the player has left. Squared, so it
            // stays green for most of the turn and reddens sharply at the end
            // rather than sitting muddy in the middle.
            var urgency = elapsed < 0f ? 0f : Mathf.Clamp01(elapsed) * Mathf.Clamp01(elapsed);
            var beat = Color.Lerp(UiFactory.Good, UiFactory.Danger, urgency);

            _ring.color = UiFactory.Alpha(beat, pulse);

            if (_turnFill == null || elapsed < 0f) return;

            _turnFill.fillAmount = Mathf.Clamp01(elapsed);
            _turnFill.color = UiFactory.Alpha(beat, 0.34f);
        }

        private static string DescribeStatus(SeatDto seat)
        {
            if (!seat.connected) return "offline";
            if (seat.status == SeatState.Packed) return "Pack";
            if (seat.status == SeatState.Won) return "Winner";
            if (seat.status == SeatState.Waiting) return "waiting";
            return string.Empty;
        }

        private void SetCardBacks(int count, float alpha = 1f)
        {
            for (var i = 0; i < _cardBacks.Length; i++)
            {
                var show = i < count;
                _cardBacks[i].gameObject.SetActive(show);
                if (!show) continue;

                // The artwork is tinted white so only its alpha changes; a plain
                // coloured back keeps its own colour.
                _cardBacks[i].color = UiFactory.CardBack != null
                    ? new Color(1f, 1f, 1f, alpha)
                    : new Color(CardBack.r, CardBack.g, CardBack.b, alpha);
            }
        }

        private static string Truncate(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) return "Player";
            return value.Length <= max ? value : value.Substring(0, max - 1) + "…";
        }
    }
}
