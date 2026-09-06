using System.Collections;
using KingTeenPatti.Models;
using KingTeenPatti.Net;
using KingTeenPatti.UI;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

namespace KingTeenPatti.Game
{
    /// <summary>
    /// The client entry point: owns the connection, the local view of the game,
    /// and the UI.
    ///
    /// To run it, drop this component on a single GameObject in an empty scene
    /// and press Play — the canvas, event system and every screen are created
    /// at runtime. Set <see cref="serverUrl"/> to your server.
    ///
    /// The client is deliberately not authoritative about anything: it renders
    /// server snapshots and forwards button presses. It never decides who wins,
    /// what a bet costs, or whose turn it is.
    /// </summary>
    [AddComponentMenu("King Teen Patti/Game Client")]
    public class GameClient : MonoBehaviour
    {
        [Header("Server")]
        [Tooltip("Base URL of the game server, e.g. http://localhost:3000 or https://play.example.com")]
        public string serverUrl = "http://localhost:3000";

        [Tooltip("Reuse the saved session token instead of showing the login screen.")]
        public bool autoLogin = true;

        private GameConnection _connection;
        private GameUI _ui;

        private UserDto _me;
        private RoomStateDto _room;
        private bool _busy;

        private void Awake()
        {
            Application.runInBackground = true;
            // A turn clock is running server-side; a throttled client would look
            // frozen and time players out, so keep a steady frame rate.
            Application.targetFrameRate = 60;

            EnsureEventSystem();

            var canvas = UiFactory.CreateCanvas("TeenPattiCanvas", out _);
            canvas.transform.SetParent(transform, false);

            _ui = new GameUI();
            _ui.Build(canvas.transform);
            WireUi();

            _connection = new GameConnection();
            WireConnection();

            if (autoLogin && AuthService.HasSession)
            {
                _ui.SetLoginBusy(true);
                _ui.SetLoginError("Signing in…");
                _connection.Connect(serverUrl, AuthService.SessionToken);
            }
        }

        private void Update()
        {
            _connection?.Tick();
            _ui?.Tick();
        }

        private void OnDestroy() => _connection?.Disconnect();

        private void OnApplicationQuit() => _connection?.Disconnect();

        /// <summary>
        /// On mobile the app is suspended when backgrounded and the socket dies.
        /// Reconnecting on resume restores the seat, because the server holds it
        /// for a grace period and replays the current state on connect.
        /// </summary>
        private void OnApplicationPause(bool paused)
        {
            if (paused || _connection == null || _connection.IsConnected) return;
            if (!AuthService.HasSession) return;
            _connection.Connect(serverUrl, AuthService.SessionToken);
        }

        private static void EnsureEventSystem()
        {
            // FindObjectOfType was deprecated in Unity 2022.2; keep both paths so
            // the client still builds on 2021.3 LTS.
#if UNITY_2022_2_OR_NEWER
            if (FindAnyObjectByType<EventSystem>() != null) return;
#else
            if (FindObjectOfType<EventSystem>() != null) return;
#endif
            var go = new GameObject("EventSystem", typeof(EventSystem), typeof(StandaloneInputModule));
            DontDestroyOnLoad(go);
        }

        // ------------------------------------------------------------ UI wiring

        private void WireUi()
        {
            _ui.GuestLoginRequested += name => StartLogin(AuthService.LoginAsGuest(serverUrl, name, OnLoggedIn, OnLoginFailed));
            _ui.GoogleLoginRequested += () => StartLogin(AuthService.LoginWithGoogle(serverUrl, OnLoggedIn, OnLoginFailed));
            _ui.FacebookLoginRequested += () => StartLogin(AuthService.LoginWithFacebook(serverUrl, OnLoggedIn, OnLoginFailed));

            _ui.QuickJoinRequested += (boot, category) => _connection.QuickJoin(boot, category, OnJoinResult);
            _ui.CreateTableRequested += (boot, category) =>
                _connection.CreateTable(boot, true, category, OnJoinResult);
            _ui.JoinCodeRequested += code =>
            {
                if (string.IsNullOrEmpty(code))
                {
                    _ui.SetLobbyError("Enter a table code first.");
                    return;
                }
                _connection.JoinByCode(code, OnJoinResult);
            };

            _ui.LeaveRequested += () => _connection.LeaveRoom();
            _ui.ActionRequested += action => _connection.SendAction(action);
            // A bet carries the exact amount picked on the +/- stepper; the
            // server re-validates it against the ladder before taking any chips.
            _ui.BetRequested += (action, amount) => _connection.Bet(action, amount, ack =>
            {
                if (ack != null && !ack.ok) _ui.SetStatus(ack.message);
            });

            _ui.Chat.MessageSubmitted += text => _connection.SendChat(text, ack =>
            {
                // Surface a refusal (rate limit, or not being at a table) in the
                // panel rather than silently dropping the message.
                _ui.Chat.SetError(ack != null && !ack.ok ? ack.message : string.Empty);
            });
        }

        private void StartLogin(IEnumerator routine)
        {
            if (_busy) return;
            _busy = true;
            _ui.SetLoginBusy(true);
            _ui.SetLoginError(string.Empty);
            StartCoroutine(RunLogin(routine));
        }

