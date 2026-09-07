using UnityEngine;
using UnityEngine.UI;

namespace KingTeenPatti.UI
{
    /// <summary>
    /// Requirement 28: a band of light sweeps across a boot table card, from its
    /// top-left corner to its bottom-right, continuously. It is the only motion
    /// in the lobby, and it is what stops a grid of flat rectangles looking
    /// cheap.
    ///
    /// The card itself masks the streak, so the light is clipped to the rounded
    /// corners rather than squaring them off.
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class CardSheen : MonoBehaviour
    {
        private RectTransform _card;
        private RectTransform _streak;
        private float _period = 3.4f;
        private float _phase;

        /// <summary>
        /// Adds the sweep to a card. <paramref name="phase"/> staggers the rail
        /// so the cards do not all flash in unison, which reads as a glitch.
        /// </summary>
        public static void Attach(Image card, float phase = 0f, float period = 3.4f)
        {
            if (card == null) return;

            // Mask, not RectMask2D: this one follows the sprite's alpha, so the
            // light stops at the rounded corner instead of the bounding box.
            var mask = card.GetComponent<Mask>() ?? card.gameObject.AddComponent<Mask>();
            mask.showMaskGraphic = true;

            var streak = UiFactory.CreateImage("Sheen", card.transform, new Color(1f, 1f, 1f, 0.14f));
            streak.raycastTarget = false;

            var rect = streak.rectTransform;
            rect.anchorMin = new Vector2(0.5f, 0.5f);
            rect.anchorMax = new Vector2(0.5f, 0.5f);
            rect.pivot = new Vector2(0.5f, 0.5f);
            // Tall enough to cross the card at any point of its travel once the
            // 45-degree tilt is applied.
            rect.sizeDelta = new Vector2(150f, 3000f);
            rect.localRotation = Quaternion.Euler(0f, 0f, 45f);

            var sheen = card.gameObject.AddComponent<CardSheen>();
            sheen._card = card.rectTransform;
            sheen._streak = rect;
            sheen._phase = phase;
            sheen._period = period;
        }

        private void Update()
        {
            if (_card == null || _streak == null) return;

            // Unscaled, because a paused or slowed game should not stall the
            // lobby's idle animation.
            var t = Mathf.Repeat((Time.unscaledTime + _phase) / _period, 1f);
            var span = _card.rect.width + _card.rect.height;
            _streak.anchoredPosition = new Vector2(Mathf.Lerp(-span * 0.75f, span * 0.75f, t), 0f);
        }
    }
}
