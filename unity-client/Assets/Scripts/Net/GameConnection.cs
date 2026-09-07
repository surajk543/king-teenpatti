using System;
using KingTeenPatti.Models;
using UnityEngine;

namespace KingTeenPatti.Net
{
    /// <summary>
    /// Typed wrapper over <see cref="SocketIOClient"/>.
    ///
    /// This is the only class the game code talks to: it turns raw Socket.IO
    /// events into C# events carrying parsed DTOs, and turns method calls into
    /// the JSON the server expects. Every event fires on the Unity main thread.
    /// </summary>
    public class GameConnection
    {
        private readonly SocketIOClient _socket;

        public bool IsConnected => _socket.IsConnected;

        // Session
        public event Action<SessionReadyDto> SessionReady;
        public event Action<SessionReplacedDto> SessionReplaced;
        public event Action Connected;
        public event Action<string> Disconnected;
        public event Action<string> TransportError;

        // Room
        public event Action<RoomStateDto> RoomJoined;
        public event Action<RoomStateDto> RoomStateChanged;
        public event Action RoomLeft;
        public event Action RoomClosed;
        /// <summary>Requirement 24: merged onto a busier table.</summary>
        public event Action<RoomMovedDto> RoomMoved;

        // Game
        public event Action<HandStartedDto> HandStarted;
        public event Action<TurnChangedDto> TurnChanged;
        public event Action<YourTurnDto> YourTurn;
        public event Action<ActionDto> PlayerActed;
        public event Action<ShowdownDto> Showdown;
        public event Action<HandEndedDto> HandEnded;
        public event Action<PlayerCardsDto> CardsReceived;
        public event Action<GameErrorDto> GameError;

        // Room chat
        public event Action<ChatMessageDto> ChatReceived;
        public event Action<ChatHistoryDto> ChatHistoryReceived;

        public GameConnection()
        {
            _socket = new SocketIOClient(CreateWebSocket());

            _socket.OnConnected += () => Connected?.Invoke();
            _socket.OnDisconnected += reason => Disconnected?.Invoke(reason);
            _socket.OnError += error => TransportError?.Invoke(error);

            _socket.On<SessionReadyDto>("session:ready", payload => SessionReady?.Invoke(payload));
            _socket.On<SessionReplacedDto>("session:replaced", payload => SessionReplaced?.Invoke(payload));

            _socket.On<RoomStateDto>("room:joined", payload => RoomJoined?.Invoke(payload));
            _socket.On<RoomStateDto>("room:state", payload => RoomStateChanged?.Invoke(payload));
            _socket.On("room:left", _ => RoomLeft?.Invoke());
            _socket.On("room:closed", _ => RoomClosed?.Invoke());
            _socket.On<RoomMovedDto>("room:moved", payload => RoomMoved?.Invoke(payload));

            _socket.On<HandStartedDto>("game:handStarted", payload => HandStarted?.Invoke(payload));
            _socket.On<TurnChangedDto>("game:turn", payload => TurnChanged?.Invoke(payload));
            _socket.On<YourTurnDto>("game:yourTurn", payload => YourTurn?.Invoke(payload));
            _socket.On<ActionDto>("game:action", payload => PlayerActed?.Invoke(payload));
            _socket.On<ShowdownDto>("game:showdown", payload => Showdown?.Invoke(payload));
            _socket.On<HandEndedDto>("game:handEnded", payload => HandEnded?.Invoke(payload));
            _socket.On<PlayerCardsDto>("player:cards", payload => CardsReceived?.Invoke(payload));
            _socket.On<GameErrorDto>("game:error", payload => GameError?.Invoke(payload));
            _socket.On<ChatMessageDto>("chat:message", payload => ChatReceived?.Invoke(payload));
            _socket.On<ChatHistoryDto>("chat:history", payload => ChatHistoryReceived?.Invoke(payload));
        }

        /// <summary>Picks the transport this platform can actually use.</summary>
        private static IWebSocket CreateWebSocket()
        {
#if UNITY_WEBGL && !UNITY_EDITOR
            return new WebGLWebSocket();
#else
            return new SystemWebSocket();
#endif
        }

        public void Connect(string baseUrl, string sessionToken) => _socket.Connect(baseUrl, sessionToken);

        public void Disconnect() => _socket.Disconnect();

        /// <summary>Pump the socket; call from Update.</summary>
        public void Tick() => _socket.Update();

