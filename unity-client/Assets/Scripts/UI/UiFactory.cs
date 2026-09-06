using System;
using UnityEngine;
using UnityEngine.UI;

namespace KingTeenPatti.UI
{
    /// <summary>
    /// Builders for the runtime uGUI.
    ///
    /// The whole interface is constructed in code so the project runs straight
    /// from an empty scene — drop <c>GameClient</c> on a GameObject and press
    /// Play. Swapping in designed prefabs later is a matter of replacing the
    /// calls in <see cref="GameUI"/>; nothing else depends on these helpers.
    /// </summary>
    public static class UiFactory
    {
        public static readonly Color Felt = new Color(0.06f, 0.30f, 0.20f);
        public static readonly Color FeltDark = new Color(0.04f, 0.11f, 0.07f);
        public static readonly Color Panel = new Color(0.07f, 0.14f, 0.10f, 0.96f);
        public static readonly Color Gold = new Color(0.91f, 0.77f, 0.42f);
        public static readonly Color Ink = new Color(0.95f, 0.96f, 0.95f);
        public static readonly Color Muted = new Color(0.62f, 0.70f, 0.66f);
        public static readonly Color Danger = new Color(0.89f, 0.38f, 0.31f);
        public static readonly Color Good = new Color(0.31f, 0.75f, 0.50f);

        private static Font _font;

        /// <summary>The built-in font, resolved across Unity versions.</summary>
        public static Font DefaultFont
        {
            get
            {
                if (_font != null) return _font;
                // LegacyRuntime.ttf on 2022+, Arial.ttf on older versions.
                _font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf")
                        ?? Resources.GetBuiltinResource<Font>("Arial.ttf");
                return _font;
            }
        }

        public static Canvas CreateCanvas(string name, out GraphicRaycaster raycaster)
        {
            var go = new GameObject(name, typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
            var canvas = go.GetComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;

            var scaler = go.GetComponent<CanvasScaler>();
            scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
            // Portrait reference: this is a phone-first game that also runs in a browser.
            scaler.referenceResolution = new Vector2(1080, 1920);
            scaler.matchWidthOrHeight = 0.5f;

            raycaster = go.GetComponent<GraphicRaycaster>();
            return canvas;
        }

        public static RectTransform CreateRect(string name, Transform parent)
        {
            var go = new GameObject(name, typeof(RectTransform));
            var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false);
            return rect;
        }

        /// <summary>A full-screen stretched container.</summary>
        public static RectTransform CreatePanel(string name, Transform parent, Color color)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image));
            var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false);
            Stretch(rect);
            go.GetComponent<Image>().color = color;
            return rect;
        }

        public static void Stretch(RectTransform rect, float padding = 0f)
        {
            rect.anchorMin = Vector2.zero;
            rect.anchorMax = Vector2.one;
            rect.offsetMin = new Vector2(padding, padding);
            rect.offsetMax = new Vector2(-padding, -padding);
        }

        public static void Anchor(RectTransform rect, Vector2 anchorMin, Vector2 anchorMax,
            Vector2 offsetMin, Vector2 offsetMax)
        {
            rect.anchorMin = anchorMin;
            rect.anchorMax = anchorMax;
            rect.offsetMin = offsetMin;
            rect.offsetMax = offsetMax;
        }

        public static Text CreateText(
            string name,
            Transform parent,
            string content,
            int size = 32,
            TextAnchor alignment = TextAnchor.MiddleCenter,
            Color? color = null,
            FontStyle style = FontStyle.Normal)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Text));
            var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false);

            var text = go.GetComponent<Text>();
            text.font = DefaultFont;
            text.text = content;
            text.fontSize = size;
            text.alignment = alignment;
            text.color = color ?? Ink;
            text.fontStyle = style;
            text.horizontalOverflow = HorizontalWrapMode.Wrap;
            text.verticalOverflow = VerticalWrapMode.Truncate;
            text.raycastTarget = false;
            return text;
        }

        public static Image CreateImage(string name, Transform parent, Color color)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image));
            go.GetComponent<RectTransform>().SetParent(parent, false);
            var image = go.GetComponent<Image>();
            image.color = color;
            return image;
        }

        public static Button CreateButton(
            string name,
            Transform parent,
            string label,
            Action onClick,
            Color? background = null,
            Color? textColor = null,
            int fontSize = 30)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button));
            go.GetComponent<RectTransform>().SetParent(parent, false);

            var image = go.GetComponent<Image>();
            image.color = background ?? new Color(0.10f, 0.20f, 0.15f);

            var button = go.GetComponent<Button>();
            button.targetGraphic = image;
            if (onClick != null) button.onClick.AddListener(() => onClick());

            var text = CreateText("Label", go.transform, label, fontSize, TextAnchor.MiddleCenter,
                textColor ?? Ink, FontStyle.Bold);
            Stretch(text.rectTransform, 6f);

            return button;
        }

        public static InputField CreateInput(string name, Transform parent, string placeholder, int fontSize = 30)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(InputField));
            go.GetComponent<RectTransform>().SetParent(parent, false);
            go.GetComponent<Image>().color = new Color(0.04f, 0.09f, 0.06f);

            var field = go.GetComponent<InputField>();

            var text = CreateText("Text", go.transform, string.Empty, fontSize, TextAnchor.MiddleLeft, Ink);
            Stretch(text.rectTransform, 14f);
            text.raycastTarget = true;
            text.supportRichText = false;

            var hint = CreateText("Placeholder", go.transform, placeholder, fontSize, TextAnchor.MiddleLeft, Muted,
                FontStyle.Italic);
            Stretch(hint.rectTransform, 14f);

            field.textComponent = text;
            field.placeholder = hint;
            field.targetGraphic = go.GetComponent<Image>();
            return field;
        }

        /// <summary>A vertical list container with automatic layout.</summary>
        public static VerticalLayoutGroup CreateColumn(
            string name,
            Transform parent,
            float spacing = 14f,
            RectOffset padding = null)
        {
            var rect = CreateRect(name, parent);
            var layout = rect.gameObject.AddComponent<VerticalLayoutGroup>();
            layout.spacing = spacing;
            layout.padding = padding ?? new RectOffset(0, 0, 0, 0);
            layout.childControlWidth = true;
            layout.childControlHeight = false;
            layout.childForceExpandWidth = true;
            layout.childForceExpandHeight = false;
            return layout;
        }

        public static HorizontalLayoutGroup CreateRow(
            string name,
            Transform parent,
            float spacing = 12f)
        {
            var rect = CreateRect(name, parent);
            var layout = rect.gameObject.AddComponent<HorizontalLayoutGroup>();
            layout.spacing = spacing;
            layout.childControlWidth = true;
            layout.childControlHeight = true;
            layout.childForceExpandWidth = true;
            layout.childForceExpandHeight = true;
            return layout;
        }

        public static LayoutElement SetHeight(GameObject go, float height)
        {
            var element = go.GetComponent<LayoutElement>() ?? go.AddComponent<LayoutElement>();
            element.preferredHeight = height;
            element.minHeight = height;
            return element;
        }
    }
}
