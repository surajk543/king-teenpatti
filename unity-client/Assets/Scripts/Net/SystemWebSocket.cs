#if !UNITY_WEBGL || UNITY_EDITOR
using System;
using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace KingTeenPatti.Net
{
    /// <summary>
    /// WebSocket transport built on <see cref="ClientWebSocket"/>, used on
    /// Android, iOS, desktop and in the Editor.
    ///
    /// Receiving happens on a background task; everything it produces is parked
    /// on a concurrent queue and replayed from <see cref="Poll"/> so game code
    /// only ever runs on Unity's main thread.
    /// </summary>
    public class SystemWebSocket : IWebSocket
    {
        private const int ReceiveBufferSize = 8 * 1024;

        private ClientWebSocket _socket;
        private CancellationTokenSource _cancellation;
        private readonly ConcurrentQueue<Action> _mainThreadQueue = new ConcurrentQueue<Action>();

        public WebSocketState State { get; private set; } = WebSocketState.Closed;

        public event Action OnOpen;
        public event Action<string> OnMessage;
        public event Action<string> OnError;
        public event Action<int> OnClose;

        public void Connect(string url)
        {
            if (State == WebSocketState.Open || State == WebSocketState.Connecting) return;

            State = WebSocketState.Connecting;
            _socket = new ClientWebSocket();
            _cancellation = new CancellationTokenSource();

            Task.Run(async () =>
            {
                try
                {
                    await _socket.ConnectAsync(new Uri(url), _cancellation.Token);
                    Enqueue(() =>
                    {
                        State = WebSocketState.Open;
                        OnOpen?.Invoke();
                    });
                    await ReceiveLoop();
                }
                catch (OperationCanceledException)
                {
                    // A deliberate Close(); nothing to report.
                }
                catch (Exception error)
                {
                    var message = error.Message;
                    Enqueue(() =>
                    {
                        State = WebSocketState.Closed;
                        OnError?.Invoke(message);
                        OnClose?.Invoke(1006);
                    });
                }
            });
        }

        private async Task ReceiveLoop()
        {
            var buffer = new byte[ReceiveBufferSize];
            var builder = new StringBuilder();

            while (_socket.State == System.Net.WebSockets.WebSocketState.Open &&
                   !_cancellation.IsCancellationRequested)
            {
                WebSocketReceiveResult result;
                try
                {
                    result = await _socket.ReceiveAsync(new ArraySegment<byte>(buffer), _cancellation.Token);
                }
                catch (Exception error)
                {
                    var message = error.Message;
                    Enqueue(() =>
                    {
                        State = WebSocketState.Closed;
                        OnError?.Invoke(message);
                        OnClose?.Invoke(1006);
                    });
                    return;
                }

                if (result.MessageType == WebSocketMessageType.Close)
                {
                    var code = (int)(result.CloseStatus ?? WebSocketCloseStatus.NormalClosure);
                    Enqueue(() =>
                    {
                        State = WebSocketState.Closed;
                        OnClose?.Invoke(code);
                    });
                    return;
                }

                builder.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));

                // A frame can arrive in several chunks; only surface it whole.
                if (!result.EndOfMessage) continue;

                var payload = builder.ToString();
                builder.Clear();
                Enqueue(() => OnMessage?.Invoke(payload));
            }
        }

        public void Send(string message)
        {
            if (_socket == null || _socket.State != System.Net.WebSockets.WebSocketState.Open) return;

            var bytes = Encoding.UTF8.GetBytes(message);
            // Fire and forget: the send queue is ordered by ClientWebSocket itself.
            _ = _socket.SendAsync(
                new ArraySegment<byte>(bytes),
                WebSocketMessageType.Text,
                true,
                _cancellation.Token);
        }

        public void Close()
        {
            if (_socket == null) return;
            State = WebSocketState.Closing;

            try
            {
                _cancellation?.Cancel();
                if (_socket.State == System.Net.WebSockets.WebSocketState.Open)
                {
                    _ = _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
                }
            }
            catch (Exception)
            {
                // Closing a socket that is already gone is not an error worth surfacing.
            }
            finally
            {
                State = WebSocketState.Closed;
                Enqueue(() => OnClose?.Invoke(1000));
            }
        }

        public void Poll()
        {
            while (_mainThreadQueue.TryDequeue(out var action))
            {
                action();
            }
        }

        private void Enqueue(Action action) => _mainThreadQueue.Enqueue(action);
    }
}
#endif
