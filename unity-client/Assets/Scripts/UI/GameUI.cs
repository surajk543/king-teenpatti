using System;
using System.Collections.Generic;
using System.Text;
using KingTeenPatti.Game;
using KingTeenPatti.Models;
using UnityEngine;
using UnityEngine.UI;

namespace KingTeenPatti.UI
{
    /// <summary>
    /// Builds and drives the whole interface: login, lobby and table.
    ///
    /// It is a pure view — it raises callbacks for player intent and renders
    /// whatever state it is handed. All game rules live on the server, so this
    /// class never decides what is legal; it only shows the options the server
    /// sent with <c>game:yourTurn</c>.
    /// </summary>
    public class GameUI
    {
        private const int MaxSeats = 5;
        private const int LogLines = 8;

        // Screens
        private RectTransform _loginPanel;
        private RectTransform _lobbyPanel;
        private RectTransform _tablePanel;

        // Login
        private InputField _nameInput;
        private Text _loginError;
        private Button _guestButton;
        private Button _googleButton;
        private Button _facebookButton;

        // Lobby
        private Text _lobbyName;
        private Text _lobbyChips;
        private Text _lobbyError;
        private InputField _codeInput;
        private Text _bootLabel;
        /// <summary>Stakes the lobby offers; replaced by the server's list on connect.</summary>
        private long[] _bootChoices = { 200, 5000 };
        private int _bootIndex;
        private Button _seenButton;
        private Button _blindButton;
        private Text _categoryHint;
        /// <summary>"seen" shows every stack; "blind" shows only your own.</summary>
        private string _category = TableCategory.Seen;

        // Table
        private Text _tableCode;
        private Text _potText;
        private Text _stakeText;
        private Text _statusText;
        private Text _myChipsText;
        private Image _timerFill;
        private readonly SeatView[] _seatViews = new SeatView[MaxSeats];
        private readonly CardView[] _cardViews = new CardView[3];
        private readonly List<Button> _actionButtons = new List<Button>();
        private RectTransform _actionRow;
        private Text _logText;
        private readonly Queue<string> _log = new Queue<string>();

        /// <summary>Room chat. Only shown while the player is at a table.</summary>
        public ChatPanel Chat { get; } = new ChatPanel();

        private float _turnDeadline;
        private float _turnTotalSeconds = 25f;

        /// <summary>Which rung of the bet ladder the +/- stepper sits on. 0 = plain chaal.</summary>
        private int _raiseIndex;
        private TurnOptionsDto _options;

        // Player intent, wired up by GameClient.
        public event Action<string> GuestLoginRequested;
        public event Action GoogleLoginRequested;
        public event Action FacebookLoginRequested;
        public event Action<long, string> QuickJoinRequested;
        public event Action<long, string> CreateTableRequested;
        public event Action<string> JoinCodeRequested;
        public event Action LeaveRequested;
        public event Action<string> ActionRequested;
        /// <summary>Raised with the exact amount picked on the stepper.</summary>
        public event Action<string, long> BetRequested;

        public long SelectedBoot => _bootChoices[Mathf.Clamp(_bootIndex, 0, _bootChoices.Length - 1)];

        /// <summary>The Blind/Seen category currently picked in the lobby.</summary>
        public string SelectedCategory => _category;

        // ------------------------------------------------------------- build

        public void Build(Transform canvas)
        {
            BuildLogin(canvas);
            BuildLobby(canvas);
            BuildTable(canvas);
            // Built last so the chat panel draws over the table.
            Chat.Build(_tablePanel);
            ShowLogin();
        }

