using System;

namespace KingTeenPatti.Net
{
    public enum WebSocketState
    {
        Closed,
        Connecting,
        Open,
        Closing
    }

    /// <summary>
    /// The one WebSocket surface the Socket.IO client needs.
    ///
    /// Two implementations back it: <see cref="SystemWebSocket"/> for Android,
    /// iOS, the Editor and desktop, and <see cref="WebGLWebSocket"/> for browser
    /// builds, where .NET sockets are unavailable and the browser's own
    /// WebSocket has to be reached through a jslib.
    ///
    /// Every callback is raised on the Unity main thread by
    /// <see cref="SocketIOClient"/>, so handlers may safely touch the scene.
    /// </summary>
    public interface IWebSocket
    {
        WebSocketState State { get; }

        event Action OnOpen;
        event Action<string> OnMessage;
        event Action<string> OnError;
        event Action<int> OnClose;

        void Connect(string url);

        void Send(string message);

        void Close();

        /// <summary>Pumps queued events; call once per frame from the main thread.</summary>
        void Poll();
    }
}
