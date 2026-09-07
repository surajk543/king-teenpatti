using System;
using System.Collections;
using System.Text;
using KingTeenPatti.Models;
using UnityEngine;
using UnityEngine.Networking;

namespace KingTeenPatti.Net
{
    /// <summary>
    /// REST calls to the game server: login and profile.
    ///
    /// Gameplay never goes through here — once logged in, the session token is
    /// handed to <see cref="SocketIOClient"/> and everything else is realtime.
    /// </summary>
    public static class ApiClient
    {
        /// <summary>
        /// Logs in with a verified provider credential.
        ///
        /// Google sends the Sign-In id_token, Facebook the user access token,
        /// and a guest sends the device id. The server verifies the credential,
        /// creates the account on first sight with the welcome chip grant, and
        /// returns the same account on every later login.
        /// </summary>
        public static IEnumerator Login(
            string baseUrl,
            string requestJson,
            Action<LoginResponse> onSuccess,
            Action<string> onError)
        {
            var url = baseUrl.TrimEnd('/') + "/api/auth/login";
            using var request = new UnityWebRequest(url, UnityWebRequest.kHttpVerbPOST);

            request.uploadHandler = new UploadHandlerRaw(Encoding.UTF8.GetBytes(requestJson));
            request.downloadHandler = new DownloadHandlerBuffer();
            request.SetRequestHeader("Content-Type", "application/json");
            request.timeout = 15;

            yield return request.SendWebRequest();

            var body = request.downloadHandler?.text ?? string.Empty;

            if (request.result != UnityWebRequest.Result.Success)
            {
                // The server sends a structured error for anything it rejected;
                // fall back to the transport error when it did not answer at all.
                var message = request.error;
                if (!string.IsNullOrEmpty(body))
                {
                    try
                    {
                        var parsed = JsonUtility.FromJson<ErrorResponse>(body);
                        if (!string.IsNullOrEmpty(parsed?.message)) message = parsed.message;
                    }
                    catch (Exception)
                    {
                        // Keep the transport error.
                    }
                }
                onError?.Invoke(message);
                yield break;
            }

            LoginResponse response = null;
            try
            {
                response = JsonUtility.FromJson<LoginResponse>(body);
            }
            catch (Exception error)
            {
                onError?.Invoke($"Could not read the login response: {error.Message}");
                yield break;
            }

            if (response?.token == null)
            {
                onError?.Invoke("The server did not return a session token.");
                yield break;
            }

            onSuccess?.Invoke(response);
        }

        /// <summary>Re-reads the signed-in player's persisted profile.</summary>
        public static IEnumerator GetProfile(
            string baseUrl,
            string token,
            Action<UserDto> onSuccess,
            Action<string> onError)
        {
            var url = baseUrl.TrimEnd('/') + "/api/auth/me";
            using var request = UnityWebRequest.Get(url);

            request.SetRequestHeader("Authorization", "Bearer " + token);
            request.timeout = 15;

            yield return request.SendWebRequest();

            if (request.result != UnityWebRequest.Result.Success)
            {
                onError?.Invoke(request.error);
                yield break;
            }

            var wrapper = JsonUtility.FromJson<ProfileResponse>(request.downloadHandler.text);
            onSuccess?.Invoke(wrapper?.user);
        }

        /// <summary>Lists open tables for the lobby.</summary>
        public static IEnumerator ListTables(
            string baseUrl,
            Action<TableSummaryDto[]> onSuccess,
            Action<string> onError)
        {
            var url = baseUrl.TrimEnd('/') + "/api/rooms";
            using var request = UnityWebRequest.Get(url);
            request.timeout = 10;

            yield return request.SendWebRequest();

            if (request.result != UnityWebRequest.Result.Success)
            {
                onError?.Invoke(request.error);
                yield break;
            }

            var parsed = JsonUtility.FromJson<TableListDto>(request.downloadHandler.text);
            onSuccess?.Invoke(parsed?.tables ?? Array.Empty<TableSummaryDto>());
        }

