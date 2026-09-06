using KingTeenPatti.Models;
using UnityEngine;
using UnityEngine.UI;

namespace KingTeenPatti.UI
{
    /// <summary>One seat around the table: name, chips, state and card backs.</summary>
    public class SeatView
    {
        private Image _background;
        private Image _highlight;
        private Text _name;
        private Text _chips;
        private Text _status;
        private Text _dealer;
        private readonly Image[] _cardBacks = new Image[3];

        private static readonly Color Idle = new Color(0f, 0f, 0f, 0.28f);
        private static readonly Color OnTurn = new Color(0.91f, 0.77f, 0.42f, 0.22f);
        private static readonly Color Winner = new Color(0.31f, 0.75f, 0.50f, 0.28f);

        public static SeatView Create(Transform parent, int index, Vector2 anchorMin, Vector2 anchorMax)
        {
            var view = new SeatView();

            view._background = UiFactory.CreateImage($"Seat{index}", parent, Idle);
            UiFactory.Anchor(view._background.rectTransform, anchorMin, anchorMax, Vector2.zero, Vector2.zero);

            var root = view._background.transform;

            view._highlight = UiFactory.CreateImage("Highlight", root, new Color(0.91f, 0.77f, 0.42f, 0f));
            UiFactory.Stretch(view._highlight.rectTransform, -4f);
            view._highlight.transform.SetAsFirstSibling();

            view._dealer = UiFactory.CreateText("Dealer", root, string.Empty, 20,
                TextAnchor.MiddleCenter, Color.white, FontStyle.Bold);
            UiFactory.Anchor(view._dealer.rectTransform, new Vector2(0, 0.86f), new Vector2(1, 1f),
                Vector2.zero, Vector2.zero);

            view._name = UiFactory.CreateText("Name", root, string.Empty, 22,
                TextAnchor.MiddleCenter, UiFactory.Ink, FontStyle.Bold);
            UiFactory.Anchor(view._name.rectTransform, new Vector2(0, 0.68f), new Vector2(1, 0.87f),
                Vector2.zero, Vector2.zero);

            view._chips = UiFactory.CreateText("Chips", root, string.Empty, 22,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(view._chips.rectTransform, new Vector2(0, 0.52f), new Vector2(1, 0.69f),
                Vector2.zero, Vector2.zero);

            view._status = UiFactory.CreateText("Status", root, string.Empty, 18,
                TextAnchor.MiddleCenter, UiFactory.Muted);
            UiFactory.Anchor(view._status.rectTransform, new Vector2(0, 0.36f), new Vector2(1, 0.53f),
                Vector2.zero, Vector2.zero);

            // Three face-down cards; nobody ever sees an opponent's faces.
            for (var i = 0; i < 3; i++)
            {
                var back = UiFactory.CreateImage($"Back{i}", root, new Color(0.52f, 0.16f, 0.16f));
                var x = 0.16f + i * 0.24f;
                UiFactory.Anchor(back.rectTransform, new Vector2(x, 0.06f), new Vector2(x + 0.20f, 0.34f),
                    Vector2.zero, Vector2.zero);
                view._cardBacks[i] = back;
            }

            return view;
        }

        /// <param name="chipsHidden">
        /// True on a blind table, where only the viewer's own stack was sent.
        /// </param>
        public void Render(SeatDto seat, bool isOnTurn, bool isDealer, string myUserId,
            bool chipsHidden = false)
        {
            if (seat == null || !seat.IsOccupied)
            {
                _background.color = Idle;
                _highlight.color = new Color(0, 0, 0, 0);
                _name.text = "—";
                _chips.text = string.Empty;
                _status.text = "empty";
                _dealer.text = string.Empty;
                SetCardBacks(0);
                return;
            }

            var isMe = seat.userId == myUserId;
            _name.text = isMe ? "YOU" : Truncate(seat.displayName, 10);
            _name.color = isMe ? UiFactory.Gold : UiFactory.Ink;

            // On a blind table another player's stack was never sent, so show it
            // as withheld rather than printing the 0 that JsonUtility left behind.
            if (seat.ChipsKnown(chipsHidden, myUserId))
            {
                _chips.text = seat.chips.ToString("N0");
                _chips.color = UiFactory.Gold;
            }
            else
            {
                _chips.text = "•••";
                _chips.color = UiFactory.Muted;
            }

            _dealer.text = isDealer ? "D" : string.Empty;

            _status.text = DescribeStatus(seat);
            _status.color = seat.connected ? UiFactory.Muted : UiFactory.Danger;

            if (seat.status == SeatState.Won) _background.color = Winner;
            else if (isOnTurn) _background.color = OnTurn;
            else _background.color = Idle;

            _highlight.color = isOnTurn
                ? new Color(0.91f, 0.77f, 0.42f, 0.55f)
                : new Color(0, 0, 0, 0);

            // A packed player's card backs are dimmed rather than removed, so the
            // seat still reads as "was in this hand".
            var alpha = seat.status == SeatState.Packed || seat.status == SeatState.Lost ? 0.22f : 1f;
            SetCardBacks(seat.cardCount, alpha);
        }

        private static string DescribeStatus(SeatDto seat)
        {
            if (!seat.connected) return "offline";

            switch (seat.status)
            {
                case SeatState.Active:
                    var bet = seat.contributed > 0 ? "  " + seat.contributed.ToString("N0") : string.Empty;
                    return (seat.isBlind ? "blind" : "seen") + bet;
                case SeatState.Packed: return "packed";
                case SeatState.Lost: return "lost";
                case SeatState.Won: return "WON";
                case SeatState.Waiting: return "waiting";
                default: return seat.status;
            }
        }

        private void SetCardBacks(int count, float alpha = 1f)
        {
            for (var i = 0; i < _cardBacks.Length; i++)
            {
                var visible = i < count;
                _cardBacks[i].gameObject.SetActive(visible);
                if (visible) _cardBacks[i].color = new Color(0.52f, 0.16f, 0.16f, alpha);
            }
        }

        private static string Truncate(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) return "Player";
            return value.Length <= max ? value : value.Substring(0, max - 1) + "…";
        }
    }
}
