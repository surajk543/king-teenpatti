using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

namespace KingTeenPatti.Net
{
    /// <summary>
    /// A compact Socket.IO v4 (Engine.IO v4) client for Unity.
    ///
    /// There is no official Unity client for Socket.IO, and the protocol is
    /// small enough to speak directly. Only the websocket transport is used —
    /// no polling upgrade dance — which is what every supported platform
    /// (Android, iOS, WebGL) can do natively.
    ///
    /// Wire format, for reference:
    ///   "0{...}"        Engine.IO OPEN, carries sid and ping interval
    ///   "2" / "3"       PING from server / PONG from client
    ///   "40{auth}"      Socket.IO CONNECT (auth object goes here)
    ///   "42[\"ev\",{}]" EVENT
    ///   "42N[...]"      EVENT expecting ack N
    ///   "43N[...]"      ACK N
    /// </summary>
    public class SocketIOClient
    {
        private const int PingIntervalFallbackMs = 25000;

        private readonly IWebSocket _socket;
        private readonly Dictionary<string, List<Action<string>>> _handlers =
            new Dictionary<string, List<Action<string>>>();
        private readonly Dictionary<int, Action<string>> _acks = new Dictionary<int, Action<string>>();

        private string _url;
        private string _authJson = "{}";
        private int _nextAckId = 1;
        private float _pingDeadline;
        private bool _connectSent;

        public bool IsConnected { get; private set; }

        public event Action OnConnected;
        public event Action<string> OnDisconnected;
        public event Action<string> OnError;

        public SocketIOClient(IWebSocket socket)
        {
            _socket = socket;
            _socket.OnOpen += HandleOpen;
            _socket.OnMessage += HandleMessage;
            _socket.OnError += error => OnError?.Invoke(error);
            _socket.OnClose += code =>
            {
                IsConnected = false;
                _connectSent = false;
                OnDisconnected?.Invoke($"closed ({code})");
            };
        }

        /// <summary>
        /// Opens the connection. <paramref name="baseUrl"/> is the plain HTTP
        /// server address (e.g. "http://localhost:3000"); the websocket URL and
        /// Engine.IO query string are derived from it.
        /// </summary>
        public void Connect(string baseUrl, string authToken)
        {
            _authJson = "{\"token\":\"" + Json.Escape(authToken) + "\"}";

            var wsUrl = baseUrl.TrimEnd('/')
                .Replace("https://", "wss://")
                .Replace("http://", "ws://");

            _url = wsUrl + "/socket.io/?EIO=4&transport=websocket";
            _socket.Connect(_url);
        }

        public void Disconnect()
        {
            if (_socket.State == WebSocketState.Open) _socket.Send("41"); // Socket.IO DISCONNECT
            _socket.Close();
            IsConnected = false;
        }

        /// <summary>Call once per frame from a MonoBehaviour's Update.</summary>
        public void Update()
        {
            _socket.Poll();

            // Engine.IO expects the client to answer server pings. If the server
            // has gone quiet past the interval, treat the link as dead so the
            // UI can show a reconnect state rather than hanging on a live-looking
            // socket.
            if (IsConnected && _pingDeadline > 0f && Time.realtimeSinceStartup > _pingDeadline)
            {
                _pingDeadline = 0f;
                IsConnected = false;
                OnDisconnected?.Invoke("ping timeout");
                _socket.Close();
            }
        }

        // ------------------------------------------------------------ emitting

        /// <summary>Emits an event whose payload is already a JSON object string.</summary>
        public void Emit(string eventName, string jsonPayload = "{}")
        {
            if (_socket.State != WebSocketState.Open) return;
            _socket.Send("42[\"" + Json.Escape(eventName) + "\"," + jsonPayload + "]");
        }

        /// <summary>Emits an event and invokes <paramref name="onAck"/> with the server's reply.</summary>
        public void Emit(string eventName, string jsonPayload, Action<string> onAck)
        {
            if (_socket.State != WebSocketState.Open) return;

            var ackId = _nextAckId++;
            _acks[ackId] = onAck;
            _socket.Send("42" + ackId + "[\"" + Json.Escape(eventName) + "\"," + jsonPayload + "]");
        }

        /// <summary>Registers a handler receiving the event's first argument as raw JSON.</summary>
        public void On(string eventName, Action<string> handler)
        {
            if (!_handlers.TryGetValue(eventName, out var list))
            {
                list = new List<Action<string>>();
                _handlers[eventName] = list;
            }
            list.Add(handler);
        }

        /// <summary>Registers a handler that receives the payload deserialized into T.</summary>
        public void On<T>(string eventName, Action<T> handler)
        {
            On(eventName, json =>
            {
                try
                {
                    handler(JsonUtility.FromJson<T>(json));
                }
                catch (Exception error)
                {
                    Debug.LogError($"[SocketIO] failed to parse '{eventName}': {error.Message}\n{json}");
                }
            });
        }

