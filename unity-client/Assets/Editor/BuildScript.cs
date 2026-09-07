#if UNITY_EDITOR
using System;
using System.IO;
using KingTeenPatti.Game;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace KingTeenPatti.EditorTools
{
    /// <summary>
    /// Command-line build helpers.
    ///
    /// The whole UI is created at runtime, so the game scene is just one
    /// GameObject carrying <see cref="GameClient"/> — which means the scene can
    /// be generated here rather than committed as a binary asset.
    ///
    ///   Unity -batchmode -quit -projectPath . \
    ///         -executeMethod KingTeenPatti.EditorTools.BuildScript.BuildLinux \
    ///         -serverUrl https://play.example.com
    /// </summary>
    public static class BuildScript
    {
        private const string ScenePath = "Assets/Scenes/Game.unity";

        /// <summary>
        /// The address the built player will talk to: -serverUrl if given,
        /// otherwise the host machine as that platform sees it.
        /// </summary>
        private static string ServerUrlFor(BuildTarget target) => ArgumentOr(
            "-serverUrl",
            target == BuildTarget.Android ? "http://10.0.2.2:3000" : "http://localhost:3000");

        [MenuItem("King Teen Patti/Create Game Scene")]
        public static string CreateGameScene() => CreateGameScene(EditorUserBuildSettings.activeBuildTarget);

        /// <param name="target">
        /// The platform being built for. It has to be passed in: the editor's
        /// active target has not switched yet when the scene is generated, so
        /// reading it here would bake a desktop address into an APK.
        /// </param>
        public static string CreateGameScene(BuildTarget target)
        {
            Directory.CreateDirectory("Assets/Scenes");

            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

            var go = new GameObject("GameClient");
            var client = go.AddComponent<GameClient>();
            // On Android the default points at the host machine as an emulator
            // sees it; -serverUrl overrides for a real device or a LAN address.
            client.serverUrl = ServerUrlFor(target);
            client.autoLogin = true;

            // A camera so the scene renders something behind the overlay canvas.
            var cameraGo = new GameObject("Main Camera");
            var camera = cameraGo.AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(0.04f, 0.11f, 0.07f);
            cameraGo.tag = "MainCamera";

            EditorSceneManager.SaveScene(scene, ScenePath);
            Debug.Log($"[Build] scene written to {ScenePath} (server {client.serverUrl})");
            return ScenePath;
        }

        public static void BuildLinux() => Build(BuildTarget.StandaloneLinux64, "Build/Linux/KingTeenPatti");

        /// <summary>
        /// Builds an APK.
        ///
        /// An emulator reaches the host machine's loopback at 10.0.2.2, so that
        /// is the default server address; pass -serverUrl to override it.
        /// </summary>
        public static void BuildAndroid()
        {
            PlayerSettings.SetApplicationIdentifier(
                UnityEditor.Build.NamedBuildTarget.Android, "com.kinggames.teenpatti");

            // The emulator talks to the host over plain HTTP, which Android has
            // blocked by default since API 28; Plugins/Android/LauncherManifest.xml
            // turns it back on for development.

            // ARM64 is the only remaining choice — Unity 6 dropped Android
            // x86_64 ("no longer supported and has been removed"). That is fine
            // for a desktop emulator too: the google_apis images translate
            // arm64-v8a, and it is what a real phone wants anyway.
            PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
            PlayerSettings.SetScriptingBackend(
                UnityEditor.Build.NamedBuildTarget.Android, ScriptingImplementation.IL2CPP);
            PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel24;

            Build(BuildTarget.Android, "Build/Android/KingTeenPatti.apk");
        }

        public static void BuildWebGL() => Build(BuildTarget.WebGL, "Build/WebGL");

        public static void BuildIOS() => Build(BuildTarget.iOS, "Build/iOS");

        private static void Build(BuildTarget target, string outputPath)
        {
            var scene = CreateGameScene(target);

            PlayerSettings.companyName = "King Games";
            PlayerSettings.productName = "King Teen Patti";
            // The game is a network client; it must keep ticking in the background
            // or a backgrounded player would silently time out its own turns.
            PlayerSettings.runInBackground = true;

            // The "Made with Unity" splash. Turning it off is a licensed
            // feature: on a Personal licence the build re-enables the logo and
            // these two lines are quietly ignored, so the startup screen is
            // only really gone on Plus/Pro.
            PlayerSettings.SplashScreen.show = false;
            PlayerSettings.SplashScreen.showUnityLogo = false;
            PlayerSettings.SplashScreen.backgroundColor = new Color(0.04f, 0.11f, 0.07f);

            // UnityWebRequest refuses cleartext HTTP by default, which is right
            // for a shipped build but stops the player reaching a local dev
            // server. Allow it only when the address really is http, so pointing
            // -serverUrl at an https host restores the guard by itself.
            var serverUrl = ServerUrlFor(target);
            PlayerSettings.insecureHttpOption =
                serverUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
                    ? InsecureHttpOption.NotAllowed
                    : InsecureHttpOption.AlwaysAllowed;
            Debug.Log($"[Build] server {serverUrl} (insecure http: {PlayerSettings.insecureHttpOption})");

            // Requirement 23: phones play in landscape only. Both landscape
            // orientations are allowed so the device can be held either way,
            // but neither portrait orientation is.
            PlayerSettings.defaultInterfaceOrientation = UIOrientation.AutoRotation;
            PlayerSettings.allowedAutorotateToLandscapeLeft = true;
            PlayerSettings.allowedAutorotateToLandscapeRight = true;
            PlayerSettings.allowedAutorotateToPortrait = false;
            PlayerSettings.allowedAutorotateToPortraitUpsideDown = false;

            var options = new BuildPlayerOptions
            {
                scenes = new[] { scene },
                locationPathName = outputPath,
                target = target,
                options = BuildOptions.None,
            };

            var report = BuildPipeline.BuildPlayer(options);
            var summary = report.summary;

            Debug.Log($"[Build] {target} -> {summary.result} " +
                      $"({summary.totalSize} bytes, {summary.totalErrors} errors, {summary.totalWarnings} warnings)");

            if (summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded)
            {
                EditorApplication.Exit(1);
            }
        }

        private static string ArgumentOr(string name, string fallback)
        {
            var args = Environment.GetCommandLineArgs();
            for (var i = 0; i < args.Length - 1; i++)
            {
                if (args[i] == name) return args[i + 1];
            }
            return fallback;
        }
    }
}
#endif