        /// <summary>
        /// Collects a reward. `path` is "/api/rewards/milestone" or
        /// "/api/rewards/bonus"; the server decides whether it is actually due,
        /// so a client cannot grant itself chips by calling this early.
        /// </summary>
        public static IEnumerator ClaimReward(
            string baseUrl,
            string token,
            string path,
            Action<RewardClaimDto> onDone,
            Action<string> onError)
        {
            var url = baseUrl.TrimEnd('/') + path;
            using var request = new UnityWebRequest(url, UnityWebRequest.kHttpVerbPOST);
            request.downloadHandler = new DownloadHandlerBuffer();
            request.SetRequestHeader("Authorization", "Bearer " + token);
            request.timeout = 15;

            yield return request.SendWebRequest();

            var body = request.downloadHandler?.text ?? string.Empty;
            RewardClaimDto parsed = null;
            try
            {
                if (!string.IsNullOrEmpty(body)) parsed = JsonUtility.FromJson<RewardClaimDto>(body);
            }
            catch (Exception)
            {
                parsed = null;
            }

            // A refusal still carries a message and the current account, so it
            // is reported through onDone rather than treated as a transport error.
            if (request.result != UnityWebRequest.Result.Success && parsed == null)
            {
                onError?.Invoke(request.error);
                yield break;
            }

            onDone?.Invoke(parsed ?? new RewardClaimDto { claimed = false, message = request.error });
        }

        /// <summary>Lists the pictures bundled with the game.</summary>
        public static IEnumerator GetProfilePictures(
            string baseUrl,
            Action<ProfilePictureDto[]> onSuccess,
            Action<string> onError)
        {
            var url = baseUrl.TrimEnd('/') + "/api/profiles";
            using var request = UnityWebRequest.Get(url);
            request.timeout = 10;

            yield return request.SendWebRequest();

            if (request.result != UnityWebRequest.Result.Success)
            {
                onError?.Invoke(request.error);
                yield break;
            }

            var parsed = JsonUtility.FromJson<ProfilePictureListDto>(request.downloadHandler.text);
            onSuccess?.Invoke(parsed?.profiles ?? Array.Empty<ProfilePictureDto>());
        }

        /// <summary>
        /// Chooses a profile picture. Pass null to fall back to the
        /// Google/Facebook one. Refused by the server while seated at a table.
        /// </summary>
        public static IEnumerator SetProfilePicture(
            string baseUrl,
            string token,
            string avatarId,
            Action<UserDto> onSuccess,
            Action<string> onError)
        {
            var url = baseUrl.TrimEnd('/') + "/api/profile/avatar";
            var payload = avatarId == null
                ? "{\"avatar\":null}"
                : "{\"avatar\":\"" + Json.Escape(avatarId) + "\"}";

            using var request = new UnityWebRequest(url, UnityWebRequest.kHttpVerbPOST);
            request.uploadHandler = new UploadHandlerRaw(Encoding.UTF8.GetBytes(payload));
            request.downloadHandler = new DownloadHandlerBuffer();
            request.SetRequestHeader("Content-Type", "application/json");
            request.SetRequestHeader("Authorization", "Bearer " + token);
            request.timeout = 15;

            yield return request.SendWebRequest();

            var body = request.downloadHandler?.text ?? string.Empty;

            if (request.result != UnityWebRequest.Result.Success)
            {
                var message = request.error;
                try
                {
                    var parsed = JsonUtility.FromJson<ErrorResponse>(body);
                    if (!string.IsNullOrEmpty(parsed?.message)) message = parsed.message;
                }
                catch (Exception)
                {
                    // Keep the transport error.
                }
                onError?.Invoke(message);
                yield break;
            }

            var wrapper = JsonUtility.FromJson<ProfileResponse>(body);
            onSuccess?.Invoke(wrapper?.user);
        }

        [Serializable]
        private class ProfileResponse
        {
            public UserDto user;
        }
    }
}
