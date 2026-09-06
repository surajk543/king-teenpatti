#if UNITY_WEBGL && !UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using AOT;

namespace KingTeenPatti.Net
{
    /// <summary>
    /// WebGL transport. Delegates to the browser's WebSocket through
    /// Plugins/WebGL/TeenPattiWebSocket.jslib.
    ///
    /// The browser calls back on the same (single) thread Unity runs on, so no
    /// marshalling is needed — but callbacks from native code must be static,
    /// hence the id-keyed instance table.
    /// </summary>
    public class WebGLWebSocket : IWebSocket
    {
        [DllImport("__Internal")]
        private static extern void TPWS_SetCallbacks(
            Action<int> onOpen,
            Action<int, IntPtr> onMessage,
            Action<int, IntPtr> onError,
            Action<int, int> onClose);

        [DllImport("__Internal")]
        private static extern int TPWS_Connect(string url);

        [DllImport("__Internal")]
        private static extern int TPWS_Send(int id, string message);

        [DllImport("__Internal")]
        private static extern void TPWS_Close(int id);

        [DllImport("__Internal")]
        private static extern int TPWS_State(int id);

        private static readonly Dictionary<int, WebGLWebSocket> Instances =
            new Dictionary<int, WebGLWebSocket>();

        private static bool _callbacksRegistered;

        private int _id;

        public event Action OnOpen;
        public event Action<string> OnMessage;
        public event Action<string> OnError;
        public event Action<int> OnClose;

        public WebSocketState State
        {
            get
            {
                if (_id == 0) return WebSocketState.Closed;
                switch (TPWS_State(_id))
                {
                    case 0: return WebSocketState.Connecting;
                    case 1: return WebSocketState.Open;
                    case 2: return WebSocketState.Closing;
                    default: return WebSocketState.Closed;
                }
            }
        }

        public void Connect(string url)
        {
            if (!_callbacksRegistered)
            {
                TPWS_SetCallbacks(HandleOpen, HandleMessage, HandleError, HandleClose);
                _callbacksRegistered = true;
            }

            _id = TPWS_Connect(url);
            Instances[_id] = this;
        }

        public void Send(string message)
        {
            if (_id != 0) TPWS_Send(_id, message);
        }

        public void Close()
        {
            if (_id == 0) return;
            TPWS_Close(_id);
            Instances.Remove(_id);
            _id = 0;
        }

        /// <summary>No-op: browser callbacks already arrive on the main thread.</summary>
        public void Poll()
        {
        }

        [MonoPInvokeCallback(typeof(Action<int>))]
        private static void HandleOpen(int id)
        {
            if (Instances.TryGetValue(id, out var socket)) socket.OnOpen?.Invoke();
        }

        [MonoPInvokeCallback(typeof(Action<int, IntPtr>))]
        private static void HandleMessage(int id, IntPtr pointer)
        {
            if (Instances.TryGetValue(id, out var socket))
            {
                // The jslib writes UTF-8; PtrToStringAuto would misread non-ASCII
                // display names and chat text.
                socket.OnMessage?.Invoke(Marshal.PtrToStringUTF8(pointer));
            }
        }

        [MonoPInvokeCallback(typeof(Action<int, IntPtr>))]
        private static void HandleError(int id, IntPtr pointer)
        {
            if (Instances.TryGetValue(id, out var socket))
            {
                socket.OnError?.Invoke(Marshal.PtrToStringUTF8(pointer));
            }
        }

        [MonoPInvokeCallback(typeof(Action<int, int>))]
        private static void HandleClose(int id, int code)
        {
            if (!Instances.TryGetValue(id, out var socket)) return;
            Instances.Remove(id);
            socket.OnClose?.Invoke(code);
        }
    }
}
#endif
