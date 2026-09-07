# King Teen Patti — Unity Client

Unity client for Android, iOS and WebGL. Talks to the Node.js server over Socket.IO.

> **Status:** compiled and tested with **Unity 6000.6.0f1** — `KingTeenPatti.dll` builds with
> 0 errors and 0 warnings, 36 PlayMode tests pass against a live server, and a StandaloneLinux64
> player builds successfully. See [Verification](#verification).

## Requirements

- **Unity 2021.3 LTS or newer.** Developed and verified on **Unity 6000.6.0f1**; the one
  version-sensitive API (`FindObjectOfType`, deprecated in 2022.2) is behind a version guard so
  older LTS still compiles.
- No third-party runtime packages. WebSockets use `System.Net.WebSockets` on mobile/desktop and a
  bundled `.jslib` on WebGL. `com.unity.test-framework` is a test-only dependency.

## Getting started

Open this folder as a Unity project (Unity Hub → Add → select `unity-client`), then open
`Assets/Scenes/Game.unity` and press **Play**. Select the `GameClient` object to set **Server Url**
in the Inspector (`http://localhost:3000` for local development).

Start the server first:

```bash
cd ../server && npm start
```

Press **Play as Guest** to get in. To fill a table, open <http://localhost:3000> in a browser and
join from there too — the browser client speaks the same protocol.

The canvas, EventSystem, and all three screens (login, lobby, table) are built at runtime, so there
is no prefab wiring to do. If the scene is ever missing, regenerate it from the menu bar:
**King Teen Patti → Create Game Scene**.

## Project layout

```
Assets/
├── Scripts/
│   ├── Net/
│   │   ├── IWebSocket.cs        Transport interface
│   │   ├── SystemWebSocket.cs   Android / iOS / desktop / Editor (ClientWebSocket)
│   │   ├── WebGLWebSocket.cs    Browser builds (bridges to the jslib)
│   │   ├── SocketIOClient.cs    Socket.IO v4 protocol + minimal JSON scanner
│   │   ├── ApiClient.cs         REST login and profile (UnityWebRequest)
│   │   └── GameConnection.cs    Typed events over SocketIOClient
│   ├── Models/Dtos.cs           Wire models for every server payload
│   ├── Game/
│   │   ├── GameClient.cs        Entry point MonoBehaviour
│   │   ├── AuthService.cs       Guest / Google / Facebook sign-in
│   │   └── Card.cs              Card code display helpers
│   └── UI/
│       ├── UiFactory.cs         Runtime uGUI builders
│       ├── GameUI.cs            Screens and rendering
│       ├── SeatView.cs          One seat at the table
│       ├── CardView.cs          One of your own cards
│       └── ChatPanel.cs         Room chat
├── Plugins/WebGL/
│   └── TeenPattiWebSocket.jslib Browser WebSocket bridge
├── Editor/BuildScript.cs        Scene generation + command-line builds
├── Scenes/Game.unity            Generated play scene (one GameClient object)
└── Tests/PlayMode/              36 tests, incl. live-server end-to-end
```

## Look and feel

The interface follows **Material 3** (requirement 23). `UiFactory` holds two schemes built from one
tonal palette, and every widget reads its colour from `UiFactory.Scheme`, so the ☀️/🌙 toggle is a
single `SetDarkMode` call — `GameClient` then rebuilds the runtime UI, which is cheaper than teaching
each widget to repaint itself. The choice is stored in `PlayerPrefs`.

Phones run the game in **landscape only**. `BuildScript` disables both portrait orientations at build
time, `GameClient.Awake` sets the same policy so the Editor matches, and the canvas scales against a
1920×1080 reference matched on height.

## Platform notes

**Android.** Add the internet permission (Unity adds it automatically when a build uses the
network). For a plain-HTTP server during development, allow cleartext traffic in a custom
`AndroidManifest.xml`, or use HTTPS.

**iOS.** App Transport Security blocks plain HTTP. Use `https://` / `wss://` in production, or add
an ATS exception for your dev host.

**WebGL.** `System.Net.WebSockets` is unavailable, so `WebGLWebSocket` bridges to the browser's own
WebSocket via `Plugins/WebGL/TeenPattiWebSocket.jslib`. The transport is selected automatically:

```csharp
#if UNITY_WEBGL && !UNITY_EDITOR
    return new WebGLWebSocket();
#else
    return new SystemWebSocket();
#endif
```

Serve the WebGL build over HTTPS and point it at a `wss://` server, and make sure the server's
`CORS_ORIGIN` includes the page's origin.

## Google and Facebook sign-in

Guest login works out of the box. Google and Facebook need their native SDKs, which are
per-project (they carry your own app ids and native manifests), so they are not bundled. The
client exposes hooks instead — install the SDK you want and assign the matching hook once at
startup:

```csharp
// Google Sign-In (e.g. googlesignin-unity), somewhere in your bootstrap:
AuthService.GoogleSignIn = (onToken, onError) => GoogleSignInFlow(onToken, onError);

private IEnumerator GoogleSignInFlow(Action<string> onToken, Action<string> onError)
{
    var task = GoogleSignIn.DefaultInstance.SignIn();
    while (!task.IsCompleted) yield return null;

    if (task.IsFaulted || task.IsCanceled) onError("Google sign-in failed");
    else onToken(task.Result.IdToken);   // the server verifies this id_token
}
```

```csharp
// Facebook SDK for Unity:
AuthService.FacebookSignIn = (onToken, onError) => FacebookSignInFlow(onToken, onError);

private IEnumerator FacebookSignInFlow(Action<string> onToken, Action<string> onError)
{
    var done = false;
    FB.LogInWithReadPermissions(new[] { "public_profile" }, result =>
    {
        done = true;
        if (string.IsNullOrEmpty(result.Error) && FB.IsLoggedIn)
            onToken(AccessToken.CurrentAccessToken.TokenString);
        else
            onError(result.Error ?? "Facebook login cancelled");
    });
    while (!done) yield return null;
}
```

The client never asserts who the player is: it forwards the provider credential and the **server**
verifies it (Google id_tokens against your OAuth client ids, Facebook tokens via `debug_token`
including the `app_id` check). Set `GOOGLE_CLIENT_IDS` and `FACEBOOK_APP_ID`/`FACEBOOK_APP_SECRET`
on the server to match.

Guest login uses `SystemInfo.deviceUniqueIdentifier`, falling back to a generated id persisted in
`PlayerPrefs` (WebGL and some devices do not expose one). The server hashes it before storage, and
the same install always resolves to the same account.

## How the client is structured

`GameClient` owns a `GameConnection`, which wraps `SocketIOClient`, which drives an `IWebSocket`.
Server events become C# events carrying parsed DTOs; UI callbacks become emits. Every callback is
raised on the Unity main thread — `SystemWebSocket` queues background-thread results and replays
them from `Poll()`, which `GameClient.Update()` pumps once per frame.

**The client is not authoritative about anything.** It renders server snapshots and forwards button
presses. It does not know card faces until the server sends them (after *See*), does not compute
bet amounts (they arrive in `game:yourTurn`), and does not decide who wins.

### Two Unity-specific things worth knowing

**`JsonUtility` cannot represent `null` for a nested class.** The server sends `you: null` when you
are not seated, `turn: null` when no hand is running and `options: null` when it is not your turn —
but `JsonUtility` hands back a zeroed instance rather than `null`. The DTOs therefore carry
explicit markers, and the UI checks those instead of null:

```csharp
room.you.IsSeated        // status is non-empty
room.turn.HasTurn        // userId is non-empty
options.IsActionable     // canPack is true on every real turn
```

**`JsonUtility` cannot read a top-level array**, which is exactly what a Socket.IO envelope is
(`42["event",{…}]`). `SocketIOClient` splits the envelope with a small string-literal-aware scanner
(`Json` in `SocketIOClient.cs`) and only hands the payload object to `JsonUtility`. The scanner
handles quotes, escapes and braces inside strings, so a display name like `Raj "Ace" {x}` is safe.

## Reconnection

Mobile apps get suspended and lose their socket. `GameClient.OnApplicationPause` reconnects on
resume; the server holds the seat for `RECONNECT_GRACE_MS` and replays the current room state, own
cards, and chat backlog on connect. The turn clock keeps running while you are away.

## Verification

Compiled and run with **Unity 6000.6.0f1** on Linux:

| Step | Result |
|---|---|
| Compile `KingTeenPatti.dll` | **0 errors, 0 warnings** |
| WebGL transport type-check | **0 errors** (guard temporarily relaxed so `WebGLWebSocket.cs`, normally excluded in the Editor, is compiled) |
| PlayMode tests | **36 passed, 0 failed** |
| `StandaloneLinux64` player | **Succeeded** — 0 errors, 0 warnings |

### Running the tests

Start the server, then run the PlayMode suite:

```bash
cd ../server && npm start
```

In the Editor: **Window → General → Test Runner → PlayMode → Run All**.
Or from the command line:

```bash
Unity -batchmode -nographics -projectPath . \
      -runTests -testPlatform PlayMode -testResults results.xml
```

The tests **skip** rather than fail when no server is reachable, so the suite stays runnable
without one.

`Assets/Tests/PlayMode/` contains:

- `JsonParserTests.cs` — the hand-rolled JSON scanner: envelope splitting, braces and quotes inside
  strings, nested objects, escapes, and the JsonUtility null-marker behaviour described above.
- `LiveServerTests.cs` — the real client against a real server: guest login and the welcome grant,
  returning-account lookup, the Engine.IO handshake, rejection of a bad token, two clients seated at
  one table playing a hand through to settlement (asserting an opponent never receives your card
  faces), the +/− bet ladder (doubling, stack-bounded, off-ladder amounts refused), Blind/Seen chip
  visibility, and room chat with backlog.

There is a second, independent check on the server side. `server/test/socketProtocol.test.js` ports
the `Json` helper and packet dispatch from `SocketIOClient.cs` to JavaScript and drives it with real
frames, so protocol regressions are caught by `npm test` alone — no Unity install needed:

```bash
cd ../server && node --test test/socketProtocol.test.js
```

**If you change the `Json` helper or the packet dispatch in `SocketIOClient.cs`, update the port
too** — both files carry that note.

## Building

`Assets/Editor/BuildScript.cs` generates the scene (one GameObject with `GameClient`) and builds:

```bash
Unity -batchmode -quit -projectPath . \
      -executeMethod KingTeenPatti.EditorTools.BuildScript.BuildLinux \
      -serverUrl https://play.example.com
```

Entry points: `BuildLinux`, `BuildAndroid`, `BuildWebGL`, `BuildIOS`. Only the Linux Standalone
module was installed on the machine this was built on, so **Android, iOS and WebGL players have not
been produced** — install those platform modules in Unity Hub and run the matching entry point
before shipping. All three code paths compile.

`King Teen Patti → Create Game Scene` in the menu bar does the scene generation alone.

## Replacing the runtime UI

The interface is built in code so the project runs from an empty scene. To use designed prefabs,
replace the `UiFactory.Create*` calls in `GameUI.Build*` with references to your own objects — the
rendering methods (`RenderRoom`, `ShowActions`, `ShowOwnCards`) and the event surface stay the same.
