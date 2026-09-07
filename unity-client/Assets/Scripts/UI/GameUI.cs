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
        private Text _lobbyProvider;
        private RectTransform _lobbyRail;
        private Text _privateHint;
        private Image _currentAvatar;
        private Text _avatarHint;
        private RectTransform _avatarGrid;
        private Button _avatarClearButton;
        private Text[] _statLines;
        private ProfilePictureDto[] _avatarChoices = Array.Empty<ProfilePictureDto>();
        private UserDto _user;

        /// <summary>The rows of the record card, in the order they are drawn.</summary>
        private static readonly string[] StatLabels =
        {
            "Hands played", "Won", "Lost", "Left mid-hand", "Total winnings", "Biggest pot",
        };
        /// <summary>Stakes the lobby offers; replaced by the server's list on connect.</summary>
        private long[] _bootChoices = { 200, 5000 };
        private Button _createButton;
        /// <summary>The categories the rail offers; the server's list wins.</summary>
        private string[] _categories = { TableCategory.Seen, TableCategory.Blind };

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
        private RectTransform _actionLeft;
        private RectTransform _actionRight;
        /// <summary>True only while this player may actually act.</summary>
        private bool _myTurn;
        /// <summary>Overlaid on the player's own cards, not in the button bar.</summary>
        private Button _seeButton;
        private Text _logText;
        private readonly Queue<string> _log = new Queue<string>();

        /// <summary>The most recent table snapshot, for looking names up.</summary>
        private RoomStateDto _lastRoom;

        // Showdown overlay (requirement 14)
        private RectTransform _showdownPanel;
        private RectTransform _showdownHands;
        private Text _showdownResult;
        private readonly List<GameObject> _showdownItems = new List<GameObject>();

        // Lobby rewards (requirements 17 and 18)
        private Text _rewardText;
        private Button _milestoneButton;
        private Button _bonusButton;
        private RewardsDto _rewards;

        /// <summary>Room chat. Only shown while the player is at a table.</summary>
        public ChatPanel Chat { get; } = new ChatPanel();

        /// <summary>Raised when the player collects a reward: "milestone" or "bonus".</summary>
        public event Action<string> RewardClaimRequested;

        /// <summary>Raised when the light/dark icon is pressed (requirement 23).</summary>
        public event Action ThemeToggleRequested;

        // Leave confirmation (requirement 25)
        private RectTransform _leavePanel;
        private Text _leaveBody;

        private float _turnDeadline;
        /// <summary>Which pod is counting down, and when its clock runs out.</summary>
        private int _turnViewIndex = -1;
        private float _seatTurnEndsAt;
        /// <summary>The hand the showdown on screen belongs to.</summary>
        private int _shownHandNo = -1;
        private float _turnTotalSeconds = 25f;
        private float _lastRewardTick;

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

        /// <summary>Requirement 21: a bundled picture was picked in the lobby.</summary>
        public event Action<string> AvatarChosen;

        /// <summary>Fall back to the Google/Facebook picture.</summary>
        public event Action AvatarCleared;

        /// <summary>
        /// Supplied by the client so the lobby can show pictures: it takes a URL
        /// and calls back with a sprite. Kept as a delegate because this class
        /// is not a MonoBehaviour and cannot run a download itself.
        /// </summary>
        public Action<string, Action<Sprite>> ImageLoader;
        public event Action LeaveRequested;
        public event Action<string> ActionRequested;
        /// <summary>Raised with the exact amount picked on the stepper.</summary>
        public event Action<string, long> BetRequested;

        public long SelectedBoot => _bootChoices.Length > 0 ? _bootChoices[0] : 200;

        /// <summary>The Blind/Seen category currently picked in the lobby.</summary>
        public string SelectedCategory => _categories.Length > 0 ? _categories[0] : TableCategory.Seen;

        // ------------------------------------------------------------- build

        public void Build(Transform canvas)
        {
            BuildLogin(canvas);
            BuildLobby(canvas);
            BuildTable(canvas);
            // Built last so the chat panel draws over the table.
            Chat.Build(_tablePanel);
            BuildLeaveDialog(_tablePanel);
            ShowLogin();
        }

        // The card is 1040 x 880; this is the breathing room inside it.
        private const int CardPad = 64;
        private const int LobbyPad = 36;
        private const int CardInset = 36;

        // The canvas matches on height, so it is always 1080 units tall: the
        // rail's height — and therefore a square card's side — is exact.
        private const float RailBottom = 0.095f;
        private const float RailTop = 0.865f;
        private const float TableCardSize = (RailTop - RailBottom) * 1080f;
        private const float SideCardWidth = 620f;

        private void BuildLogin(Transform canvas)
        {
            var card = UiFactory.CreateAppCard("LoginCard", canvas);
            // The page behind the card is what gets shown and hidden, so the
            // backdrop travels with the screen.
            _loginPanel = (RectTransform)card.parent;

            // "King" in ink, "Teen Patti" in gold — the browser's wordmark.
            var gold = ColorUtility.ToHtmlStringRGB(UiFactory.Gold);
            var title = UiFactory.CreateText("Title", card,
                "King <color=#" + gold + ">Teen Patti</color>", 58,
                TextAnchor.MiddleLeft, UiFactory.Ink, FontStyle.Bold);
            UiFactory.Anchor(title.rectTransform, new Vector2(0f, 0.85f), new Vector2(0.8f, 0.95f),
                new Vector2(CardPad, 0f), Vector2.zero);

            AddThemeToggle(card, new Vector2(0.87f, 0.862f), new Vector2(0.955f, 0.938f));

            var subtitle = UiFactory.CreateText("Subtitle", card, "Sign in to take a seat.", 28,
                TextAnchor.MiddleLeft, UiFactory.Muted);
            UiFactory.Anchor(subtitle.rectTransform, new Vector2(0f, 0.77f), new Vector2(1f, 0.84f),
                new Vector2(CardPad, 0f), new Vector2(-CardPad, 0f));

            var column = UiFactory.CreateColumn("Column", card, 16f,
                new RectOffset(CardPad, CardPad, 0, 0));
            UiFactory.Anchor((RectTransform)column.transform, new Vector2(0f, 0.06f),
                new Vector2(1f, 0.755f), Vector2.zero, Vector2.zero);

            var nameLabel = UiFactory.CreateText("NameLabel", column.transform, "Display name", 24,
                TextAnchor.MiddleLeft, UiFactory.Muted);
            UiFactory.SetHeight(nameLabel.gameObject, 36);

            _nameInput = UiFactory.CreateInput("NameInput", column.transform, "Player");
            UiFactory.SetHeight(_nameInput.gameObject, 84);
            _nameInput.characterLimit = 24;

            _guestButton = UiFactory.CreateButton("GuestButton", column.transform, "Play as Guest",
                () => GuestLoginRequested?.Invoke(_nameInput.text),
                UiFactory.Scheme.Primary, UiFactory.Scheme.OnPrimary);
            UiFactory.SetHeight(_guestButton.gameObject, 92);

            _googleButton = UiFactory.CreateButton("GoogleButton", column.transform,
                "Continue with Google", () => GoogleLoginRequested?.Invoke());
            UiFactory.SetHeight(_googleButton.gameObject, 84);

            _facebookButton = UiFactory.CreateButton("FacebookButton", column.transform,
                "Continue with Facebook", () => FacebookLoginRequested?.Invoke());
            UiFactory.SetHeight(_facebookButton.gameObject, 84);

            var hint = UiFactory.CreateText("Hint", column.transform,
                "Guest play is keyed to this device's id, so your chips are here next time.", 22,
                TextAnchor.MiddleLeft, UiFactory.Muted);
            UiFactory.SetHeight(hint.gameObject, 44);

            _loginError = UiFactory.CreateText("Error", column.transform, string.Empty, 24,
                TextAnchor.MiddleLeft, UiFactory.Danger);
            UiFactory.SetHeight(_loginError.gameObject, 44);
        }

        private void BuildLobby(Transform canvas)
        {
            // The lobby fills the screen. There is no centred card here: a phone
            // held in landscape is mostly width, and boxing the content into a
            // narrow column in the middle wastes the whole point of the format.
            var page = UiFactory.CreatePanel("LobbyPage", canvas, UiFactory.Scheme.Surface);
            _lobbyPanel = page;

            // --- top bar, running the full width
            var who = UiFactory.CreateRow("Who", page, 16f);
            who.childControlWidth = true;
            who.childForceExpandWidth = false;
            who.childAlignment = TextAnchor.MiddleLeft;
            UiFactory.Anchor((RectTransform)who.transform, new Vector2(0.175f, 0.895f),
                new Vector2(0.55f, 0.975f), Vector2.zero, Vector2.zero);

            _lobbyName = UiFactory.CreateText("Name", who.transform, string.Empty, 40,
                TextAnchor.MiddleLeft, UiFactory.Ink, FontStyle.Bold);
            var nameFit = _lobbyName.gameObject.AddComponent<ContentSizeFitter>();
            nameFit.horizontalFit = ContentSizeFitter.FitMode.PreferredSize;

            _lobbyProvider = UiFactory.CreateChip("Provider", who.transform, string.Empty,
                UiFactory.Scheme.SecondaryContainer, UiFactory.Scheme.OnSecondaryContainer, 22);
            var chipElement = _lobbyProvider.transform.parent.gameObject.AddComponent<LayoutElement>();
            chipElement.preferredWidth = 130f;
            chipElement.preferredHeight = 52f;

            _lobbyChips = UiFactory.CreateText("Chips", page, string.Empty, 40,
                TextAnchor.MiddleRight, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_lobbyChips.rectTransform, new Vector2(0.55f, 0.895f),
                new Vector2(0.885f, 0.975f), Vector2.zero, Vector2.zero);

            AddThemeToggle(page, new Vector2(0.905f, 0.905f), new Vector2(0.965f, 0.965f));

            // --- the rail: every lobby choice is a card, swiped sideways, so a
            //     phone never has to scroll down to reach one.
            _lobbyRail = UiFactory.CreateHScroll("Rail", page, 28f);
            var viewport = (RectTransform)_lobbyRail.parent;
            UiFactory.Anchor(viewport, new Vector2(0f, RailBottom), new Vector2(1f, RailTop),
                new Vector2(LobbyPad, 0f), new Vector2(-LobbyPad, 0f));

            BuildRail();

            _lobbyError = UiFactory.CreateText("Error", page, string.Empty, 24,
                TextAnchor.MiddleCenter, UiFactory.Danger);
            UiFactory.Anchor(_lobbyError.rectTransform, new Vector2(0.2f, 0.005f),
                new Vector2(0.72f, 0.045f), Vector2.zero, Vector2.zero);

            _rewardText = UiFactory.CreateText("RewardText", page, string.Empty, 22,
                TextAnchor.MiddleCenter, UiFactory.Muted);
            UiFactory.Anchor(_rewardText.rectTransform, new Vector2(0.2f, 0.045f),
                new Vector2(0.72f, 0.082f), Vector2.zero, Vector2.zero);

            // Requirements 26 and 27: the two rewards sit in opposite corners of
            // the screen, so they are always reachable without hunting.
            _bonusButton = UiFactory.CreateButton("BonusBtn", page, "BONUS",
                () => RewardClaimRequested?.Invoke("bonus"));
            UiFactory.Anchor(_bonusButton.GetComponent<RectTransform>(),
                new Vector2(0.008f, 0.9f), new Vector2(0.165f, 0.975f), Vector2.zero, Vector2.zero);
            UiFactory.SetHeight(_bonusButton.gameObject, 82);

            _milestoneButton = UiFactory.CreateButton("MilestoneBtn", page, "MILESTONE",
                () => RewardClaimRequested?.Invoke("milestone"));
            UiFactory.Anchor(_milestoneButton.GetComponent<RectTransform>(),
                new Vector2(0.835f, 0.012f), new Vector2(0.992f, 0.087f), Vector2.zero, Vector2.zero);
            UiFactory.SetHeight(_milestoneButton.gameObject, 82);
        }

        // ------------------------------------------------------------- rail

        /// <summary>
        /// Rebuilds the lobby rail. Called again whenever the server tells us
        /// which stakes and categories it is actually offering.
        /// </summary>
        private void BuildRail()
        {
            if (_lobbyRail == null) return;

            for (var i = _lobbyRail.childCount - 1; i >= 0; i--)
            {
                UnityEngine.Object.Destroy(_lobbyRail.GetChild(i).gameObject);
            }

            var index = 0;
            foreach (var category in _categories)
            {
                foreach (var boot in _bootChoices)
                {
                    AddTableCard(category, boot, index++);
                }
            }

            AddPrivateCard();
            AddPictureCard();
            AddRecordCard();
        }

        /// <summary>
        /// One boot table. Requirement 28: square, and lit by a sweep that runs
        /// corner to corner without stopping. The whole card is the hit target.
        /// </summary>
        private void AddTableCard(string category, long boot, int index)
        {
            var blind = category == TableCategory.Blind;

            var card = UiFactory.CreateRounded("Table_" + category + "_" + boot, _lobbyRail,
                UiFactory.Scheme.Surface3, UiFactory.ShapeXLarge);
            SetRailCardWidth(card.gameObject, TableCardSize);

            var button = card.gameObject.AddComponent<Button>();
            button.targetGraphic = card;
            button.onClick.AddListener(() => QuickJoinRequested?.Invoke(boot, category));

            // A tinted band behind the heading, so the card has depth rather
            // than being one flat block of colour.
            var wash = UiFactory.CreateImage("Wash", card.transform,
                UiFactory.Alpha(blind ? UiFactory.Scheme.Tertiary : UiFactory.Gold, 0.18f));
            UiFactory.Anchor(wash.rectTransform, new Vector2(0f, 0.56f), new Vector2(1f, 1f),
                Vector2.zero, Vector2.zero);
            wash.raycastTarget = false;

            var chip = UiFactory.CreateChip("Kind", card.transform, blind ? "BLIND" : "SEEN",
                blind ? UiFactory.Scheme.TertiaryContainer : UiFactory.Scheme.SecondaryContainer,
                blind ? UiFactory.Scheme.OnTertiaryContainer : UiFactory.Scheme.OnSecondaryContainer,
                26);
            UiFactory.Anchor((RectTransform)chip.transform.parent, new Vector2(0f, 0.855f),
                new Vector2(0.42f, 0.935f), new Vector2(CardInset, 0f), Vector2.zero);

            var amount = UiFactory.CreateText("Boot", card.transform, boot.ToString("N0"), 108,
                TextAnchor.MiddleLeft, UiFactory.Good, FontStyle.Bold);
            UiFactory.Anchor(amount.rectTransform, new Vector2(0f, 0.66f), new Vector2(1f, 0.84f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));

            var label = UiFactory.CreateText("Label", card.transform, "boot", 28,
                TextAnchor.MiddleLeft, UiFactory.Muted);
            UiFactory.Anchor(label.rectTransform, new Vector2(0f, 0.6f), new Vector2(1f, 0.66f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));

            var hint = UiFactory.CreateText("Hint", card.transform,
                blind ? "Only your own chips are visible" : "Everyone's chips are visible", 28,
                TextAnchor.UpperLeft, UiFactory.Ink);
            UiFactory.Anchor(hint.rectTransform, new Vector2(0f, 0.4f), new Vector2(1f, 0.55f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));

            var cta = UiFactory.CreateText("Cta", card.transform, "Tap to sit down", 30,
                TextAnchor.MiddleLeft, UiFactory.Good, FontStyle.Bold);
            UiFactory.Anchor(cta.rectTransform, new Vector2(0f, 0.07f), new Vector2(1f, 0.16f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));

            // Staggered, so the rail shimmers in sequence instead of blinking.
            CardSheen.Attach(card, index * 0.55f);
        }

        private void AddPrivateCard()
        {
            var card = UiFactory.CreateRounded("PrivateCard", _lobbyRail,
                UiFactory.Scheme.Surface3, UiFactory.ShapeXLarge);
            SetRailCardWidth(card.gameObject, SideCardWidth);

            var column = UiFactory.CreateColumn("Column", card.transform, 16f,
                new RectOffset(CardInset, CardInset, 0, 0));
            UiFactory.Stretch((RectTransform)column.transform, 40f);

            var heading = UiFactory.CreateText("Heading", column.transform, "Private table", 38,
                TextAnchor.MiddleLeft, UiFactory.Ink, FontStyle.Bold);
            UiFactory.SetHeight(heading.gameObject, 60);

            _privateHint = UiFactory.CreateText("Hint", column.transform, string.Empty, 24,
                TextAnchor.UpperLeft, UiFactory.Muted);
            UiFactory.SetHeight(_privateHint.gameObject, 100);

            // The boot is fixed server-side, so nothing is chosen here; 0 tells
            // the connection to let the server decide.
            _createButton = UiFactory.CreateButton("CreateTable", column.transform, "Create",
                () => CreateTableRequested?.Invoke(0, TableCategory.Seen),
                UiFactory.Scheme.Primary, UiFactory.Scheme.OnPrimary, 28);
            UiFactory.SetHeight(_createButton.gameObject, 88);

            var or = UiFactory.CreateText("Or", column.transform, "Or join one with its code:", 24,
                TextAnchor.MiddleLeft, UiFactory.Muted);
            UiFactory.SetHeight(or.gameObject, 48);

            _codeInput = UiFactory.CreateInput("CodeInput", column.transform, "TABLE CODE", 28);
            UiFactory.SetHeight(_codeInput.gameObject, 84);
            _codeInput.characterLimit = 6;

            var join = UiFactory.CreateButton("JoinCode", column.transform, "Join",
                () => JoinCodeRequested?.Invoke((_codeInput.text ?? string.Empty).Trim().ToUpperInvariant()),
                null, null, 28);
            UiFactory.SetHeight(join.gameObject, 84);

            UpdatePrivateLabel();
        }

        private void AddPictureCard()
        {
            var card = UiFactory.CreateRounded("PictureCard", _lobbyRail,
                UiFactory.Scheme.Surface3, UiFactory.ShapeXLarge);
            SetRailCardWidth(card.gameObject, SideCardWidth);

            var heading = UiFactory.CreateText("Heading", card.transform, "Picture", 38,
                TextAnchor.MiddleLeft, UiFactory.Ink, FontStyle.Bold);
            UiFactory.Anchor(heading.rectTransform, new Vector2(0f, 0.88f), new Vector2(1f, 0.95f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));

            _currentAvatar = UiFactory.CreateRounded("Current", card.transform,
                UiFactory.Scheme.SurfaceVariant, 44);
            UiFactory.Anchor(_currentAvatar.rectTransform, new Vector2(0f, 0.7f),
                new Vector2(0f, 0.855f), new Vector2(CardInset, 0f), new Vector2(CardInset + 128, 0f));

            _avatarHint = UiFactory.CreateText("AvatarHint", card.transform, string.Empty, 22,
                TextAnchor.UpperLeft, UiFactory.Muted);
            UiFactory.Anchor(_avatarHint.rectTransform, new Vector2(0f, 0.68f), new Vector2(1f, 0.855f),
                new Vector2(CardInset + 148, 0f), new Vector2(-CardInset, 0f));

            // A plain grid of choices. It is deliberately not a scroll view: the
            // bundled set is small and fits.
            _avatarGrid = UiFactory.CreateRect("AvatarGrid", card.transform);
            UiFactory.Anchor(_avatarGrid, new Vector2(0f, 0.18f), new Vector2(1f, 0.66f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));
            var grid = _avatarGrid.gameObject.AddComponent<GridLayoutGroup>();
            grid.cellSize = new Vector2(96, 96);
            grid.spacing = new Vector2(16, 16);
            grid.childAlignment = TextAnchor.UpperLeft;

            _avatarClearButton = UiFactory.CreateButton("AvatarClear", card.transform,
                "Use my Google/Facebook picture", () => AvatarCleared?.Invoke(), null, null, 22);
            UiFactory.Anchor(_avatarClearButton.GetComponent<RectTransform>(),
                new Vector2(0f, 0.05f), new Vector2(1f, 0.14f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));
            UiFactory.SetHeight(_avatarClearButton.gameObject, 72);

            RenderAvatarGrid();
        }

        private void AddRecordCard()
        {
            var card = UiFactory.CreateRounded("RecordCard", _lobbyRail,
                UiFactory.Scheme.Surface3, UiFactory.ShapeXLarge);
            SetRailCardWidth(card.gameObject, SideCardWidth);

            var heading = UiFactory.CreateText("Heading", card.transform, "Your record", 38,
                TextAnchor.MiddleLeft, UiFactory.Ink, FontStyle.Bold);
            UiFactory.Anchor(heading.rectTransform, new Vector2(0f, 0.88f), new Vector2(1f, 0.95f),
                new Vector2(CardInset, 0f), new Vector2(-CardInset, 0f));

            var column = UiFactory.CreateColumn("Stats", card.transform, 10f,
                new RectOffset(CardInset, CardInset, 0, 0));
            UiFactory.Anchor((RectTransform)column.transform, new Vector2(0f, 0.06f),
                new Vector2(1f, 0.86f), Vector2.zero, Vector2.zero);

            _statLines = new Text[StatLabels.Length];
            for (var i = 0; i < StatLabels.Length; i++)
            {
                var row = UiFactory.CreateRect("Stat" + i, column.transform);
                UiFactory.SetHeight(row.gameObject, 84);

                var label = UiFactory.CreateText("Label", row, StatLabels[i], 24,
                    TextAnchor.MiddleLeft, UiFactory.Muted);
                UiFactory.Anchor(label.rectTransform, new Vector2(0f, 0f), new Vector2(0.6f, 1f),
                    Vector2.zero, Vector2.zero);

                _statLines[i] = UiFactory.CreateText("Value", row, "-", 30,
                    TextAnchor.MiddleRight, UiFactory.Ink, FontStyle.Bold);
                UiFactory.Anchor(_statLines[i].rectTransform, new Vector2(0.6f, 0f),
                    new Vector2(1f, 1f), Vector2.zero, Vector2.zero);
            }

            RenderStats();
        }

        private static void SetRailCardWidth(GameObject go, float width)
        {
            var element = go.GetComponent<LayoutElement>() ?? go.AddComponent<LayoutElement>();
            element.preferredWidth = width;
            element.minWidth = width;
        }

        private void BuildTable(Transform canvas)
        {
            _tablePanel = UiFactory.CreatePanel("TablePanel", canvas, UiFactory.FeltDark);

            // --- top bar
            var leave = UiFactory.CreateButton("Leave", _tablePanel, "LEAVE", AskToLeave,
                UiFactory.Field, UiFactory.Muted, 26);
            UiFactory.Anchor(leave.GetComponent<RectTransform>(), new Vector2(0, 0.94f),
                new Vector2(0.22f, 0.985f), new Vector2(24, 0), Vector2.zero);

            _tableCode = UiFactory.CreateText("Code", _tablePanel, string.Empty, 30,
                TextAnchor.MiddleCenter, UiFactory.Muted);
            UiFactory.Anchor(_tableCode.rectTransform, new Vector2(0.22f, 0.94f), new Vector2(0.72f, 0.985f),
                Vector2.zero, Vector2.zero);

            _myChipsText = UiFactory.CreateText("MyChips", _tablePanel, string.Empty, 32,
                TextAnchor.MiddleRight, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_myChipsText.rectTransform, new Vector2(0.62f, 0.94f), new Vector2(0.90f, 0.985f),
                Vector2.zero, Vector2.zero);

            AddThemeToggle(_tablePanel, new Vector2(0.91f, 0.935f), new Vector2(0.995f, 0.99f));

            // --- felt
            // A stadium, not a rectangle: a huge corner radius on a wide, short
            // box is the closest uGUI gets to the oval table players expect.
            var feltRing = UiFactory.CreateRounded("FeltRing", _tablePanel,
                UiFactory.Alpha(UiFactory.Gold, 0.55f), 200);
            UiFactory.Anchor(feltRing.rectTransform, new Vector2(0.115f, 0.163f),
                new Vector2(0.885f, 0.945f), Vector2.zero, Vector2.zero);

            var felt = UiFactory.CreateRounded("Felt", _tablePanel, UiFactory.Felt, 190);
            UiFactory.Anchor(felt.rectTransform, new Vector2(0.115f, 0.163f),
                new Vector2(0.885f, 0.945f), new Vector2(9, 9), new Vector2(-9, -9));

            // The pot sits in the middle of the ring of players.
            var potLabel = UiFactory.CreateText("PotLabel", felt.transform, "POT", 22,
                TextAnchor.MiddleCenter, UiFactory.OnFelt);
            UiFactory.Anchor(potLabel.rectTransform, new Vector2(0.4f, 0.6f), new Vector2(0.6f, 0.675f),
                Vector2.zero, Vector2.zero);

            _potText = UiFactory.CreateText("Pot", felt.transform, "0", 58,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_potText.rectTransform, new Vector2(0.38f, 0.45f), new Vector2(0.62f, 0.605f),
                Vector2.zero, Vector2.zero);

            _stakeText = UiFactory.CreateText("Stake", felt.transform, string.Empty, 20,
                TextAnchor.MiddleCenter, UiFactory.OnFelt);
            UiFactory.Anchor(_stakeText.rectTransform, new Vector2(0.36f, 0.38f), new Vector2(0.64f, 0.45f),
                Vector2.zero, Vector2.zero);

            // Players sit in a ring around the table, seat 0 at the bottom and
            // the rest clockwise. Fixed points keep a seat in place when someone
            // else leaves, so nobody appears to slide around the table.
            // Places round the oval, in view order: the player looking at the
            // screen is always the one at the bottom, and the rest run clockwise
            // from their left. Seats keep their place when someone leaves, so
            // nobody appears to slide around the table.
            //
            // The heights are not free. A top seat stacks pod, then cards, then
            // its bet chip downwards; a side seat runs its cards inward at its
            // own height. Put the side pair too high and their cards meet the
            // top pair's chips in the corners.
            var places = new[]
            {
                new Vector2(0.405f, 0.155f), // you, bottom centre — centred with the stepper
                new Vector2(0.058f, 0.3f), // left
                new Vector2(0.275f, 0.85f), // top left
                new Vector2(0.725f, 0.85f), // top right
                new Vector2(0.942f, 0.3f), // right
            };

            for (var i = 0; i < MaxSeats; i++)
            {
                var centre = places[i];
                var half = new Vector2(0.05f, 0.135f);
                _seatViews[i] = SeatView.Create(felt.transform, i, centre, half);
            }

            _statusText = UiFactory.CreateText("Status", felt.transform, string.Empty, 30,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_statusText.rectTransform, new Vector2(0.37f, 0.855f),
                new Vector2(0.63f, 0.95f), Vector2.zero, Vector2.zero);

            // Showdown overlay (requirement 14): every revealed hand plus the
            // result, drawn over the felt until the next deal.
            _showdownPanel = UiFactory.CreateRounded("Showdown", felt.transform,
                UiFactory.Alpha(UiFactory.Scheme.Surface, 0.94f), 190).rectTransform;
            UiFactory.Stretch(_showdownPanel);

            _showdownHands = UiFactory.CreateRect("Hands", _showdownPanel);
            var handRow = _showdownHands.gameObject.AddComponent<HorizontalLayoutGroup>();
            handRow.spacing = 16f;
            handRow.childAlignment = TextAnchor.MiddleCenter;
            handRow.childControlWidth = true;
            handRow.childControlHeight = true;
            handRow.childForceExpandWidth = false;
            UiFactory.Anchor(_showdownHands, new Vector2(0.02f, 0.38f), new Vector2(0.98f, 0.95f),
                Vector2.zero, Vector2.zero);

            _showdownResult = UiFactory.CreateText("Result", _showdownPanel, string.Empty, 34,
                TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Anchor(_showdownResult.rectTransform, new Vector2(0, 0.06f), new Vector2(1, 0.36f),
                Vector2.zero, Vector2.zero);

            _showdownPanel.gameObject.SetActive(false);

            // --- own hand
            // The player's own three cards sit in a tray to the right of their
            // pod, where the reference layout puts them.
            // A child of the felt, so it is positioned against the player's own
            // pod and so the showdown overlay covers it like everything else.
            var tray = UiFactory.CreateRounded("HandTray", felt.transform,
                UiFactory.Alpha(UiFactory.Scheme.Surface, 0.9f), UiFactory.ShapeMedium);
            // Butted up against the player's own pod, the way a real hand sits
            // in front of the person holding it. Sized in canvas units from the
            // shared card size, so the hand matches every opponent's exactly.
            const float trayPad = 10f;
            var traySize = new Vector2(3f * UiFactory.CardWidth + trayPad * 2f,
                UiFactory.CardHeight + trayPad * 2f);

            var trayRect = tray.rectTransform;
            trayRect.anchorMin = new Vector2(0.405f + 0.05f, 0.155f); // the pod's inner edge
            trayRect.anchorMax = trayRect.anchorMin;
            trayRect.pivot = new Vector2(0f, 0.5f);
            trayRect.sizeDelta = traySize;
            trayRect.anchoredPosition = new Vector2(12f, 0f);

            // Edge to edge: each slot is exactly one card wide, so there is
            // nothing spare for the artwork to letterbox into.
            for (var i = 0; i < 3; i++)
            {
                var x0 = (trayPad + i * UiFactory.CardWidth) / traySize.x;
                var x1 = (trayPad + (i + 1) * UiFactory.CardWidth) / traySize.x;
                var y0 = trayPad / traySize.y;
                var y1 = (traySize.y - trayPad) / traySize.y;
                _cardViews[i] = CardView.Create(tray.transform, new Vector2(x0, y0), new Vector2(x1, y1));
            }

            // "See" sits on the cards rather than in the button bar: looking at
            // your hand is something you do to the cards, and once you have
            // looked the button has no reason to still be there.
            _seeButton = UiFactory.CreateButton("SeeCards", tray.transform, "SEE CARDS",
                () =>
                {
                    _seeButton.gameObject.SetActive(false);
                    ActionRequested?.Invoke(GameAction.See);
                },
                UiFactory.Alpha(UiFactory.Scheme.Primary, 0.94f), UiFactory.Scheme.OnPrimary, 28);
            UiFactory.Anchor(_seeButton.GetComponent<RectTransform>(), new Vector2(0.05f, 0.34f),
                new Vector2(0.95f, 0.66f), Vector2.zero, Vector2.zero);
            UiFactory.SetHeight(_seeButton.gameObject, 66);
            _seeButton.transform.SetAsLastSibling();
            _seeButton.gameObject.SetActive(false);

            // --- turn clock
            // No separate turn bar: the pod of whoever is to act fills up
            // instead, which puts the countdown on the player it belongs to.

            // --- action buttons
            _actionLeft = MakeActionZone("ActionsLeft", 0.025f, 0.185f);
            _actionRow = MakeActionZone("ActionsCentre", 0.30f, 0.70f);
            _actionRight = MakeActionZone("ActionsRight", 0.815f, 0.975f);

            // Draw it straight away, dead, so the table never opens on an empty
            // strip where the controls are about to appear.
            RenderActionBar();

            // --- event log, kept but not shown: play-by-play text belongs in a
            //     debug build, not on top of the table.
            _logText = UiFactory.CreateText("Log", _tablePanel, string.Empty, 24,
                TextAnchor.LowerLeft, UiFactory.Muted);
            UiFactory.Anchor(_logText.rectTransform, new Vector2(0.04f, 0.01f), new Vector2(0.96f, 0.14f),
                Vector2.zero, Vector2.zero);
            _logText.gameObject.SetActive(false);
        }

        /// <summary>
        /// One of the three bands the bottom bar is split into. Pack sits on the
        /// left and chaal on the right — far apart, because they are the two
        /// irreversible taps and a misfire costs the hand.
        /// </summary>
        private RectTransform MakeActionZone(string name, float xMin, float xMax)
        {
            var zone = UiFactory.CreateRect(name, _tablePanel);
            var row = zone.gameObject.AddComponent<HorizontalLayoutGroup>();
            row.spacing = 12f;
            row.childControlWidth = true;
            row.childControlHeight = true;
            row.childForceExpandWidth = true;
            row.childForceExpandHeight = true;
            UiFactory.Anchor(zone, new Vector2(xMin, 0.028f), new Vector2(xMax, 0.142f),
                Vector2.zero, Vector2.zero);
            return zone;
        }

        /// <summary>
        /// The light/dark icon (requirement 23). It shows the theme it will
        /// switch *to*, which is the convention players expect.
        /// </summary>
        private void AddThemeToggle(Transform parent, Vector2 anchorMin, Vector2 anchorMax)
        {
            var button = UiFactory.CreateButton("ThemeToggle", parent,
                UiFactory.IsDarkMode ? "\u2600" : "\u263D",
                () => ThemeToggleRequested?.Invoke(),
                UiFactory.Scheme.SurfaceVariant, UiFactory.Scheme.OnSurfaceVariant, 34);

            UiFactory.Anchor(button.GetComponent<RectTransform>(), anchorMin, anchorMax,
                Vector2.zero, Vector2.zero);
        }

        /// <summary>
        /// Requirement 25: leaving a table is confirmed first. The wording
        /// changes when a hand is live, because that is when walking away
        /// actually costs something — the stake stays in the pot.
        /// </summary>
        private void BuildLeaveDialog(Transform parent)
        {
            // A scrim across the whole screen, so nothing behind it is clickable.
            _leavePanel = UiFactory.CreatePanel("LeaveScrim", parent, new Color(0, 0, 0, 0.72f));
            UiFactory.Stretch(_leavePanel);

            var dialog = UiFactory.CreateImage("Dialog", _leavePanel, UiFactory.Scheme.Surface3);
            UiFactory.Anchor(dialog.rectTransform, new Vector2(0.18f, 0.30f), new Vector2(0.82f, 0.72f),
                Vector2.zero, Vector2.zero);

            var title = UiFactory.CreateText("Title", dialog.transform, "Leave this table?", 40,
                TextAnchor.MiddleCenter, UiFactory.Ink, FontStyle.Bold);
            UiFactory.Anchor(title.rectTransform, new Vector2(0.05f, 0.66f), new Vector2(0.95f, 0.92f),
                Vector2.zero, Vector2.zero);

            _leaveBody = UiFactory.CreateText("Body", dialog.transform, string.Empty, 26,
                TextAnchor.UpperCenter, UiFactory.Muted);
            UiFactory.Anchor(_leaveBody.rectTransform, new Vector2(0.07f, 0.34f), new Vector2(0.93f, 0.66f),
                Vector2.zero, Vector2.zero);

            var stay = UiFactory.CreateButton("Stay", dialog.transform, "STAY",
                () => _leavePanel.gameObject.SetActive(false),
                UiFactory.Scheme.SurfaceVariant, UiFactory.Scheme.OnSurfaceVariant, 28);
            UiFactory.Anchor(stay.GetComponent<RectTransform>(), new Vector2(0.08f, 0.08f),
                new Vector2(0.47f, 0.28f), Vector2.zero, Vector2.zero);

            var confirm = UiFactory.CreateButton("Confirm", dialog.transform, "LEAVE",
                () =>
                {
                    _leavePanel.gameObject.SetActive(false);
                    LeaveRequested?.Invoke();
                },
                UiFactory.Scheme.Error, UiFactory.Scheme.OnErrorContainer, 28);
            UiFactory.Anchor(confirm.GetComponent<RectTransform>(), new Vector2(0.53f, 0.08f),
                new Vector2(0.92f, 0.28f), Vector2.zero, Vector2.zero);

            _leavePanel.gameObject.SetActive(false);
        }

        private void AskToLeave()
        {
            if (_leavePanel == null)
            {
                LeaveRequested?.Invoke();
                return;
            }

            var midHand = _lastRoom != null
                          && _lastRoom.state == TableState.Betting
                          && _lastRoom.you != null
                          && _lastRoom.you.IsSeated
                          && _lastRoom.you.status == SeatState.Active;

            _leaveBody.text = midHand
                ? "You are in a hand. Leaving packs your cards and your stake stays in the pot."
                : "You can join another table straight away.";

            _leavePanel.gameObject.SetActive(true);
            _leavePanel.SetAsLastSibling();
        }

        /// <summary>
        /// A private table's boot, which requirement 22 fixes rather than lets a
        /// player choose. The server sets it regardless of what is sent, so this
        /// is only used to label the card.
        /// </summary>
        private long _privateBoot = 200;
        private long _privateMaxPot;

        /// <summary>Replaces the lobby's stake list with the one the server offers.</summary>
        public void SetLobbyOptions(GameConfigDto config)
        {
            if (config == null) return;

            if (config.privateBoot > 0) _privateBoot = config.privateBoot;
            _privateMaxPot = config.privateMaxPot;

            if (config.categories != null && config.categories.Length > 0) _categories = config.categories;
            if (config.stakes != null && config.stakes.Length > 0) _bootChoices = config.stakes;

            // The rail is what the player actually picks from, so it is rebuilt
            // rather than patched: the server may offer a different set entirely.
            BuildRail();
        }

        /// <summary>The bundled pictures a player can choose between.</summary>
        public void SetProfilePictures(ProfilePictureDto[] pictures)
        {
            _avatarChoices = pictures ?? Array.Empty<ProfilePictureDto>();
            RenderAvatarGrid();
        }

        private void RenderAvatarGrid()
        {
            if (_avatarGrid == null) return;

            for (var i = _avatarGrid.childCount - 1; i >= 0; i--)
            {
                UnityEngine.Object.Destroy(_avatarGrid.GetChild(i).gameObject);
            }

            foreach (var picture in _avatarChoices)
            {
                var id = picture.id;
                var swatch = UiFactory.CreateRounded("Avatar_" + id, _avatarGrid,
                    UiFactory.Scheme.SurfaceVariant, 38);

                var button = swatch.gameObject.AddComponent<Button>();
                button.targetGraphic = swatch;
                button.onClick.AddListener(() => AvatarChosen?.Invoke(id));

                if (IsVector(picture.url)) DrawCardGlyph(swatch, id);
                else LoadImage(picture.url, swatch);
            }

            RenderAvatarState();
        }

        private void RenderAvatarState()
        {
            if (_avatarHint != null)
            {
                _avatarHint.text = _user == null
                    ? string.Empty
                    : (string.IsNullOrEmpty(_user.avatarChoice)
                        ? "Using your " + _user.provider + " picture."
                        : "Picture chosen. It cannot change once you sit at a table.");
            }

            if (_avatarClearButton != null)
            {
                _avatarClearButton.gameObject.SetActive(
                    _user != null && !string.IsNullOrEmpty(_user.providerAvatarUrl));
            }

            if (_currentAvatar != null && _user != null)
            {
                if (IsVector(_user.avatarUrl)) DrawCardGlyph(_currentAvatar, _user.avatarChoice ?? _user.avatarUrl);
                else LoadImage(_user.avatarUrl, _currentAvatar);
            }
        }

        /// <summary>
        /// Fetches a picture through the loader the client supplies. GameUI is a
        /// plain class with no coroutines of its own, so downloading is somebody
        /// else's job; without a loader the swatches simply stay blank.
        /// </summary>
        private void LoadImage(string url, Image target)
        {
            if (ImageLoader == null || string.IsNullOrEmpty(url) || target == null) return;

            ImageLoader(url, sprite =>
            {
                if (sprite == null || target == null) return;
                target.sprite = sprite;
                target.type = Image.Type.Simple;
                target.preserveAspect = true;
                target.color = Color.white;
            });
        }

        private static bool IsVector(string url) =>
            !string.IsNullOrEmpty(url) && url.EndsWith(".svg", StringComparison.OrdinalIgnoreCase);

        /// <summary>
        /// The bundled pictures are card suits and faces drawn as SVG. Unity has
        /// no SVG decoder in a stock project, so the same card is drawn here
        /// from its name — the player sees a hearts avatar either way.
        /// </summary>
        private static void DrawCardGlyph(Image swatch, string id)
        {
            if (swatch == null) return;

            var name = (id ?? string.Empty);
            var slash = name.LastIndexOf('/');
            if (slash >= 0) name = name.Substring(slash + 1);
            var dot = name.IndexOf('.');
            if (dot >= 0) name = name.Substring(0, dot);

            string glyph;
            Color colour;
            switch (name.ToLowerInvariant())
            {
                case "heart": glyph = "\u2665"; colour = UiFactory.Danger; break;
                case "diamond": glyph = "\u2666"; colour = UiFactory.Danger; break;
                case "spade": glyph = "\u2660"; colour = UiFactory.Ink; break;
                case "club": glyph = "\u2663"; colour = UiFactory.Ink; break;
                case "ace": glyph = "A"; colour = UiFactory.Good; break;
                case "king": glyph = "K"; colour = UiFactory.Good; break;
                case "queen": glyph = "Q"; colour = UiFactory.Good; break;
                case "joker": glyph = "\u2605"; colour = UiFactory.Gold; break;
                default:
                    glyph = name.Length > 0 ? name.Substring(0, 1).ToUpperInvariant() : "?";
                    colour = UiFactory.Ink;
                    break;
            }

            // Rebuilt every time the grid is, so clear whatever was drawn before.
            for (var i = swatch.transform.childCount - 1; i >= 0; i--)
            {
                UnityEngine.Object.Destroy(swatch.transform.GetChild(i).gameObject);
            }

            var text = UiFactory.CreateText("Glyph", swatch.transform, glyph, 40,
                TextAnchor.MiddleCenter, colour, FontStyle.Bold);
            UiFactory.Stretch(text.rectTransform, 4f);
        }

        private void RenderStats()
        {
            if (_statLines == null) return;

            var values = _user == null
                ? new[] { "-", "-", "-", "-", "-", "-" }
                : new[]
                {
                    _user.handsPlayed.ToString("N0"),
                    _user.handsWon.ToString("N0"),
                    _user.handsLost.ToString("N0"),
                    _user.handsLeftMid.ToString("N0"),
                    _user.totalWinnings.ToString("N0"),
                    _user.biggestPot.ToString("N0"),
                };

            for (var i = 0; i < _statLines.Length && i < values.Length; i++)
            {
                if (_statLines[i] != null) _statLines[i].text = values[i];
            }
        }

        private void UpdatePrivateLabel()
        {
            if (_privateHint == null) return;

            _privateHint.text = "Boot " + _privateBoot.ToString("N0")
                                + (_privateMaxPot > 0
                                    ? ", max win " + _privateMaxPot.ToString("N0") + "."
                                    : ".")
                                + " Share the code to fill the seats.";
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
            HideShowdown();
            if (_leavePanel != null) _leavePanel.gameObject.SetActive(false);

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
            _user = user;

            _lobbyName.text = user.displayName;
            if (_lobbyProvider != null) _lobbyProvider.text = (user.provider ?? string.Empty).ToUpperInvariant();
            _lobbyChips.text = user.chips.ToString("N0");

            RenderAvatarState();
            RenderStats();
        }

        // ------------------------------------------------------------ render

        /// <summary>Renders a table snapshot. Everything shown comes from the server.</summary>
        public void RenderRoom(RoomStateDto room, string myUserId)
        {
            if (room == null) return;
            _lastRoom = room;

            // A new deal clears the last reveal. Without this the showdown from
            // the previous hand stays over the table and hides everyone.
            if (room.handNo != _shownHandNo)
            {
                _shownHandNo = room.handNo;
                HideShowdown();
            }

            _tableCode.text = "Table " + room.code +
                               "  ·  " + (room.chipsHidden ? "BLIND" : "SEEN") +
                               "  ·  Hand " + room.handNo;
            _potText.text = room.pot.ToString("N0");
            _stakeText.text = "stake " + room.stake.ToString("N0")
                               + "   ·   boot " + room.bootAmount.ToString("N0")
                               + (room.maxPot > 0 ? "   ·   max pot " + room.maxPot.ToString("N0") : string.Empty);
            if (room.turnTimeoutMs > 0) _turnTotalSeconds = room.turnTimeoutMs / 1000f;

            var seated = room.you != null && room.you.IsSeated;
            var turn = room.turn != null && room.turn.HasTurn ? room.turn : null;

            if (seated) _myChipsText.text = room.you.chips.ToString("N0");

            var turnSeat = turn?.seatIndex ?? -1;
            var isBetting = room.state == TableState.Betting;

            var mySeat = seated ? room.you.seatIndex : 0;
            _turnViewIndex = -1;
            for (var i = 0; i < MaxSeats; i++)
            {
                var serverSeat = (mySeat + i + MaxSeats) % MaxSeats;
                var seat = serverSeat < (room.seats?.Length ?? 0) ? room.seats[serverSeat] : null;
                var onTurn = isBetting && turnSeat == serverSeat;
                if (onTurn) _turnViewIndex = i;
                _seatViews[i].Render(seat, onTurn, serverSeat == room.dealerSeat, myUserId,
                    room.chipsHidden);
            }

            // The server sends the deadline for whoever is to act, not just for
            // this player, so every pod can run its own clock.
            if (_turnViewIndex >= 0 && turn != null && turn.deadline > 0)
            {
                var remaining = (turn.deadline - NowMs()) / 1000f;
                _seatTurnEndsAt = Time.realtimeSinceStartup + Mathf.Max(0f, remaining);
            }
            else
            {
                _seatTurnEndsAt = 0f;
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
            _options = options;
            _myTurn = options != null;
            RenderActionBar();
        }

        /// <summary>
        /// Draws the bottom bar. It is always there — Pack, the stake stepper
        /// and Chaal keep their places whoever is to act, and simply go dead
        /// between turns. A bar that disappears and comes back moves the buttons
        /// under the player's thumb, which is how misclicks happen.
        /// </summary>
        private void RenderActionBar()
        {
            _actionButtons.Clear();
            ClearZone(_actionLeft);
            ClearZone(_actionRow);
            ClearZone(_actionRight);

            var live = _myTurn && _options != null;
            var options = live ? _options : null;

            var pack = AddAction(_actionLeft, "Pack", GameAction.Pack,
                UiFactory.Scheme.ErrorContainer, UiFactory.Scheme.OnErrorContainer);
            pack.interactable = live && options.canPack;

            AddBetControl(options, live);

            // Seeing your cards is offered on the cards themselves.
            if (_seeButton != null) _seeButton.gameObject.SetActive(live && options.canSee);

            // Show is only ever offered on the player's own turn, so it is the
            // one part of the bar that does come and go.
            if (live && options.show > 0)
            {
                AddAction(_actionRight, "Show\n" + options.show.ToString("N0"), GameAction.Show,
                    UiFactory.Scheme.TertiaryContainer, UiFactory.Scheme.OnTertiaryContainer);
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
        private void AddBetControl(TurnOptionsDto options, bool live)
        {
            // Between turns there are no rungs to walk, so the readout falls
            // back to the table's stake just to have something sensible on it.
            var steps = options?.raiseSteps;
            if (steps == null || steps.Length == 0)
            {
                steps = new[] { _lastRoom?.stake ?? 0 };
            }

            _raiseIndex = Mathf.Clamp(_raiseIndex, 0, steps.Length - 1);
            var amount = steps[_raiseIndex];

            var minus = UiFactory.CreateButton("BetDown", _actionRow, "−", () =>
            {
                _raiseIndex = Mathf.Max(0, _raiseIndex - 1);
                RenderActionBar();
            }, UiFactory.Tonal, UiFactory.Gold, 34);
            minus.interactable = live && _raiseIndex > 0;
            _actionButtons.Add(minus);
            SetFlexWidth(minus.gameObject, 0.35f);

            var readout = UiFactory.CreateRounded("BetAmount", _actionRow,
                UiFactory.Scheme.Surface3, 30);
            var readoutText = UiFactory.CreateText("Value", readout.transform,
                amount.ToString("N0"), 40, TextAnchor.MiddleCenter, UiFactory.Gold, FontStyle.Bold);
            UiFactory.Stretch(readoutText.rectTransform, 8f);
            SetFlexWidth(readout.gameObject, 1.6f);

            var chaal = UiFactory.CreateButton("BetChaal", _actionRight,
                "Chaal\n" + amount.ToString("N0"),
                () =>
                {
                    ClearActions();
                    // Anything above the base rung is a raise to the server and
                    // to the hand history, even though it is one button here.
                    var action = amount == steps[0] ? GameAction.Chaal : GameAction.Raise;
                    BetRequested?.Invoke(action, amount);
                },
                UiFactory.Gold, UiFactory.OnGold, 24);
            chaal.interactable = live;
            _actionButtons.Add(chaal);

            var atTop = _raiseIndex >= steps.Length - 1;
            var plus = UiFactory.CreateButton("BetUp", _actionRow, "+", () =>
            {
                _raiseIndex = Mathf.Min(steps.Length - 1, _raiseIndex + 1);
                RenderActionBar();
            }, UiFactory.Tonal, UiFactory.Gold, 34);
            plus.interactable = live && !atTop;
            _actionButtons.Add(plus);
            SetFlexWidth(plus.gameObject, 0.35f);

            // Tell the player why "+" stopped: they have hit their own stack or
            // the table's pot limit.
            if (live && atTop && steps.Length > 1 && options.chips > 0)
            {
                SetStatus("Max bet " + amount.ToString("N0") + "  ·  you have " + options.chips.ToString("N0"));
            }
        }

        private static void SetFlexWidth(GameObject go, float weight)
        {
            var element = go.GetComponent<LayoutElement>() ?? go.AddComponent<LayoutElement>();
            element.flexibleWidth = weight;
        }

        private Button AddAction(RectTransform zone, string label, string action,
            Color background, Color? textColor = null)
        {
            var button = UiFactory.CreateButton("Action_" + action, zone, label, () =>
            {
                // Disable immediately: the turn is over the moment this is sent,
                // and a double tap would be a second (illegal) action.
                ClearActions();
                ActionRequested?.Invoke(action);
            }, background, textColor, 26);

            _actionButtons.Add(button);
            return button;
        }


        /// <summary>
        /// The player can no longer act — they have just moved, or it is someone
        /// else's turn. The bar stays put and goes dead.
        /// </summary>
        public void ClearActions()
        {
            _myTurn = false;
            RenderActionBar();
        }

        private static void ClearZone(RectTransform zone)
        {
            if (zone == null) return;
            for (var i = zone.childCount - 1; i >= 0; i--)
            {
                UnityEngine.Object.Destroy(zone.GetChild(i).gameObject);
            }
        }

        // ---------------------------------------------------------- showdown

        /// <summary>
        /// Requirement 14: shows every revealed hand to everyone at the table,
        /// with the winner and the amount across the middle.
        ///
        /// The reveals come from the server; a client is never sent a card it
        /// should not see, so nothing here can leak a hand early.
        /// </summary>
        public void ShowShowdown(RevealDto[] reveals, string resultLine, string myUserId)
        {
            ClearShowdown();
            // The seats were added to the felt after this panel, so without this
            // the pods and their chips show through the reveal.
            _showdownPanel.SetAsLastSibling();
            if ((reveals == null || reveals.Length == 0) && string.IsNullOrEmpty(resultLine)) return;

            foreach (var reveal in reveals ?? Array.Empty<RevealDto>())
            {
                var column = UiFactory.CreateRect("Reveal_" + reveal.seatIndex, _showdownHands);
                var layout = column.gameObject.AddComponent<VerticalLayoutGroup>();
                layout.spacing = 4f;
                layout.childAlignment = TextAnchor.MiddleCenter;
                layout.childControlWidth = true;
                layout.childControlHeight = false;
                layout.childForceExpandWidth = true;

                var element = column.gameObject.AddComponent<LayoutElement>();
                element.preferredWidth = 220f;

                var who = UiFactory.CreateText("Who", column,
                    (reveal.userId == myUserId ? "YOU" : Truncate(reveal.handName == null ? "" : NameFor(reveal.userId), 12))
                        + (reveal.won ? "  WON" : string.Empty),
                    24, TextAnchor.MiddleCenter,
                    reveal.won ? UiFactory.Good : UiFactory.Ink, FontStyle.Bold);
                UiFactory.SetHeight(who.gameObject, 34);

                var cards = UiFactory.CreateRect("Cards", column);
                var cardRow = cards.gameObject.AddComponent<HorizontalLayoutGroup>();
                cardRow.spacing = 5f;
                cardRow.childAlignment = TextAnchor.MiddleCenter;
                cardRow.childControlWidth = false;
                cardRow.childControlHeight = false;
                cardRow.childForceExpandWidth = false;
                UiFactory.SetHeight(cards.gameObject, 96);

                foreach (var code in reveal.cards ?? Array.Empty<string>())
                {
                    var card = UiFactory.CreateRounded("Card", cards, CardView.Face, UiFactory.ShapeMedium);
                    var size = card.gameObject.AddComponent<LayoutElement>();
                    size.preferredWidth = 62f;
                    size.preferredHeight = 90f;

                    var colour = Card.ColorOf(code);

                    var face = UiFactory.CreateText("Face", card.transform, Card.RankOf(code), 32,
                        TextAnchor.MiddleCenter, colour, FontStyle.Bold);
                    UiFactory.Anchor(face.rectTransform, new Vector2(0f, 0.44f), new Vector2(1f, 0.94f),
                        Vector2.zero, Vector2.zero);

                    var pip = UiFactory.CreateImage("Pip", card.transform, colour);
                    pip.sprite = UiFactory.SuitSprite(Card.SuitOf(code));
                    pip.preserveAspect = true;
                    pip.raycastTarget = false;
                    UiFactory.Anchor(pip.rectTransform, new Vector2(0.24f, 0.08f),
                        new Vector2(0.76f, 0.44f), Vector2.zero, Vector2.zero);
                }

                var rank = UiFactory.CreateText("Rank", column, reveal.handName ?? string.Empty, 20,
                    TextAnchor.MiddleCenter, UiFactory.Muted);
                UiFactory.SetHeight(rank.gameObject, 28);

                _showdownItems.Add(column.gameObject);
            }

            _showdownResult.text = resultLine ?? string.Empty;
            _showdownPanel.gameObject.SetActive(true);
        }

        public void HideShowdown()
        {
            ClearShowdown();
            if (_showdownPanel != null) _showdownPanel.gameObject.SetActive(false);
            if (_showdownResult != null) _showdownResult.text = string.Empty;
        }

        private void ClearShowdown()
        {
            foreach (var item in _showdownItems)
            {
                if (item != null) UnityEngine.Object.Destroy(item);
            }
            _showdownItems.Clear();
        }

        /// <summary>Looks a player's name up from the current table snapshot.</summary>
        private string NameFor(string userId)
        {
            if (_lastRoom?.seats == null) return "Player";
            foreach (var seat in _lastRoom.seats)
            {
                if (seat.IsOccupied && seat.userId == userId) return seat.displayName;
            }
            return "Player";
        }

        private static string Truncate(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) return "Player";
            return value.Length <= max ? value : value.Substring(0, max - 1) + "\u2026";
        }

        // ----------------------------------------------------------- rewards

        /// <summary>
        /// Requirements 17 and 18: the milestone every 25 hands played, and the
        /// bonus that recharges over 4 hours. Both buttons stay disabled until
        /// the server says the reward is actually due.
        /// </summary>
        public void RenderRewards(UserDto user)
        {
            _rewards = user?.rewards;
            if (_rewards == null || _milestoneButton == null) return;

            var milestoneLabel = _rewards.milestoneAvailable
                ? "COLLECT\n" + _rewards.milestoneReward.ToString("N0")
                : "MILESTONE\n" + _rewards.handsToNextMilestone + " to go";
            SetButton(_milestoneButton, milestoneLabel, _rewards.milestoneAvailable);

            RefreshBonusButton();
        }

        /// <summary>Ticks the bonus countdown between server updates.</summary>
        private void RefreshBonusButton()
        {
            if (_rewards == null || _bonusButton == null) return;

            var ready = _rewards.IsBonusReady;
            var label = ready
                ? "COLLECT\n" + _rewards.bonusReward.ToString("N0")
                : "BONUS\n" + FormatCountdown(_rewards.MillisecondsUntilBonus);

            SetButton(_bonusButton, label, ready);
        }

        private static void SetButton(Button button, string label, bool enabled)
        {
            button.interactable = enabled;

            var image = button.targetGraphic as Image;
            if (image != null)
            {
                image.color = enabled ? UiFactory.Gold : UiFactory.Tonal;
            }

            var text = button.GetComponentInChildren<Text>();
            if (text != null)
            {
                text.text = label;
                text.color = enabled ? UiFactory.OnGold : UiFactory.Muted;
            }
        }

        /// <summary>
        /// Formats the bonus countdown. Seconds are always shown (requirement
        /// 26), so the timer visibly ticks instead of resting on a minute.
        /// </summary>
        public static string FormatCountdown(long milliseconds)
        {
            var total = Math.Max(0, milliseconds / 1000);
            var hours = total / 3600;
            var minutes = (total % 3600) / 60;
            var seconds = total % 60;

            if (hours > 0) return hours + "h " + minutes + "m " + seconds + "s";
            if (minutes > 0) return minutes + "m " + seconds + "s";
            return seconds + "s";
        }

        public void SetRewardMessage(string message)
        {
            if (_rewardText != null) _rewardText.text = message ?? string.Empty;
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
            // Pulse the seat whose turn it is, so the table shows at a glance
            // who everyone is waiting for, and fill it as their clock runs down.
            var elapsed = -1f;
            if (_seatTurnEndsAt > 0f && _turnTotalSeconds > 0f)
            {
                var left = _seatTurnEndsAt - Time.realtimeSinceStartup;
                elapsed = Mathf.Clamp01(1f - left / _turnTotalSeconds);
            }

            for (var i = 0; i < _seatViews.Length; i++)
            {
                _seatViews[i]?.TickHighlight(i == _turnViewIndex ? elapsed : -1f);
            }

            // The bonus countdown ticks locally between server updates.
            if (Time.realtimeSinceStartup - _lastRewardTick >= 1f)
            {
                _lastRewardTick = Time.realtimeSinceStartup;
                RefreshBonusButton();
            }

            if (_turnDeadline <= 0f) return;

            var remaining = _turnDeadline - Time.realtimeSinceStartup;
            if (remaining <= 0f)
            {
                StopTimer();
                return;
            }

            if (_timerFill != null)
            {
                _timerFill.fillAmount = Mathf.Clamp01(remaining / _turnTotalSeconds);
                _timerFill.color = remaining < 6f ? UiFactory.Danger : UiFactory.Gold;
            }
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
