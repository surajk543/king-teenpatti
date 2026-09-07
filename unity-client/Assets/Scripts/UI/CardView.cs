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
        private Image _suit;

        /// A playing card is a physical object: it looks the same whichever
        /// theme the app is in, so these two are deliberately not palette roles.
        public static readonly Color Face = new Color(0.97f, 0.97f, 0.95f);
        public static readonly Color Back = new Color(0.52f, 0.16f, 0.16f);

        public static CardView Create(Transform parent, Vector2 anchorMin, Vector2 anchorMax)
        {
            var view = new CardView();

            view._background = UiFactory.CreateRounded("Card", parent, Back, UiFactory.ShapeMedium);
            UiFactory.Anchor(view._background.rectTransform, anchorMin, anchorMax, Vector2.zero, Vector2.zero);

            view._rank = UiFactory.CreateText("Rank", view._background.transform, string.Empty, 56,
                TextAnchor.MiddleCenter, Card.Black, FontStyle.Bold);
            UiFactory.Anchor(view._rank.rectTransform, new Vector2(0, 0.44f), new Vector2(1, 0.92f),
                Vector2.zero, Vector2.zero);

            // The pip is a generated sprite, not a character: the built-in font
            // has no suit glyphs on Android and the cards came out blank there.
            view._suit = UiFactory.CreateImage("Suit", view._background.transform, Card.Black);
            view._suit.preserveAspect = true;
            view._suit.raycastTarget = false;
            UiFactory.Anchor(view._suit.rectTransform, new Vector2(0.22f, 0.08f),
                new Vector2(0.78f, 0.46f), Vector2.zero, Vector2.zero);
            view._suit.enabled = false;

            return view;
        }

        /// <summary>Not in the hand at all — hide the card entirely.</summary>
        public void SetHidden() => _background.gameObject.SetActive(false);

        /// <summary>Dealt, but this player has not looked yet.</summary>
        public void SetBack()
        {
            _background.gameObject.SetActive(true);
            _rank.text = string.Empty;
            _suit.enabled = false;

            if (UiFactory.CardBack != null)
            {
                UiFactory.ApplyCardBack(_background);
                return;
            }

            _background.sprite = UiFactory.RoundedSprite(UiFactory.ShapeMedium);
            _background.type = Image.Type.Sliced;
            _background.preserveAspect = false;
            _background.color = Back;
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
            // Back to the plain rounded card the rank and pip are drawn on.
            _background.sprite = UiFactory.RoundedSprite(UiFactory.ShapeMedium);
            _background.type = Image.Type.Sliced;
            _background.preserveAspect = false;
            _background.color = Face;

            var color = Card.ColorOf(code);
            _rank.text = Card.RankOf(code);
            _rank.color = color;
            _suit.sprite = UiFactory.SuitSprite(Card.SuitOf(code));
            _suit.color = color;
            _suit.enabled = true;
        }
    }
}
