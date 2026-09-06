// WebSocket bridge for WebGL builds.
//
// Unity's WebGL target has no .NET sockets, so the browser's own WebSocket is
// driven from here and results are pushed back into C# through the callbacks
// registered by WebGLWebSocket.cs.
mergeInto(LibraryManager.library, {

  $TeenPattiWS: {
    instances: {},
    nextId: 1,
    callbacks: { open: null, message: null, error: null, close: null },
  },

  TPWS_SetCallbacks: function (onOpen, onMessage, onError, onClose) {
    TeenPattiWS.callbacks.open = onOpen;
    TeenPattiWS.callbacks.message = onMessage;
    TeenPattiWS.callbacks.error = onError;
    TeenPattiWS.callbacks.close = onClose;
  },

  TPWS_Connect: function (urlPtr) {
    var url = UTF8ToString(urlPtr);
    var id = TeenPattiWS.nextId++;

    var socket;
    try {
      socket = new WebSocket(url);
    } catch (e) {
      var errPtr = allocateUTF8(String(e && e.message ? e.message : e));
      // Report asynchronously so the caller has its id before the error lands.
      setTimeout(function () {
        {{{ makeDynCall('vii', 'TeenPattiWS.callbacks.error') }}}(id, errPtr);
        _free(errPtr);
      }, 0);
      return id;
    }

    socket.binaryType = 'arraybuffer';
    TeenPattiWS.instances[id] = socket;

    socket.onopen = function () {
      if (TeenPattiWS.callbacks.open) {
        {{{ makeDynCall('vi', 'TeenPattiWS.callbacks.open') }}}(id);
      }
    };

    socket.onmessage = function (event) {
      if (typeof event.data !== 'string') return; // this protocol is text only
      if (!TeenPattiWS.callbacks.message) return;
      var length = lengthBytesUTF8(event.data) + 1;
      var buffer = _malloc(length);
      stringToUTF8(event.data, buffer, length);
      {{{ makeDynCall('vii', 'TeenPattiWS.callbacks.message') }}}(id, buffer);
      _free(buffer);
    };

    socket.onerror = function () {
      if (!TeenPattiWS.callbacks.error) return;
      var message = 'websocket error';
      var length = lengthBytesUTF8(message) + 1;
      var buffer = _malloc(length);
      stringToUTF8(message, buffer, length);
      {{{ makeDynCall('vii', 'TeenPattiWS.callbacks.error') }}}(id, buffer);
      _free(buffer);
    };

    socket.onclose = function (event) {
      if (TeenPattiWS.callbacks.close) {
        {{{ makeDynCall('vii', 'TeenPattiWS.callbacks.close') }}}(id, event.code);
      }
      delete TeenPattiWS.instances[id];
    };

    return id;
  },

  TPWS_Send: function (id, messagePtr) {
    var socket = TeenPattiWS.instances[id];
    if (!socket || socket.readyState !== 1) return 0;
    socket.send(UTF8ToString(messagePtr));
    return 1;
  },

  TPWS_Close: function (id) {
    var socket = TeenPattiWS.instances[id];
    if (!socket) return;
    try {
      socket.close(1000, 'bye');
    } catch (e) {
      // Already closing or closed.
    }
    delete TeenPattiWS.instances[id];
  },

  TPWS_State: function (id) {
    var socket = TeenPattiWS.instances[id];
    return socket ? socket.readyState : 3; // 3 = CLOSED
  },
});

autoAddDeps(LibraryManager.library, '$TeenPattiWS');
