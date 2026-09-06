using System;
using System.Collections;
using KingTeenPatti.Models;
using KingTeenPatti.Net;
using UnityEngine;

namespace KingTeenPatti.Game
{
    /// <summary>
    /// Turns a platform sign-in into a game session token.
    ///
    /// Each provider produces a credential the *server* verifies — the client is
    /// never trusted to assert who it is:
    ///   Google   -> the Sign-In id_token
    ///   Facebook -> the user access token
    ///   Guest    -> the device id, which the server hashes and keys the account on
    ///
    /// The Google and Facebook SDKs are not bundled here (they are per-project
    /// native plugins with their own app ids), so those two paths call into
    /// pluggable hooks. Assign <see cref="GoogleSignIn"/> and
    /// <see cref="FacebookSignIn"/> during startup once the SDKs are installed;
    /// see the README for the exact wiring.
    /// </summary>
    public static class AuthService
    {
        private const string TokenKey = "tp_session_token";
        private const string DeviceKey = "tp_device_id";

        /// <summary>
        /// Set this to a coroutine that runs the Google Sign-In flow and calls
        /// back with the id_token (or an error).
        /// </summary>
        public static Func<Action<string>, Action<string>, IEnumerator> GoogleSignIn;

        /// <summary>Same contract as <see cref="GoogleSignIn"/>, returning a Facebook access token.</summary>
        public static Func<Action<string>, Action<string>, IEnumerator> FacebookSignIn;

        public static string SessionToken
        {
            get => PlayerPrefs.GetString(TokenKey, null);
            private set
            {
                PlayerPrefs.SetString(TokenKey, value ?? string.Empty);
                PlayerPrefs.Save();
            }
        }

        public static bool HasSession => !string.IsNullOrEmpty(SessionToken);

        public static void ClearSession() => SessionToken = string.Empty;

        /// <summary>
        /// A stable per-install identifier for guest play.
        ///
        /// <c>SystemInfo.deviceUniqueIdentifier</c> is the primary source, but it
        /// is unavailable on WebGL and can be unsupported on some devices, so a
        /// generated id is persisted as a fallback. Either way the same install
        /// resolves to the same account on every later login.
        /// </summary>
        public static string DeviceId
        {
            get
            {
                var stored = PlayerPrefs.GetString(DeviceKey, null);
                if (!string.IsNullOrEmpty(stored)) return stored;

                var id = SystemInfo.deviceUniqueIdentifier;
                if (string.IsNullOrEmpty(id) || id == SystemInfo.unsupportedIdentifier)
                {
                    id = Guid.NewGuid().ToString("N");
                }

                id = Application.platform + "-" + id;
                PlayerPrefs.SetString(DeviceKey, id);
                PlayerPrefs.Save();
                return id;
            }
        }

        // -------------------------------------------------------------- flows

        public static IEnumerator LoginAsGuest(
            string baseUrl,
            string displayName,
            Action<LoginResponse> onSuccess,
            Action<string> onError)
        {
            var payload = "{\"provider\":\"guest\",\"deviceId\":\"" + Json.Escape(DeviceId) + "\"" +
                          (string.IsNullOrWhiteSpace(displayName)
                              ? ""
                              : ",\"displayName\":\"" + Json.Escape(displayName.Trim()) + "\"") +
                          "}";

            yield return ApiClient.Login(baseUrl, payload, Persist(onSuccess), onError);
        }

        public static IEnumerator LoginWithGoogle(
            string baseUrl,
            Action<LoginResponse> onSuccess,
            Action<string> onError)
        {
            if (GoogleSignIn == null)
            {
                onError?.Invoke("Google Sign-In is not wired up in this build. See AuthService.GoogleSignIn.");
                yield break;
            }

            string idToken = null;
            string failure = null;
            yield return GoogleSignIn(token => idToken = token, error => failure = error);

            if (failure != null || string.IsNullOrEmpty(idToken))
            {
                onError?.Invoke(failure ?? "Google sign-in was cancelled.");
                yield break;
            }

            var payload = "{\"provider\":\"google\",\"idToken\":\"" + Json.Escape(idToken) + "\"}";
            yield return ApiClient.Login(baseUrl, payload, Persist(onSuccess), onError);
        }

        public static IEnumerator LoginWithFacebook(
            string baseUrl,
            Action<LoginResponse> onSuccess,
            Action<string> onError)
        {
            if (FacebookSignIn == null)
            {
                onError?.Invoke("Facebook Login is not wired up in this build. See AuthService.FacebookSignIn.");
                yield break;
            }

            string accessToken = null;
            string failure = null;
            yield return FacebookSignIn(token => accessToken = token, error => failure = error);

            if (failure != null || string.IsNullOrEmpty(accessToken))
            {
                onError?.Invoke(failure ?? "Facebook login was cancelled.");
                yield break;
            }

            var payload = "{\"provider\":\"facebook\",\"accessToken\":\"" + Json.Escape(accessToken) + "\"}";
            yield return ApiClient.Login(baseUrl, payload, Persist(onSuccess), onError);
        }

        private static Action<LoginResponse> Persist(Action<LoginResponse> next)
        {
            return response =>
            {
                SessionToken = response.token;
                next?.Invoke(response);
            };
        }
    }
}
