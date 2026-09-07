using System;
using System.Collections.Generic;
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
        /// <summary>
        /// Material 3 colour scheme (requirement 23).
        ///
        /// Both schemes come from one tonal palette, and everything the UI
        /// draws reads its colour from the active <see cref="Scheme"/>. Calling
        /// <see cref="SetDarkMode"/> swaps the whole app over.
        /// </summary>
        public class ColorScheme
        {
            public Color Primary;
            public Color OnPrimary;
            public Color PrimaryContainer;
            public Color OnPrimaryContainer;
            public Color Secondary;
            public Color OnSecondary;
            public Color SecondaryContainer;
            public Color OnSecondaryContainer;
            public Color Tertiary;
            public Color OnTertiary;
            public Color TertiaryContainer;
            public Color OnTertiaryContainer;
            public Color Error;
            public Color ErrorContainer;
            public Color OnErrorContainer;
            public Color Surface;
            public Color OnSurface;
            public Color SurfaceVariant;
            public Color OnSurfaceVariant;
            public Color Outline;
            /// <summary>Elevated surfaces, from lowest to highest tint.</summary>
            public Color Surface1;
            public Color Surface2;
            public Color Surface3;
        }

        private static Color Hex(string hex)
        {
            ColorUtility.TryParseHtmlString(hex, out var color);
            return color;
        }

        public static readonly ColorScheme Dark = new ColorScheme
        {
            Primary = Hex("#7FD6A4"), OnPrimary = Hex("#00391F"),
            PrimaryContainer = Hex("#00522F"), OnPrimaryContainer = Hex("#9BF3C0"),
            Secondary = Hex("#E8C46A"), OnSecondary = Hex("#3D2E00"),
            SecondaryContainer = Hex("#574400"), OnSecondaryContainer = Hex("#FFE08B"),
            Tertiary = Hex("#A0CFE8"), OnTertiary = Hex("#003547"),
            TertiaryContainer = Hex("#1F4C60"), OnTertiaryContainer = Hex("#C4E7FF"),
            Error = Hex("#FFB4AB"), ErrorContainer = Hex("#93000A"), OnErrorContainer = Hex("#FFDAD6"),
            Surface = Hex("#0D1411"), OnSurface = Hex("#DFE4DF"),
            SurfaceVariant = Hex("#3F4943"), OnSurfaceVariant = Hex("#BFC9C2"),
            Outline = Hex("#899390"),
            Surface1 = Hex("#151D19"), Surface2 = Hex("#19241F"), Surface3 = Hex("#1E2A24"),
        };

        public static readonly ColorScheme Light = new ColorScheme
        {
            Primary = Hex("#006C42"), OnPrimary = Hex("#FFFFFF"),
            PrimaryContainer = Hex("#9BF3C0"), OnPrimaryContainer = Hex("#002110"),
            Secondary = Hex("#6D5C00"), OnSecondary = Hex("#FFFFFF"),
            SecondaryContainer = Hex("#FFE08B"), OnSecondaryContainer = Hex("#221B00"),
            Tertiary = Hex("#1B6683"), OnTertiary = Hex("#FFFFFF"),
            TertiaryContainer = Hex("#C4E7FF"), OnTertiaryContainer = Hex("#001E2B"),
            Error = Hex("#BA1A1A"), ErrorContainer = Hex("#FFDAD6"), OnErrorContainer = Hex("#410002"),
            Surface = Hex("#F5FBF5"), OnSurface = Hex("#171D1A"),
            SurfaceVariant = Hex("#DCE5DD"), OnSurfaceVariant = Hex("#414942"),
            Outline = Hex("#717972"),
            Surface1 = Hex("#EEF5EF"), Surface2 = Hex("#E8F1EA"), Surface3 = Hex("#E2EDE5"),
        };

        /// <summary>The scheme every builder below reads from.</summary>
        /// <summary>Day mode is the default; the toggle remembers a change.</summary>
        public static ColorScheme Scheme { get; private set; } = Light;

        public static bool IsDarkMode { get; private set; }

        /// <summary>Raised after a theme switch so live views can recolour.</summary>
        public static event System.Action ThemeChanged;

        public static void SetDarkMode(bool dark)
        {
            IsDarkMode = dark;
            Scheme = dark ? Dark : Light;
            ThemeChanged?.Invoke();
        }

        // Role aliases, so existing call sites keep reading naturally.
        /// <summary>
        /// The table baize. Deliberately not a palette role: a card table is the
        /// same green in daylight as at night, and reading it from the scheme
        /// turned it mint in day mode.
        /// </summary>
        public static Color Felt => IsDarkMode ? Hex("#0B3B27") : Hex("#0F5236");
        public static Color OnFelt => Hex("#E6F4EB");
        public static Color FeltDark => Scheme.Surface;
        public static Color Panel => Scheme.Surface1;
        public static Color Gold => Scheme.Secondary;
        public static Color Ink => Scheme.OnSurface;
        public static Color Muted => Scheme.OnSurfaceVariant;
        public static Color Danger => Scheme.Error;
        public static Color Good => Scheme.Primary;
        /// <summary>The resting fill of a tonal button, and its matching label.</summary>
        public static Color Tonal => Scheme.SurfaceVariant;
        public static Color OnTonal => Scheme.OnSurface;
        /// <summary>The label to put on a <see cref="Gold"/> fill.</summary>
        public static Color OnGold => Scheme.OnSecondary;
        /// <summary>The fill of a text field.</summary>
        public static Color Field => Scheme.SurfaceVariant;

        /// <summary>The same colour at a different opacity — M3 state layers.</summary>
        public static Color Alpha(Color colour, float alpha) =>
            new Color(colour.r, colour.g, colour.b, alpha);

        /// <summary>
        /// The width the interface is laid out in, in canvas units.
        ///
        /// A phone held in landscape is much wider than the content needs, and
        /// letting a column stretch edge to edge gives buttons the width of the
        /// whole screen. Screens anchor their content to this instead, which
        /// mirrors the browser client's --app-width and keeps the two looking
        /// like the same game.
        /// </summary>
        public const float AppWidth = 1560f;

        /// <summary>
        /// The height of that same window. Together with <see cref="AppWidth"/>
        /// it is the one card every screen is drawn inside, so login, lobby and
        /// table are the same size and in the same place.
        /// </summary>
        public const float AppHeight = 920f;

        // M3 shape scale, in canvas units (which are texture pixels here).
        /// <summary>
        /// One playing card, in canvas units, and the same everywhere: the
        /// player's own hand and every opponent's use it, so a card means the
        /// same thing wherever it appears on the table.
        ///
        /// The ratio matches the card-back artwork (691x973). Slots that do not
        /// match it letterbox the image, and that letterboxing is what shows up
        /// as a gap between neighbouring cards.
        /// </summary>
        /// The size is set by the tightest pair on the table — the right-hand
        /// seat's row and the top-right seat's row — with five seats dealt in.
        public const float CardWidth = 106f;
        public const float CardHeight = 149f;

        public const int ShapeSmall = 12;
        public const int ShapeMedium = 20;
        public const int ShapeLarge = 28;
        public const int ShapeXLarge = 40;

        private static readonly Dictionary<int, Sprite> RoundedCache = new Dictionary<int, Sprite>();

        /// <summary>
        /// A white rounded-rectangle sprite, nine-sliced so one small texture
        /// stretches to any size. uGUI has no corner radius of its own, and a
        /// square button is the single biggest reason the player looked nothing
        /// like the browser client.
        /// </summary>
        public static Sprite RoundedSprite(int radius)
        {
            radius = Mathf.Max(1, radius);
            if (RoundedCache.TryGetValue(radius, out var cached) && cached != null) return cached;

            var size = radius * 2 + 2;
            var texture = new Texture2D(size, size, TextureFormat.RGBA32, false)
            {
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp,
                hideFlags = HideFlags.HideAndDontSave,
            };

            var pixels = new Color32[size * size];
            for (var y = 0; y < size; y++)
            {
                for (var x = 0; x < size; x++)
                {
                    // Only the four corner squares are rounded; the straight
                    // edges stay fully opaque, or the nine-slice would fade the
                    // sides of every button.
                    var lowX = x < radius;
                    var highX = x > size - 1 - radius;
                    var lowY = y < radius;
                    var highY = y > size - 1 - radius;

                    var alpha = 1f;
                    if ((lowX || highX) && (lowY || highY))
                    {
                        var cx = lowX ? radius : size - 1 - radius;
                        var cy = lowY ? radius : size - 1 - radius;
                        var dx = x - cx;
                        var dy = y - cy;
                        // Half a pixel of ramp, so the curve reads smooth
                        // rather than stepped.
                        alpha = Mathf.Clamp01(radius - Mathf.Sqrt(dx * dx + dy * dy) + 0.5f);
                    }

                    pixels[y * size + x] = new Color32(255, 255, 255, (byte)(alpha * 255f));
                }
            }

            texture.SetPixels32(pixels);
            texture.Apply();

            var sprite = Sprite.Create(texture, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f),
                100f, 0, SpriteMeshType.FullRect, new Vector4(radius, radius, radius, radius));
            sprite.hideFlags = HideFlags.HideAndDontSave;
            RoundedCache[radius] = sprite;
            return sprite;
        }

        private static readonly Dictionary<char, Sprite> SuitCache = new Dictionary<char, Sprite>();

        /// <summary>
        /// A suit pip, drawn into a texture rather than typed as a character.
        ///
        /// The engine's built-in font has no glyphs for U+2660..2666 on Android,
        /// so a card rendered with "\u2660" came out blank on a phone while
        /// looking fine in the editor. Generating the shape sidesteps the font
        /// entirely, and costs four small textures for the life of the app.
        /// </summary>
        public static Sprite SuitSprite(char suit)
        {
            if (SuitCache.TryGetValue(suit, out var cached) && cached != null) return cached;

            const int size = 128;
            const int samples = 2; // 2x2 supersampling, so the curves are smooth

            var texture = new Texture2D(size, size, TextureFormat.RGBA32, false)
            {
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp,
                hideFlags = HideFlags.HideAndDontSave,
            };

            var pixels = new Color32[size * size];
            for (var y = 0; y < size; y++)
            {
                for (var x = 0; x < size; x++)
                {
                    var hits = 0;
                    for (var sy = 0; sy < samples; sy++)
                    {
                        for (var sx = 0; sx < samples; sx++)
                        {
                            var u = (x + (sx + 0.5f) / samples) / size * 2f - 1f;
                            var v = 1f - (y + (sy + 0.5f) / samples) / size * 2f;
                            if (InSuit(suit, u, v)) hits++;
                        }
                    }

                    var alpha = (byte)(255f * hits / (samples * samples));
                    pixels[y * size + x] = new Color32(255, 255, 255, alpha);
                }
            }

            texture.SetPixels32(pixels);
            texture.Apply();

            var sprite = Sprite.Create(texture, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f));
            sprite.hideFlags = HideFlags.HideAndDontSave;
            SuitCache[suit] = sprite;
            return sprite;
        }

        /// <summary>Is this point inside the pip? Coordinates run -1..1, y up.</summary>
        private static bool InSuit(char suit, float u, float v)
        {
            switch (suit)
            {
                case 'd':
                    return Mathf.Abs(u) * 1.18f + Mathf.Abs(v) * 0.95f <= 0.92f;

                case 'h':
                    return InHeart(u, v);

                case 's':
                    // A heart upside down, standing on a flared stem.
                    return InHeart(u, -v) || InStem(u, v);

                case 'c':
                    return InCircle(u, v - 0.42f, 0.42f)
                           || InCircle(u + 0.45f, v + 0.06f, 0.42f)
                           || InCircle(u - 0.45f, v + 0.06f, 0.42f)
                           || InStem(u, v);

                default:
                    return false;
            }
        }

        private static bool InCircle(float u, float v, float r) => u * u + v * v <= r * r;

        /// <summary>The classic implicit heart, scaled to fill the tile.</summary>
        private static bool InHeart(float u, float v)
        {
            var a = u * 1.35f;
            var b = v * 1.25f - 0.28f;
            var f = a * a + b * b - 1f;
            return f * f * f - a * a * b * b * b <= 0f;
        }

        /// <summary>The flared foot under a spade or a club.</summary>
        private static bool InStem(float u, float v)
        {
            if (v < -0.92f || v > -0.05f) return false;
            var flare = 0.07f + (-v - 0.05f) * 0.52f;
            return Mathf.Abs(u) <= flare;
        }

        private static Sprite _cardBack;
        private static bool _cardBackLooked;

        /// <summary>
        /// The back of a playing card, from Resources/card_back. Loaded once and
        /// null if the artwork is missing, so the game still runs (with a plain
        /// coloured back) on a project that has not been given the image.
        /// </summary>
        public static Sprite CardBack
        {
            get
            {
                if (_cardBackLooked) return _cardBack;
                _cardBackLooked = true;

                var texture = Resources.Load<Texture2D>("card_back");
                if (texture == null)
                {
                    Debug.LogWarning("[UI] Resources/card_back not found; using a plain card back.");
                    return null;
                }

                _cardBack = Sprite.Create(texture, new Rect(0, 0, texture.width, texture.height),
                    new Vector2(0.5f, 0.5f));
                _cardBack.hideFlags = HideFlags.HideAndDontSave;
                return _cardBack;
            }
        }

        /// <summary>
        /// Turns an image into a face-down card. The artwork keeps its own
        /// proportions rather than stretching to the slot: an ornate back looks
        /// obviously wrong the moment it is squashed.
        /// </summary>
        public static void ApplyCardBack(Image image, float alpha = 1f)
        {
            if (image == null) return;

            var sprite = CardBack;
            if (sprite == null) return;

            image.sprite = sprite;
            image.type = Image.Type.Simple;
            image.preserveAspect = true;
            image.color = new Color(1f, 1f, 1f, alpha);
        }

        /// <summary>A rounded block of colour — the basis of cards and buttons.</summary>
        public static Image CreateRounded(string name, Transform parent, Color color, int radius)
        {
            var image = CreateImage(name, parent, color);
            image.sprite = RoundedSprite(radius);
            image.type = Image.Type.Sliced;
            return image;
        }

        /// <summary>
        /// The window the whole game lives in: a full-bleed page in the surface
        /// colour, with one centred elevated card on top. Returns the card, and
        /// every screen parents its content to it.
        /// </summary>
        public static RectTransform CreateAppCard(string name, Transform parent)
        {
            var page = CreatePanel(name + "Page", parent, Scheme.Surface);
            var card = CreateRounded(name, page, Scheme.Surface1, ShapeXLarge).rectTransform;
            card.anchorMin = new Vector2(0.5f, 0.5f);
            card.anchorMax = new Vector2(0.5f, 0.5f);
            card.sizeDelta = new Vector2(AppWidth, AppHeight);
            card.anchoredPosition = Vector2.zero;
            return card;
        }

        /// <summary>
        /// A sideways-scrolling rail. The lobby is a row of cards rather than a
        /// tall list precisely so a phone never has to scroll down; the returned
        /// transform is the row every card is parented to.
        /// </summary>
        public static RectTransform CreateHScroll(string name, Transform parent, float spacing = 24f)
        {
            var viewport = CreateRect(name, parent);
            var scroll = viewport.gameObject.AddComponent<ScrollRect>();
            var mask = viewport.gameObject.AddComponent<RectMask2D>();
            mask.enabled = true;

            var content = CreateRect(name + "Content", viewport);
            content.anchorMin = new Vector2(0f, 0f);
            content.anchorMax = new Vector2(0f, 1f);
            content.pivot = new Vector2(0f, 0.5f);
            content.sizeDelta = new Vector2(0f, 0f);

            var row = content.gameObject.AddComponent<HorizontalLayoutGroup>();
            row.spacing = spacing;
            row.childControlWidth = true;
            row.childControlHeight = true;
            row.childForceExpandWidth = false;
            row.childForceExpandHeight = true;
            row.childAlignment = TextAnchor.MiddleLeft;

            var fitter = content.gameObject.AddComponent<ContentSizeFitter>();
            fitter.horizontalFit = ContentSizeFitter.FitMode.PreferredSize;
            fitter.verticalFit = ContentSizeFitter.FitMode.Unconstrained;

            scroll.content = content;
            scroll.viewport = viewport;
            scroll.horizontal = true;
            scroll.vertical = false;
            scroll.movementType = ScrollRect.MovementType.Elastic;
            scroll.elasticity = 0.08f;
            scroll.scrollSensitivity = 30f;
            scroll.inertia = true;

            return content;
        }

        /// <summary>A small rounded label — M3's assist chip.</summary>
        public static Text CreateChip(string name, Transform parent, string label,
            Color background, Color foreground, int fontSize = 22)
        {
            var chip = CreateRounded(name, parent, background, ShapeSmall);
            var text = CreateText(name + "Text", chip.transform, label, fontSize,
                TextAnchor.MiddleCenter, foreground, FontStyle.Bold);
            Stretch(text.rectTransform, 4f);
            return text;
        }

        /// <summary>Anchors a rect to a centred <see cref="AppWidth"/> column.</summary>
        public static void AnchorCentered(RectTransform rect, float yMin, float yMax, float width = AppWidth)
        {
            rect.anchorMin = new Vector2(0.5f, yMin);
            rect.anchorMax = new Vector2(0.5f, yMax);
            rect.offsetMin = new Vector2(-width / 2f, 0f);
            rect.offsetMax = new Vector2(width / 2f, 0f);
        }

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
            // Requirement 23: the game runs in landscape, so the reference is a
            // wide phone. Matching on height keeps the table the same size
            // whatever the aspect ratio, which varies wildly across handsets.
            scaler.referenceResolution = new Vector2(1920, 1080);
            scaler.matchWidthOrHeight = 1f;

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
            // Container and "on container" are a matched pair, so they have to
            // default together. Defaulting only the fill is what left dark
            // labels sitting on dark buttons once day mode became the default.
            image.color = background ?? Tonal;
            image.sprite = RoundedSprite(ShapeLarge);
            image.type = Image.Type.Sliced;

            var button = go.GetComponent<Button>();
            button.targetGraphic = image;
            if (onClick != null) button.onClick.AddListener(() => onClick());

            var text = CreateText("Label", go.transform, label, fontSize, TextAnchor.MiddleCenter,
                textColor ?? (background.HasValue ? Ink : OnTonal), FontStyle.Bold);
            Stretch(text.rectTransform, 6f);

            return button;
        }

        public static InputField CreateInput(string name, Transform parent, string placeholder, int fontSize = 30)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(InputField));
            go.GetComponent<RectTransform>().SetParent(parent, false);
            var fieldImage = go.GetComponent<Image>();
            fieldImage.color = Field;
            fieldImage.sprite = RoundedSprite(ShapeSmall);
            fieldImage.type = Image.Type.Sliced;

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
            // Buttons are pills, so their corner radius follows their height.
            // The height arrives after the button is built, which is why this
            // lives here rather than in CreateButton.
            if (go.GetComponent<Button>() != null)
            {
                var fill = go.GetComponent<Image>();
                if (fill != null) fill.sprite = RoundedSprite(Mathf.RoundToInt(height / 2f));
            }

            var element = go.GetComponent<LayoutElement>() ?? go.AddComponent<LayoutElement>();
            element.preferredHeight = height;
            element.minHeight = height;
            return element;
        }
    }
}
