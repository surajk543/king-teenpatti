using KingTeenPatti.Game;
using UnityEngine;
using UnityEngine.UI;

namespace KingTeenPatti.UI
{
    /// <summary>
    /// One of the player's own three cards.
    ///
    /// It has three looks: hidden (not in the hand), face down (dealt but not
    /// yet seen) and face up. The server only sends card faces after the player
    /// presses "see", so a face-down card genuinely has no value on the client.
    /// </summary>
    public class CardView
    {
        private Image _background;
        private Text _rank;
        private Text _suit;

        private static readonly Color Face = new Color(0.97f, 0.97f, 0.95f);
        private static readonly Color Back = new Color(0.52f, 0.16f, 0.16f);

        public static CardView Create(Transform parent, Vector2 anchorMin, Vector2 anchorMax)
        {
            var view = new CardView();

            view._background = UiFactory.CreateImage("Card", parent, Back);
            UiFactory.Anchor(view._background.rectTransform, anchorMin, anchorMax, Vector2.zero, Vector2.zero);

            view._rank = UiFactory.CreateText("Rank", view._background.transform, string.Empty, 56,
                TextAnchor.MiddleCenter, Card.Black, FontStyle.Bold);
            UiFactory.Anchor(view._rank.rectTransform, new Vector2(0, 0.44f), new Vector2(1, 0.92f),
                Vector2.zero, Vector2.zero);

            view._suit = UiFactory.CreateText("Suit", view._background.transform, string.Empty, 48,
                TextAnchor.MiddleCenter, Card.Black);
            UiFactory.Anchor(view._suit.rectTransform, new Vector2(0, 0.08f), new Vector2(1, 0.48f),
                Vector2.zero, Vector2.zero);

            return view;
        }

        /// <summary>Not in the hand at all — hide the card entirely.</summary>
        public void SetHidden() => _background.gameObject.SetActive(false);

        /// <summary>Dealt, but this player has not looked yet.</summary>
        public void SetBack()
        {
            _background.gameObject.SetActive(true);
            _background.color = Back;
            _rank.text = string.Empty;
            _suit.text = string.Empty;
        }

        /// <summary>Reveals a card from its server code, e.g. "As" or "Td".</summary>
        public void SetFace(string code)
        {
            if (string.IsNullOrEmpty(code))
            {
                SetBack();
                return;
            }

            _background.gameObject.SetActive(true);
            _background.color = Face;

            var color = Card.ColorOf(code);
            _rank.text = Card.RankOf(code);
            _rank.color = color;
            _suit.text = Card.SuitSymbol(code);
            _suit.color = color;
        }
    }
}