        private IEnumerator RunLogin(IEnumerator routine)
        {
            yield return routine;
            _busy = false;
            _ui.SetLoginBusy(false);
        }

        private void OnLoggedIn(LoginResponse response)
        {
            _me = response.user;
            _ui.SetPlayerHeader(_me);

            if (response.isNew)
            {
                _ui.SetLobbyError($"Welcome! {response.welcomeChips:N0} chips added to your account.");
            }

            _connection.Connect(serverUrl, response.token);
        }

        private void OnLoginFailed(string message)
        {
            _busy = false;
            _ui.SetLoginBusy(false);
            _ui.SetLoginError(message);
            _ui.ShowLogin();
        }

        private void OnJoinResult(JoinAckDto ack)
        {
            if (ack == null || ack.ok) return;
            _ui.SetLobbyError(ack.message ?? "Could not join that table.");
        }

        // ---------------------------------------------------- connection wiring

        private void WireConnection()
        {
            _connection.SessionReady += payload =>
            {
                _me = payload.user;
                _ui.SetLoginBusy(false);
                _ui.SetPlayerHeader(_me);
                _ui.Chat.SetLocalUser(_me?.id);
                // The lobby offers whatever stakes the server is configured with.
                _ui.SetLobbyOptions(payload.config);
                _ui.ShowLobby();
            };

            _connection.Disconnected += reason =>
            {
                _ui.SetStatus("Disconnected — " + reason);
                _ui.SetLobbyError("Connection lost. Reopen the app to reconnect.");
            };

            _connection.TransportError += error => Debug.LogWarning("[TeenPatti] transport: " + error);

            _connection.SessionReplaced += payload =>
            {
                _ui.ShowLogin();
                _ui.SetLoginError(payload?.message ?? "Signed in from another device.");
            };

            _connection.RoomJoined += room =>
            {
                _room = room;
                _ui.ShowTable();
                _ui.RenderRoom(room, _me?.id);
                _ui.Log("Joined table " + room.code + ".");
            };

            _connection.RoomStateChanged += room =>
            {
                _room = room;
                _ui.RenderRoom(room, _me?.id);
            };

            _connection.RoomLeft += () =>
            {
                _room = null;
                _ui.SetLobbyError(string.Empty);
                _ui.ShowLobby();
            };

            _connection.RoomClosed += () =>
            {
                _room = null;
                _ui.ShowLobby();
                _ui.SetLobbyError("That table closed.");
            };

            _connection.HandStarted += payload =>
                _ui.Log($"— Hand #{payload.handNo} dealt. Pot {payload.pot:N0}. —");

            _connection.TurnChanged += payload =>
            {
                if (payload.userId == _me?.id) _ui.SetStatus("YOUR TURN");
                _ui.StartTimer(payload.deadline);
            };

            // Only the player on turn receives this, with the exact legal moves.
            _connection.YourTurn += payload =>
            {
                _ui.BeginTurn(payload.options);
                _ui.StartTimer(payload.deadline);
                _ui.SetStatus("YOUR TURN");
            };

            _connection.CardsReceived += payload => _ui.ShowOwnCards(payload.cards);

            _connection.PlayerActed += payload =>
            {
                var who = payload.userId == _me?.id ? "You" : NameOf(payload.userId);
                var amount = payload.amount > 0 ? " " + payload.amount.ToString("N0") : string.Empty;
                var suffix = payload.reason == "timeout" ? " (timed out)" : string.Empty;
                _ui.Log($"{who}: {payload.action}{amount}{suffix}");

                if (payload.userId == _me?.id && payload.action != GameAction.See)
                {
                    _ui.ClearActions();
                    _ui.StopTimer();
                }
            };

            _connection.Showdown += payload =>
            {
                foreach (var reveal in payload.reveals)
                {
                    var who = reveal.userId == _me?.id ? "You" : NameOf(reveal.userId);
                    _ui.Log($"{who}: {Card.PrettyHand(reveal.cards)} — {reveal.handName}");
                }
            };

            _connection.HandEnded += payload =>
            {
                _ui.StopTimer();
                _ui.ClearActions();

                var won = payload.winnerId == _me?.id;
                var who = won ? "You win" : (payload.winnerName ?? "Nobody") + " wins";
                _ui.SetStatus($"{who} {payload.pot:N0}");
                _ui.Log($"{who} the pot of {payload.pot:N0} ({payload.reason.Replace('_', ' ')}).");
            };

            _connection.GameError += payload =>
            {
                _ui.SetStatus(payload.message);
                _ui.SetLobbyError(payload.message);
                _ui.Log("⚠ " + payload.message);
            };

            // Room chat: the backlog arrives on join, then live messages.
            _connection.ChatHistoryReceived += payload => _ui.Chat.SetHistory(payload.messages);
            _connection.ChatReceived += payload => _ui.Chat.Append(payload);
        }

        private string NameOf(string userId)
        {
            if (_room?.seats == null) return "Player";
            foreach (var seat in _room.seats)
            {
                if (seat.IsOccupied && seat.userId == userId) return seat.displayName;
            }
            return "Player";
        }
    }
}