        private void BuildLogin(Transform canvas)
        {
            _loginPanel = UiFactory.CreatePanel("LoginPanel", canvas, UiFactory.FeltDark);

            var title = UiFactory.CreateText("Title", _loginPanel, "KING TEEN PATTI", 72,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(title.rectTransform, new Vector2(0, 0.78f), new Vector2(1, 0.9f),
                Vector2.zero, Vector2.zero);

            var column = UiFactory.CreateColumn("Column", _loginPanel, 22f, new RectOffset(80, 80, 0, 0));
            UiFactory.Anchor((RectTransform)column.transform, new Vector2(0, 0.30f), new Vector2(1, 0.72f),
                Vector2.zero, Vector2.zero);

            _nameInput = UiFactory.CreateInput("NameInput", column.transform, "Display name");
            UiFactory.SetHeight(_nameInput.gameObject, 96);
            _nameInput.characterLimit = 24;

            _guestButton = UiFactory.CreateButton("GuestButton", column.transform, "PLAY AS GUEST",
                () => GuestLoginRequested?.Invoke(_nameInput.text),
                UiFactory.Gold, new Color(0.11f, 0.08f, 0.01f));
            UiFactory.SetHeight(_guestButton.gameObject, 110);

            _googleButton = UiFactory.CreateButton("GoogleButton", column.transform, "CONTINUE WITH GOOGLE",
                () => GoogleLoginRequested?.Invoke());
            UiFactory.SetHeight(_googleButton.gameObject, 110);

            _facebookButton = UiFactory.CreateButton("FacebookButton", column.transform, "CONTINUE WITH FACEBOOK",
                () => FacebookLoginRequested?.Invoke());
            UiFactory.SetHeight(_facebookButton.gameObject, 110);

            _loginError = UiFactory.CreateText("Error", column.transform, string.Empty, 26,
                TextAnchor.MiddleCenter, UiFactory.Danger);
            UiFactory.SetHeight(_loginError.gameObject, 90);
        }

        private void BuildLobby(Transform canvas)
        {
            _lobbyPanel = UiFactory.CreatePanel("LobbyPanel", canvas, UiFactory.FeltDark);

            _lobbyName = UiFactory.CreateText("Name", _lobbyPanel, string.Empty, 38,
                TextAnchor.MiddleLeft, UiFactory.Ink, FontStyle.Bold);
            UiFactory.Anchor(_lobbyName.rectTransform, new Vector2(0, 0.90f), new Vector2(0.6f, 0.96f),
                new Vector2(50, 0), Vector2.zero);

            _lobbyChips = UiFactory.CreateText("Chips", _lobbyPanel, string.Empty, 38,
                TextAnchor.MiddleRight, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_lobbyChips.rectTransform, new Vector2(0.5f, 0.90f), new Vector2(1, 0.96f),
                Vector2.zero, new Vector2(-50, 0));

            var column = UiFactory.CreateColumn("Column", _lobbyPanel, 20f, new RectOffset(80, 80, 0, 0));
            UiFactory.Anchor((RectTransform)column.transform, new Vector2(0, 0.30f), new Vector2(1, 0.86f),
                Vector2.zero, Vector2.zero);

            // Category picker. This decides whether every player's chip stack is
            // visible at the table, or only your own.
            var categoryRow = UiFactory.CreateRow("CategoryRow", column.transform);
            UiFactory.SetHeight(categoryRow.gameObject, 100);

            _seenButton = UiFactory.CreateButton("SeenBtn", categoryRow.transform, "SEEN",
                () => SetCategory(TableCategory.Seen), UiFactory.Gold, new Color(0.11f, 0.08f, 0.01f), 28);
            _blindButton = UiFactory.CreateButton("BlindBtn", categoryRow.transform, "BLIND",
                () => SetCategory(TableCategory.Blind));

            _categoryHint = UiFactory.CreateText("CategoryHint", column.transform, string.Empty, 22,
                TextAnchor.MiddleCenter, UiFactory.Muted);
            UiFactory.SetHeight(_categoryHint.gameObject, 46);

            // Boot amount stepper — the stake the table is played for.
            var bootRow = UiFactory.CreateRow("BootRow", column.transform);
            UiFactory.SetHeight(bootRow.gameObject, 100);

            UiFactory.CreateButton("BootDown", bootRow.transform, "-", () => CycleBoot(-1));
            _bootLabel = UiFactory.CreateText("BootLabel", bootRow.transform, string.Empty, 34,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.CreateButton("BootUp", bootRow.transform, "+", () => CycleBoot(1));
            UpdateBootLabel();
            SetCategory(TableCategory.Seen);

            var quick = UiFactory.CreateButton("QuickJoin", column.transform, "QUICK JOIN",
                () => QuickJoinRequested?.Invoke(SelectedBoot, _category),
                UiFactory.Gold, new Color(0.11f, 0.08f, 0.01f));
            UiFactory.SetHeight(quick.gameObject, 120);

            var create = UiFactory.CreateButton("CreateTable", column.transform, "CREATE PRIVATE TABLE",
                () => CreateTableRequested?.Invoke(SelectedBoot, _category));
            UiFactory.SetHeight(create.gameObject, 100);

            _codeInput = UiFactory.CreateInput("CodeInput", column.transform, "Table code");
            UiFactory.SetHeight(_codeInput.gameObject, 96);
            _codeInput.characterLimit = 6;

            var joinCode = UiFactory.CreateButton("JoinCode", column.transform, "JOIN BY CODE",
                () => JoinCodeRequested?.Invoke((_codeInput.text ?? string.Empty).Trim().ToUpperInvariant()));
            UiFactory.SetHeight(joinCode.gameObject, 100);

            _lobbyError = UiFactory.CreateText("Error", column.transform, string.Empty, 26,
                TextAnchor.MiddleCenter, UiFactory.Danger);
            UiFactory.SetHeight(_lobbyError.gameObject, 80);
        }

        private void BuildTable(Transform canvas)
        {
            _tablePanel = UiFactory.CreatePanel("TablePanel", canvas, UiFactory.FeltDark);

            // --- top bar
            var leave = UiFactory.CreateButton("Leave", _tablePanel, "LEAVE", () => LeaveRequested?.Invoke(),
                new Color(0.14f, 0.09f, 0.09f), UiFactory.Muted, 26);
            UiFactory.Anchor(leave.GetComponent<RectTransform>(), new Vector2(0, 0.94f),
                new Vector2(0.22f, 0.985f), new Vector2(24, 0), Vector2.zero);

            _tableCode = UiFactory.CreateText("Code", _tablePanel, string.Empty, 30,
                TextAnchor.MiddleCenter, UiFactory.Muted);
            UiFactory.Anchor(_tableCode.rectTransform, new Vector2(0.22f, 0.94f), new Vector2(0.72f, 0.985f),
                Vector2.zero, Vector2.zero);

            _myChipsText = UiFactory.CreateText("MyChips", _tablePanel, string.Empty, 32,
                TextAnchor.MiddleRight, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_myChipsText.rectTransform, new Vector2(0.68f, 0.94f), new Vector2(1, 0.985f),
                Vector2.zero, new Vector2(-24, 0));

            // --- felt
            var felt = UiFactory.CreateImage("Felt", _tablePanel, UiFactory.Felt);
            UiFactory.Anchor(felt.rectTransform, new Vector2(0.02f, 0.46f), new Vector2(0.98f, 0.93f),
                Vector2.zero, Vector2.zero);

            var potLabel = UiFactory.CreateText("PotLabel", felt.transform, "POT", 24,
                TextAnchor.MiddleCenter, UiFactory.Muted);
            UiFactory.Anchor(potLabel.rectTransform, new Vector2(0, 0.82f), new Vector2(1, 0.92f),
                Vector2.zero, Vector2.zero);

            _potText = UiFactory.CreateText("Pot", felt.transform, "0", 64,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_potText.rectTransform, new Vector2(0, 0.66f), new Vector2(1, 0.84f),
                Vector2.zero, Vector2.zero);

            _stakeText = UiFactory.CreateText("Stake", felt.transform, string.Empty, 24,
                TextAnchor.MiddleCenter, UiFactory.Muted);
            UiFactory.Anchor(_stakeText.rectTransform, new Vector2(0, 0.58f), new Vector2(1, 0.67f),
                Vector2.zero, Vector2.zero);

            // Five seats across the felt.
            for (var i = 0; i < MaxSeats; i++)
            {
                var min = new Vector2(0.02f + i * 0.196f, 0.16f);
                var max = new Vector2(0.02f + i * 0.196f + 0.176f, 0.55f);
                _seatViews[i] = SeatView.Create(felt.transform, i, min, max);
            }

            _statusText = UiFactory.CreateText("Status", felt.transform, string.Empty, 30,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_statusText.rectTransform, new Vector2(0, 0.02f), new Vector2(1, 0.15f),
                Vector2.zero, Vector2.zero);

            // --- own hand
            for (var i = 0; i < 3; i++)
            {
                var min = new Vector2(0.26f + i * 0.17f, 0.30f);
                var max = new Vector2(0.26f + i * 0.17f + 0.15f, 0.44f);
                _cardViews[i] = CardView.Create(_tablePanel, min, max);
            }

            // --- turn clock
            var timerBack = UiFactory.CreateImage("TimerBack", _tablePanel, new Color(1, 1, 1, 0.12f));
            UiFactory.Anchor(timerBack.rectTransform, new Vector2(0.06f, 0.265f), new Vector2(0.94f, 0.28f),
                Vector2.zero, Vector2.zero);

            _timerFill = UiFactory.CreateImage("TimerFill", timerBack.transform, UiFactory.Gold);
            _timerFill.rectTransform.anchorMin = Vector2.zero;
            _timerFill.rectTransform.anchorMax = Vector2.one;
            _timerFill.rectTransform.offsetMin = Vector2.zero;
            _timerFill.rectTransform.offsetMax = Vector2.zero;
            _timerFill.type = Image.Type.Filled;
            _timerFill.fillMethod = Image.FillMethod.Horizontal;
            _timerFill.fillAmount = 0f;

            // --- action buttons
            _actionRow = UiFactory.CreateRect("Actions", _tablePanel);
            var row = _actionRow.gameObject.AddComponent<HorizontalLayoutGroup>();
            row.spacing = 12f;
            row.childControlWidth = true;
            row.childControlHeight = true;
            row.childForceExpandWidth = true;
            row.childForceExpandHeight = true;
            UiFactory.Anchor(_actionRow, new Vector2(0.03f, 0.15f), new Vector2(0.97f, 0.25f),
                Vector2.zero, Vector2.zero);

            // --- event log
            _logText = UiFactory.CreateText("Log", _tablePanel, string.Empty, 24,
                TextAnchor.LowerLeft, UiFactory.Muted);
            UiFactory.Anchor(_logText.rectTransform, new Vector2(0.04f, 0.01f), new Vector2(0.96f, 0.14f),
                Vector2.zero, Vector2.zero);
        }

        private void CycleBoot(int direction)
        {
            _bootIndex = Mathf.Clamp(_bootIndex + direction, 0, _bootChoices.Length - 1);
            UpdateBootLabel();
        }

        private void UpdateBootLabel() => _bootLabel.text = "Boot  " + SelectedBoot.ToString("N0");

        private void SetCategory(string category)
        {
            _category = category == TableCategory.Blind ? TableCategory.Blind : TableCategory.Seen;
            var blind = _category == TableCategory.Blind;

            Tint(_seenButton, !blind);
            Tint(_blindButton, blind);

            _categoryHint.text = blind
                ? "Blind: you see only your own chips"
                : "Seen: everyone's chips are visible";
        }

        private static void Tint(Button button, bool selected)
        {
            if (button == null) return;

            var image = button.targetGraphic as Image;
            if (image != null)
            {
                image.color = selected ? UiFactory.Gold : new Color(0.10f, 0.20f, 0.15f);
            }

            var label = button.GetComponentInChildren<Text>();
            if (label != null)
            {
                label.color = selected ? new Color(0.11f, 0.08f, 0.01f) : UiFactory.Ink;
            }
        }

        /// <summary>Replaces the lobby's stake list with the one the server offers.</summary>
        public void SetLobbyOptions(GameConfigDto config)
        {
            if (config?.stakes == null || config.stakes.Length == 0) return;
            _bootChoices = config.stakes;
            _bootIndex = 0;
            UpdateBootLabel();
        }

        // ------------------------------------------------------------ screens

        public void ShowLogin()
        {
            _loginPanel.gameObject.SetActive(true);
            _lobbyPanel.gameObject.SetActive(false);
            _tablePanel.gameObject.SetActive(false);
        }

        public void ShowLobby()
        {
            _loginPanel.gameObject.SetActive(false);
            _lobbyPanel.gameObject.SetActive(true);
            _tablePanel.gameObject.SetActive(false);
            // Leaving the room leaves its chat behind.
            Chat.Clear();
            Chat.SetVisible(false);
        }

        public void ShowTable()
        {
            _loginPanel.gameObject.SetActive(false);
            _lobbyPanel.gameObject.SetActive(false);
            _tablePanel.gameObject.SetActive(true);
            _log.Clear();
            _logText.text = string.Empty;

            // A new room means a new chat log; the server sends its backlog next.
            Chat.Clear();
            Chat.SetOpen(false);
            Chat.SetVisible(true);
        }

        public void SetLoginError(string message) => _loginError.text = message ?? string.Empty;

        public void SetLobbyError(string message) => _lobbyError.text = message ?? string.Empty;

        public void SetLoginBusy(bool busy)
        {
            _guestButton.interactable = !busy;
            _googleButton.interactable = !busy;
            _facebookButton.interactable = !busy;
        }

        public void SetPlayerHeader(UserDto user)
        {
            if (user == null) return;
            _lobbyName.text = user.displayName + "  (" + user.provider + ")";
            _lobbyChips.text = user.chips.ToString("N0");
        }

        // ------------------------------------------------------------ render

        /// <summary>Renders a table snapshot. Everything shown comes from the server.</summary>
        public void RenderRoom(RoomStateDto room, string myUserId)
        {
            if (room == null) return;

            _tableCode.text = "Table " + room.code +
                               "  ·  " + (room.chipsHidden ? "BLIND" : "SEEN") +
                               "  ·  Hand " + room.handNo;
            _potText.text = room.pot.ToString("N0");
            _stakeText.text = "stake " + room.stake.ToString("N0") + "   ·   boot " + room.bootAmount.ToString("N0");
            if (room.turnTimeoutMs > 0) _turnTotalSeconds = room.turnTimeoutMs / 1000f;

            var seated = room.you != null && room.you.IsSeated;
            var turn = room.turn != null && room.turn.HasTurn ? room.turn : null;

            if (seated) _myChipsText.text = room.you.chips.ToString("N0");

            var turnSeat = turn?.seatIndex ?? -1;
            var isBetting = room.state == TableState.Betting;

            for (var i = 0; i < MaxSeats; i++)
            {
                var seat = i < (room.seats?.Length ?? 0) ? room.seats[i] : null;
                _seatViews[i].Render(seat, isBetting && turnSeat == i, i == room.dealerSeat, myUserId,
                    room.chipsHidden);
            }

            // Own cards: face down until this player has seen them.
            var cards = seated ? room.you.cards : null;
            var inHand = seated && room.you.status == SeatState.Active;

            for (var i = 0; i < 3; i++)
            {
                if (!inHand) _cardViews[i].SetHidden();
                else if (cards != null && i < cards.Length) _cardViews[i].SetFace(cards[i]);
                else _cardViews[i].SetBack();
            }

            switch (room.state)
            {
                case TableState.Waiting:
                    SetStatus("Waiting for players (" + room.minPlayers + " needed)");
                    ClearActions();
                    StopTimer();
                    break;
                case TableState.Starting:
                    SetStatus("Starting…");
                    break;
                case TableState.Betting:
                    if (turn != null && turn.userId != myUserId)
                    {
                        SetStatus(NameOfSeat(room, turn.seatIndex) + " to act");
                    }
                    break;
            }

            // The server re-sends the legal options inside the snapshot, which is
            // what restores the buttons after a reconnect mid-turn.
            var myTurn = turn != null && turn.userId == myUserId;
            var options = seated ? room.you.options : null;

            if (myTurn && options != null && options.IsActionable)
            {
                ShowActions(options);
                StartTimer(turn.deadline);
            }
            else if (!myTurn)
            {
                ClearActions();
            }
        }

        private static string NameOfSeat(RoomStateDto room, int seatIndex)
        {
            if (room.seats == null) return "Player";
            foreach (var seat in room.seats)
            {
                if (seat.seatIndex == seatIndex && seat.IsOccupied) return seat.displayName;
            }
            return "Player";
        }

        public void SetStatus(string message) => _statusText.text = message ?? string.Empty;

        public void ShowOwnCards(string[] cards)
        {
            if (cards == null) return;
            for (var i = 0; i < 3 && i < cards.Length; i++) _cardViews[i].SetFace(cards[i]);
        }

        // ----------------------------------------------------------- actions

        /// <summary>
        /// Starts a fresh turn: resets the bet stepper to the plain chaal before
        /// drawing the controls. The ladder is recomputed from the new stake each
        /// turn, so carrying the previous rung over would point at a wrong amount.
        /// </summary>
        public void BeginTurn(TurnOptionsDto options)
        {
            _raiseIndex = 0;
            ShowActions(options);
        }

        /// <summary>
        /// Renders exactly the moves the server said are legal. A bet the player
        /// cannot afford arrives as 0 and is not offered.
        /// </summary>
        public void ShowActions(TurnOptionsDto options)
        {
            ClearActions();
            _options = options;
            if (options == null) return;

            if (options.canSee)
            {
                AddAction("SEE", GameAction.See, new Color(0.16f, 0.28f, 0.22f));
            }

            AddBetControl(options);

            if (options.show > 0)
            {
                AddAction("SHOW\n" + options.show.ToString("N0"), GameAction.Show,
                    new Color(0.20f, 0.34f, 0.50f));
            }

            if (options.canPack)
            {
                AddAction("PACK", GameAction.Pack, new Color(0.28f, 0.13f, 0.12f));
            }
        }

        /// <summary>
        /// The bet control: [ − ][ CHAAL n ][ + ].
        ///
        /// "+" doubles the amount and "−" halves it, walking the ladder the
        /// server sent. The amount lives on the CHAAL button, and that button is
        /// the only thing that places a bet — the steppers just choose how much.
        /// The ladder is already capped to the player's own chips, so "+" simply
        /// runs out of rungs rather than ever offering more than they hold.
        /// </summary>
        private void AddBetControl(TurnOptionsDto options)
        {
            var steps = options.raiseSteps;
            if (steps == null || steps.Length == 0) return;

            _raiseIndex = Mathf.Clamp(_raiseIndex, 0, steps.Length - 1);
            var amount = steps[_raiseIndex];

            var minus = UiFactory.CreateButton("BetDown", _actionRow, "−", () =>
            {
                _raiseIndex = Mathf.Max(0, _raiseIndex - 1);
                ShowActions(_options);
            }, new Color(0.10f, 0.20f, 0.15f), UiFactory.Gold, 34);
            minus.interactable = _raiseIndex > 0;
            _actionButtons.Add(minus);
            SetFlexWidth(minus.gameObject, 0.55f);

            var chaal = UiFactory.CreateButton("BetChaal", _actionRow,
                "CHAAL\n" + amount.ToString("N0"),
                () =>
                {
                    ClearActions();
                    // Anything above the base rung is a raise to the server and
                    // to the hand history, even though it is one button here.
                    var action = amount == steps[0] ? GameAction.Chaal : GameAction.Raise;
                    BetRequested?.Invoke(action, amount);
                },
                UiFactory.Gold, new Color(0.11f, 0.08f, 0.01f), 24);
            _actionButtons.Add(chaal);
            SetFlexWidth(chaal.gameObject, 1.6f);

            var atTop = _raiseIndex >= steps.Length - 1;
            var plus = UiFactory.CreateButton("BetUp", _actionRow, "+", () =>
            {
                _raiseIndex = Mathf.Min(steps.Length - 1, _raiseIndex + 1);
                ShowActions(_options);
            }, new Color(0.10f, 0.20f, 0.15f), UiFactory.Gold, 34);
            plus.interactable = !atTop;
            _actionButtons.Add(plus);
            SetFlexWidth(plus.gameObject, 0.55f);

            // Tell the player why "+" stopped: they have hit their own stack or
            // the table's pot limit.
            if (atTop && steps.Length > 1 && options.chips > 0)
            {
                SetStatus("Max bet " + amount.ToString("N0") + "  ·  you have " + options.chips.ToString("N0"));
            }
        }

        private static void SetFlexWidth(GameObject go, float weight)
        {
            var element = go.GetComponent<LayoutElement>() ?? go.AddComponent<LayoutElement>();
            element.flexibleWidth = weight;
        }

        private void AddAction(string label, string action, Color background, Color? textColor = null)
        {
            var button = UiFactory.CreateButton("Action_" + action, _actionRow, label, () =>
            {
                // Disable immediately: the turn is over the moment this is sent,
                // and a double tap would be a second (illegal) action.
                ClearActions();
                ActionRequested?.Invoke(action);
            }, background, textColor, 26);

            _actionButtons.Add(button);
        }


        public void ClearActions()
        {
            foreach (var button in _actionButtons)
            {
                if (button != null) UnityEngine.Object.Destroy(button.gameObject);
            }
            _actionButtons.Clear();
        }

        // ------------------------------------------------------------- timer

        /// <summary>
        /// Starts the visual turn clock. <paramref name="deadlineMs"/> is the
        /// server's Unix-ms deadline; the bar is driven from the remaining time
        /// rather than a local countdown so clock drift cannot desync it.
        /// </summary>
        public void StartTimer(long deadlineMs)
        {
            var remaining = (deadlineMs - NowMs()) / 1000f;
            if (remaining <= 0f)
            {
                StopTimer();
                return;
            }
            _turnDeadline = Time.realtimeSinceStartup + remaining;
        }

        public void StopTimer()
        {
            _turnDeadline = 0f;
            if (_timerFill != null) _timerFill.fillAmount = 0f;
        }

        public void Tick()
        {
            if (_turnDeadline <= 0f) return;

            var remaining = _turnDeadline - Time.realtimeSinceStartup;
            if (remaining <= 0f)
            {
                StopTimer();
                return;
            }

            _timerFill.fillAmount = Mathf.Clamp01(remaining / _turnTotalSeconds);
            _timerFill.color = remaining < 6f ? UiFactory.Danger : UiFactory.Gold;
        }

        public static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        // --------------------------------------------------------------- log

        public void Log(string line)
        {
            _log.Enqueue(line);
            while (_log.Count > LogLines) _log.Dequeue();

            var builder = new StringBuilder();
            foreach (var entry in _log) builder.AppendLine(entry);
            _logText.text = builder.ToString();
        }
    }
}