        // ------------------------------------------------------------- lobby

        /// <summary>
        /// Seats the player at any table with room at this stake and category,
        /// creating one if none has a free seat. Blind and seen tables at the
        /// same stake are separate rooms.
        /// </summary>
        public void QuickJoin(long bootAmount, string category = TableCategory.Seen,
            Action<JoinAckDto> onResult = null)
        {
            var payload = "{\"bootAmount\":" + bootAmount +
                          ",\"category\":\"" + Json.Escape(category) + "\"}";
            Emit("room:quickJoin", payload, onResult);
        }

        /// <summary>
        /// Creates a table. A private table's boot is fixed by the server
        /// (requirement 22), so pass 0 for <paramref name="bootAmount"/> to let
        /// it decide; anything sent for a private table is replaced anyway.
        /// </summary>
        public void CreateTable(long bootAmount, bool isPrivate,
            string category = TableCategory.Seen, Action<JoinAckDto> onResult = null)
        {
            var boot = bootAmount > 0 ? "\"bootAmount\":" + bootAmount + "," : string.Empty;
            var payload = "{" + boot +
                          "\"isPrivate\":" + (isPrivate ? "true" : "false") +
                          ",\"category\":\"" + Json.Escape(category) + "\"}";
            Emit("room:create", payload, onResult);
        }

        public void JoinByCode(string code, Action<JoinAckDto> onResult = null)
        {
            Emit("room:joinCode", "{\"code\":\"" + Json.Escape(code) + "\"}", onResult);
        }

        public void LeaveRoom(Action<JoinAckDto> onResult = null) => Emit("room:leave", "{}", onResult);

        // ---------------------------------------------------------- gameplay

        /// <summary>Reveals your own three cards. Free, and does not pass the turn.</summary>
        public void See() => SendAction(GameAction.See);

        /// <summary>Bets the current amount.</summary>
        public void Chaal() => SendAction(GameAction.Chaal);

        /// <summary>Bets double the current amount.</summary>
        public void Raise() => SendAction(GameAction.Raise);

        /// <summary>
        /// Bets a specific amount chosen with the +/- stepper. The amount must be
        /// one of the rungs the server sent in <c>raiseSteps</c>; anything else is
        /// rejected server-side, which is what keeps a bet inside the player's stack.
        /// </summary>
        public void Bet(string action, long amount, Action<JoinAckDto> onResult = null)
        {
            var payload = "{\"action\":\"" + Json.Escape(action) + "\",\"amount\":" + amount + "}";
            Emit("game:action", payload, onResult);
        }

        /// <summary>Folds; the turn moves on without you.</summary>
        public void Pack() => SendAction(GameAction.Pack);

        /// <summary>Pays to compare hands. Only legal with two players left.</summary>
        public void Show() => SendAction(GameAction.Show);

        public void SendAction(string action, Action<JoinAckDto> onResult = null)
        {
            Emit("game:action", "{\"action\":\"" + Json.Escape(action) + "\"}", onResult);
        }

        /// <summary>Re-requests your own cards, e.g. after reconnecting mid-hand.</summary>
        public void RequestCards() => _socket.Emit("player:requestCards", "{}");

        /// <summary>
        /// Posts a message to the current room's chat. It reaches only the
        /// players at this table, and is never persisted.
        /// </summary>
        public void SendChat(string text, Action<JoinAckDto> onResult = null)
        {
            if (string.IsNullOrWhiteSpace(text)) return;
            Emit("chat:message", "{\"text\":\"" + Json.Escape(text.Trim()) + "\"}", onResult);
        }

        /// <summary>Re-pulls the room backlog, e.g. after reconnecting.</summary>
        public void RequestChatHistory() => _socket.Emit("chat:history", "{}");

        private void Emit(string eventName, string payload, Action<JoinAckDto> onResult)
        {
            if (onResult == null)
            {
                _socket.Emit(eventName, payload);
                return;
            }

            _socket.Emit(eventName, payload, json =>
            {
                JoinAckDto ack = null;
                try
                {
                    ack = JsonUtility.FromJson<JoinAckDto>(json);
                }
                catch (Exception error)
                {
                    Debug.LogError($"[GameConnection] bad ack for {eventName}: {error.Message}");
                }
                onResult(ack ?? new JoinAckDto { ok = false, message = "Malformed server reply" });
            });
        }
    }
}