        // ------------------------------------------------------------ receiving

        private void HandleOpen()
        {
            _pingDeadline = Time.realtimeSinceStartup + (PingIntervalFallbackMs / 1000f) * 2f;
        }

        private void HandleMessage(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return;

            switch (raw[0])
            {
                case '0': // Engine.IO OPEN
                    HandleEngineOpen(raw.Substring(1));
                    return;

                case '2': // Engine.IO PING
                    _socket.Send("3");
                    BumpPingDeadline();
                    return;

                case '3': // Engine.IO PONG
                    BumpPingDeadline();
                    return;

                case '4': // Engine.IO MESSAGE — the Socket.IO layer starts here
                    HandleSocketIoPacket(raw.Substring(1));
                    return;

                default:
                    return;
            }
        }

        private void HandleEngineOpen(string json)
        {
            var interval = Json.GetInt(json, "pingInterval", PingIntervalFallbackMs);
            var timeout = Json.GetInt(json, "pingTimeout", 20000);
            _pingIntervalMs = interval + timeout;
            BumpPingDeadline();

            if (_connectSent) return;
            _connectSent = true;
            // Socket.IO CONNECT, carrying the auth object the server reads as
            // socket.handshake.auth.
            _socket.Send("40" + _authJson);
        }

        private int _pingIntervalMs = PingIntervalFallbackMs + 20000;

        private void BumpPingDeadline()
        {
            _pingDeadline = Time.realtimeSinceStartup + (_pingIntervalMs / 1000f) + 5f;
        }

        private void HandleSocketIoPacket(string body)
        {
            if (body.Length == 0) return;

            var type = body[0];
            var rest = body.Substring(1);

            switch (type)
            {
                case '0': // CONNECT acknowledged
                    IsConnected = true;
                    OnConnected?.Invoke();
                    return;

                case '1': // DISCONNECT
                    IsConnected = false;
                    OnDisconnected?.Invoke("server disconnect");
                    return;

                case '4': // CONNECT_ERROR
                    OnError?.Invoke(Json.GetString(rest, "message", rest));
                    return;

                case '2': // EVENT
                    HandleEvent(rest);
                    return;

                case '3': // ACK
                    HandleAck(rest);
                    return;

                default:
                    return;
            }
        }

        private void HandleEvent(string rest)
        {
            // rest is either "[...]" or "<ackId>[...]" — we never ask the server
            // to ack us, so any leading digits are simply skipped.
            var bracket = rest.IndexOf('[');
            if (bracket < 0) return;

            var array = rest.Substring(bracket);
            var eventName = Json.FirstArrayString(array);
            if (eventName == null) return;

            var payload = Json.SecondArrayElement(array) ?? "{}";

            if (!_handlers.TryGetValue(eventName, out var list)) return;
            // Copy first: a handler may unsubscribe or emit during dispatch.
            foreach (var handler in list.ToArray())
            {
                try
                {
                    handler(payload);
                }
                catch (Exception error)
                {
                    Debug.LogError($"[SocketIO] handler for '{eventName}' threw: {error}");
                }
            }
        }

        private void HandleAck(string rest)
        {
            var bracket = rest.IndexOf('[');
            if (bracket <= 0) return;

            if (!int.TryParse(rest.Substring(0, bracket), out var ackId)) return;
            if (!_acks.TryGetValue(ackId, out var callback)) return;
            _acks.Remove(ackId);

            var array = rest.Substring(bracket);
            var payload = Json.FirstArrayElement(array) ?? "{}";

            try
            {
                callback(payload);
            }
            catch (Exception error)
            {
                Debug.LogError($"[SocketIO] ack {ackId} threw: {error}");
            }
        }
    }

    /// <summary>
    /// Just enough JSON handling for this protocol.
    ///
    /// Unity's JsonUtility deserializes the payload objects, but it cannot read
    /// a top-level array, so the Socket.IO envelope "[\"event\",{...}]" is split
    /// by hand. The scanners below are string-literal aware, so braces or
    /// brackets inside a player's display name cannot throw off the split.
    /// </summary>
    public static class Json
    {
        public static string Escape(string value)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;

