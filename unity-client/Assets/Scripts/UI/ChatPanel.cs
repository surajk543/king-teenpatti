using System;
using System.Collections.Generic;
using System.Text;
using KingTeenPatti.Models;
using UnityEngine;
using UnityEngine.UI;

namespace KingTeenPatti.UI
{
    /// <summary>
    /// The table chat: a toggle button with an unread badge, and a sliding
    /// panel with the room backlog and a message box.
    ///
    /// The panel is a pure mirror of what the server sends. Chat is scoped to
    /// one room and held only in server memory, so nothing is cached across
    /// rooms or app launches — <see cref="Clear"/> is called on every join and
    /// leave.
    /// </summary>
    public class ChatPanel
    {
        /// <summary>Matches the server's per-room cap.</summary>
        private const int MaxMessages = 100;

        private readonly List<ChatMessageDto> _messages = new List<ChatMessageDto>();

        private RectTransform _panel;
        private Button _toggleButton;
        private Text _toggleBadge;
        private Text _messageText;
        private ScrollRect _scroll;
        private InputField _input;
        private Text _error;

        private string _myUserId;
        private int _unread;
        private bool _open;

        /// <summary>Raised when the player sends a message.</summary>
        public event Action<string> MessageSubmitted;

        public bool IsOpen => _open;

        public void Build(Transform parent)
        {
            BuildToggle(parent);
            BuildPanel(parent);
            SetOpen(false);
        }

        private void BuildToggle(Transform parent)
        {
            _toggleButton = UiFactory.CreateButton("ChatToggle", parent, "CHAT", () => SetOpen(!_open),
                new Color(0.09f, 0.18f, 0.13f), UiFactory.Ink, 26);
            UiFactory.Anchor(_toggleButton.GetComponent<RectTransform>(),
                new Vector2(0.74f, 0.94f), new Vector2(0.97f, 0.985f), Vector2.zero, Vector2.zero);

            // Unread count, tucked into the corner of the button.
            var badge = UiFactory.CreateImage("Badge", _toggleButton.transform, UiFactory.Danger);
            UiFactory.Anchor(badge.rectTransform, new Vector2(0.78f, 0.55f), new Vector2(1.06f, 1.25f),
                Vector2.zero, Vector2.zero);

            _toggleBadge = UiFactory.CreateText("Count", badge.transform, "0", 20,
                TextAnchor.MiddleCenter, Color.white, FontStyle.Bold);
            UiFactory.Stretch(_toggleBadge.rectTransform);

            badge.gameObject.SetActive(false);
        }

