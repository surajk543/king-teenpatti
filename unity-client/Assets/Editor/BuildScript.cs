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

        [MenuItem("King Teen Patti/Create Game Scene")]
        public static string CreateGameScene()
        {
            Directory.CreateDirectory("Assets/Scenes");

            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

            var go = new GameObject("GameClient");
            var client = go.AddComponent<GameClient>();
            client.serverUrl = ArgumentOr("-serverUrl", "http://localhost:3000");
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

        public static void BuildAndroid() => Build(BuildTarget.Android, "Build/Android/KingTeenPatti.apk");

        public static void BuildWebGL() => Build(BuildTarget.WebGL, "Build/WebGL");

        public static void BuildIOS() => Build(BuildTarget.iOS, "Build/iOS");

        private static void Build(BuildTarget target, string outputPath)
        {
            var scene = CreateGameScene();

            PlayerSettings.companyName = "King Games";
            PlayerSettings.productName = "King Teen Patti";
            // The game is a network client; it must keep ticking in the background
            // or a backgrounded player would silently time out its own turns.
            PlayerSettings.runInBackground = true;

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