            var builder = new StringBuilder(value.Length + 8);
            foreach (var c in value)
            {
                switch (c)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (c < 0x20) builder.Append("\\u").Append(((int)c).ToString("x4"));
                        else builder.Append(c);
                        break;
                }
            }
            return builder.ToString();
        }

        /// <summary>Reads the first element of a JSON array when it is a string.</summary>
        public static string FirstArrayString(string array)
        {
            var index = SkipWhitespace(array, 1);
            if (index >= array.Length || array[index] != '"') return null;

            var end = FindStringEnd(array, index);
            if (end < 0) return null;

            return Unescape(array.Substring(index + 1, end - index - 1));
        }

        /// <summary>Returns the first element of a JSON array as raw JSON.</summary>
        public static string FirstArrayElement(string array) => ElementAt(array, 0);

        /// <summary>Returns the second element of a JSON array as raw JSON.</summary>
        public static string SecondArrayElement(string array) => ElementAt(array, 1);

        private static string ElementAt(string array, int wanted)
        {
            var index = SkipWhitespace(array, 1);
            var element = 0;

            while (index < array.Length && array[index] != ']')
            {
                var end = FindValueEnd(array, index);
                if (end < 0) return null;

                if (element == wanted) return array.Substring(index, end - index).Trim();

                element++;
                index = SkipWhitespace(array, end);
                if (index < array.Length && array[index] == ',') index = SkipWhitespace(array, index + 1);
            }

            return null;
        }

        /// <summary>Index just past the value that starts at <paramref name="start"/>.</summary>
        private static int FindValueEnd(string json, int start)
        {
            if (start >= json.Length) return -1;

            var c = json[start];
            if (c == '"')
            {
                var end = FindStringEnd(json, start);
                return end < 0 ? -1 : end + 1;
            }

            if (c == '{' || c == '[')
            {
                var open = c;
                var close = c == '{' ? '}' : ']';
                var depth = 0;
                var inString = false;

                for (var i = start; i < json.Length; i++)
                {
                    var ch = json[i];

                    if (inString)
                    {
                        if (ch == '\\') i++;
                        else if (ch == '"') inString = false;
                        continue;
                    }

                    if (ch == '"') inString = true;
                    else if (ch == open) depth++;
                    else if (ch == close)
                    {
                        depth--;
                        if (depth == 0) return i + 1;
                    }
                }
                return -1;
            }

            // A bare literal: number, true, false or null.
            var scan = start;
            while (scan < json.Length && json[scan] != ',' && json[scan] != ']' && json[scan] != '}') scan++;
            return scan;
        }

        private static int FindStringEnd(string json, int quoteIndex)
        {
            for (var i = quoteIndex + 1; i < json.Length; i++)
            {
                if (json[i] == '\\') { i++; continue; }
                if (json[i] == '"') return i;
            }
            return -1;
        }

        private static int SkipWhitespace(string json, int index)
        {
            while (index < json.Length && char.IsWhiteSpace(json[index])) index++;
            return index;
        }

        private static string Unescape(string value)
        {
            if (value.IndexOf('\\') < 0) return value;

            var builder = new StringBuilder(value.Length);
            for (var i = 0; i < value.Length; i++)
            {
                if (value[i] != '\\') { builder.Append(value[i]); continue; }

                i++;
                if (i >= value.Length) break;

                switch (value[i])
                {
                    case 'n': builder.Append('\n'); break;
                    case 'r': builder.Append('\r'); break;
                    case 't': builder.Append('\t'); break;
                    case 'u':
                        if (i + 4 < value.Length &&
                            int.TryParse(value.Substring(i + 1, 4),
                                System.Globalization.NumberStyles.HexNumber,
                                System.Globalization.CultureInfo.InvariantCulture,
                                out var code))
                        {
                            builder.Append((char)code);
                            i += 4;
                        }
                        break;
                    default: builder.Append(value[i]); break;
                }
            }
            return builder.ToString();
        }

        /// <summary>Shallow lookup of a top-level string field. Not a general parser.</summary>
        public static string GetString(string json, string field, string fallback = null)
        {
            var key = "\"" + field + "\"";
            var index = json.IndexOf(key, StringComparison.Ordinal);
            if (index < 0) return fallback;

            index = json.IndexOf(':', index + key.Length);
            if (index < 0) return fallback;

            index = SkipWhitespace(json, index + 1);
            if (index >= json.Length || json[index] != '"') return fallback;

            var end = FindStringEnd(json, index);
            return end < 0 ? fallback : Unescape(json.Substring(index + 1, end - index - 1));
        }

        /// <summary>Shallow lookup of a top-level integer field.</summary>
        public static int GetInt(string json, string field, int fallback = 0)
        {
            var key = "\"" + field + "\"";
            var index = json.IndexOf(key, StringComparison.Ordinal);
            if (index < 0) return fallback;

            index = json.IndexOf(':', index + key.Length);
            if (index < 0) return fallback;

            index = SkipWhitespace(json, index + 1);
            var end = index;
            while (end < json.Length && (char.IsDigit(json[end]) || json[end] == '-')) end++;

            return int.TryParse(json.Substring(index, end - index), out var value) ? value : fallback;
        }

        public static bool GetBool(string json, string field, bool fallback = false)
        {
            var key = "\"" + field + "\"";
            var index = json.IndexOf(key, StringComparison.Ordinal);
            if (index < 0) return fallback;

            index = json.IndexOf(':', index + key.Length);
            if (index < 0) return fallback;

            index = SkipWhitespace(json, index + 1);
            if (index + 4 <= json.Length && json.Substring(index, 4) == "true") return true;
            if (index + 5 <= json.Length && json.Substring(index, 5) == "false") return false;
            return fallback;
        }
    }
}