        private void BuildPanel(Transform parent)
        {
            _panel = UiFactory.CreatePanel("ChatPanel", parent, new Color(0.05f, 0.11f, 0.08f, 0.98f));
            UiFactory.Anchor(_panel, new Vector2(0.04f, 0.16f), new Vector2(0.96f, 0.92f),
                Vector2.zero, Vector2.zero);

            var title = UiFactory.CreateText("Title", _panel, "TABLE CHAT", 30,
                TextAnchor.MiddleLeft, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(title.rectTransform, new Vector2(0.04f, 0.93f), new Vector2(0.7f, 0.99f),
                Vector2.zero, Vector2.zero);

            var subtitle = UiFactory.CreateText("Subtitle", _panel, "only players at this table", 20,
                TextAnchor.MiddleLeft, UiFactory.Muted);
            UiFactory.Anchor(subtitle.rectTransform, new Vector2(0.04f, 0.89f), new Vector2(0.7f, 0.94f),
                Vector2.zero, Vector2.zero);

            var close = UiFactory.CreateButton("Close", _panel, "X", () => SetOpen(false),
                new Color(0.16f, 0.10f, 0.10f), UiFactory.Muted, 28);
            UiFactory.Anchor(close.GetComponent<RectTransform>(), new Vector2(0.84f, 0.90f),
                new Vector2(0.97f, 0.985f), Vector2.zero, Vector2.zero);

            // Scrolling message list. A single Text is used rather than one
            // object per line: the log is capped at 100 short messages, so this
            // is far cheaper than instantiating and pooling a hundred rows.
            var viewport = UiFactory.CreateImage("Viewport", _panel, new Color(0, 0, 0, 0.25f));
            UiFactory.Anchor(viewport.rectTransform, new Vector2(0.04f, 0.16f), new Vector2(0.96f, 0.88f),
                Vector2.zero, Vector2.zero);
            viewport.gameObject.AddComponent<Mask>().showMaskGraphic = true;

            _scroll = viewport.gameObject.AddComponent<ScrollRect>();
            _scroll.horizontal = false;
            _scroll.vertical = true;
            _scroll.movementType = ScrollRect.MovementType.Clamped;
            _scroll.scrollSensitivity = 32f;

            var content = UiFactory.CreateRect("Content", viewport.transform);
            content.anchorMin = new Vector2(0, 1);
            content.anchorMax = new Vector2(1, 1);
            content.pivot = new Vector2(0.5f, 1f);
            content.offsetMin = new Vector2(12, 0);
            content.offsetMax = new Vector2(-12, 0);

            _messageText = UiFactory.CreateText("Messages", content, string.Empty, 24,
                TextAnchor.UpperLeft, UiFactory.Ink);
            _messageText.rectTransform.anchorMin = new Vector2(0, 1);
            _messageText.rectTransform.anchorMax = new Vector2(1, 1);
            _messageText.rectTransform.pivot = new Vector2(0.5f, 1f);
            _messageText.rectTransform.offsetMin = Vector2.zero;
            _messageText.rectTransform.offsetMax = Vector2.zero;
            _messageText.verticalOverflow = VerticalWrapMode.Overflow;

            // Grow the content box to fit the text so scrolling has somewhere to go.
            var fitter = content.gameObject.AddComponent<ContentSizeFitter>();
            fitter.verticalFit = ContentSizeFitter.FitMode.PreferredSize;
            var layout = content.gameObject.AddComponent<VerticalLayoutGroup>();
            layout.childControlHeight = true;
            layout.childControlWidth = true;
            layout.childForceExpandHeight = false;
            layout.childForceExpandWidth = true;
            layout.padding = new RectOffset(0, 0, 8, 8);

            _scroll.content = content;
            _scroll.viewport = viewport.rectTransform;

            _input = UiFactory.CreateInput("ChatInput", _panel, "Say something…", 26);
            UiFactory.Anchor(_input.GetComponent<RectTransform>(), new Vector2(0.04f, 0.055f),
                new Vector2(0.72f, 0.145f), Vector2.zero, Vector2.zero);
            _input.characterLimit = 140;
            _input.onEndEdit.AddListener(text =>
            {
                // Enter sends on desktop; the Send button covers touch.
                if (Input.GetKeyDown(KeyCode.Return) || Input.GetKeyDown(KeyCode.KeypadEnter)) Submit();
            });

            var send = UiFactory.CreateButton("Send", _panel, "SEND", Submit,
                UiFactory.Gold, new Color(0.11f, 0.08f, 0.01f), 26);
            UiFactory.Anchor(send.GetComponent<RectTransform>(), new Vector2(0.74f, 0.055f),
                new Vector2(0.96f, 0.145f), Vector2.zero, Vector2.zero);

            _error = UiFactory.CreateText("ChatError", _panel, string.Empty, 20,
                TextAnchor.MiddleLeft, UiFactory.Danger);
            UiFactory.Anchor(_error.rectTransform, new Vector2(0.04f, 0.005f), new Vector2(0.96f, 0.05f),
                Vector2.zero, Vector2.zero);
        }

        private void Submit()
        {
            var text = (_input.text ?? string.Empty).Trim();
            if (text.Length == 0) return;

            MessageSubmitted?.Invoke(text);
            _input.text = string.Empty;
            _input.ActivateInputField();
        }

        // ------------------------------------------------------------- state

        public void SetLocalUser(string userId) => _myUserId = userId;

        public void SetOpen(bool open)
        {
            _open = open;
            _panel.gameObject.SetActive(open);
            _toggleButton.gameObject.SetActive(!open);

            if (!open) return;
            _unread = 0;
            UpdateBadge();
            Render();
        }

        /// <summary>Shows the panel and toggle only while the player is at a table.</summary>
        public void SetVisible(bool visible)
        {
            _toggleButton.gameObject.SetActive(visible && !_open);
            _panel.gameObject.SetActive(visible && _open);
        }

        /// <summary>Replaces the log with the room backlog sent on join.</summary>
        public void SetHistory(ChatMessageDto[] messages)
        {
            _messages.Clear();
            if (messages != null) _messages.AddRange(messages);
            Trim();
            Render();
        }

        public void Append(ChatMessageDto message)
        {
            if (message == null) return;

            _messages.Add(message);
            Trim();
            Render();

            if (!_open && !message.system)
            {
                _unread++;
                UpdateBadge();
            }
        }

        /// <summary>Drops everything — called on join and on leave.</summary>
        public void Clear()
        {
            _messages.Clear();
            _unread = 0;
            UpdateBadge();
            Render();
        }

        public void SetError(string message)
        {
            if (_error != null) _error.text = message ?? string.Empty;
        }

        private void Trim()
        {
            if (_messages.Count > MaxMessages) _messages.RemoveRange(0, _messages.Count - MaxMessages);
        }

        private void UpdateBadge()
        {
            var badge = _toggleBadge.transform.parent.gameObject;
            badge.SetActive(_unread > 0);
            _toggleBadge.text = _unread > 9 ? "9+" : _unread.ToString();
        }

        private void Render()
        {
            if (_messageText == null) return;

            if (_messages.Count == 0)
            {
                _messageText.text = "<color=#8FA69B>No messages yet. Say hello.</color>";
                return;
            }

            var builder = new StringBuilder();
            foreach (var message in _messages)
            {
                if (message.system)
                {
                    builder.Append("<color=#8FA69B><i>").Append(Sanitize(message.text)).AppendLine("</i></color>");
                    continue;
                }

                var mine = !string.IsNullOrEmpty(_myUserId) && message.userId == _myUserId;
                var author = mine ? "You" : Sanitize(message.displayName);
                var color = mine ? "#4FBF7F" : "#E8C46A";

                builder.Append("<color=").Append(color).Append("><b>").Append(author).Append(":</b></color> ")
                    .AppendLine(Sanitize(message.text));
            }

            _messageText.text = builder.ToString();
            _messageText.supportRichText = true;

            // Jump to the newest message.
            Canvas.ForceUpdateCanvases();
            if (_scroll != null) _scroll.verticalNormalizedPosition = 0f;
        }

        /// <summary>
        /// The server already strips control characters, but a display name or
        /// message is still player-supplied text being poured into a rich-text
        /// label — neutralise the markup so nobody can inject colour tags.
        /// </summary>
        private static string Sanitize(string text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            return text.Replace("<", "‹").Replace(">", "›");
        }
    }
}
