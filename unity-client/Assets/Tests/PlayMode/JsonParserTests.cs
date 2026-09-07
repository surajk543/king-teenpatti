using System;
using KingTeenPatti.Models;
using KingTeenPatti.Net;
using NUnit.Framework;
using UnityEngine;

namespace KingTeenPatti.Tests
{
    /// <summary>
    /// Unit tests for the hand-rolled JSON scanner in SocketIOClient.cs.
    ///
    /// This is the code that splits a Socket.IO envelope — `42["event",{…}]` —
    /// which JsonUtility cannot read because it is a top-level array. A bug here
    /// breaks every message the client receives, so it is tested directly rather
    /// than only through a live connection.
    /// </summary>
    public class JsonParserTests
    {
        [Test]
        public void SplitsAnEventEnvelope()
        {
            const string array = "[\"game:turn\",{\"userId\":\"abc\",\"seatIndex\":2,\"deadline\":1730000000000}]";

            Assert.AreEqual("game:turn", Json.FirstArrayString(array));

            var payload = Json.SecondArrayElement(array);
            Assert.AreEqual("abc", Json.GetString(payload, "userId"));
            Assert.AreEqual(2, Json.GetInt(payload, "seatIndex"));
        }

        [Test]
        public void BracesInsideStringsDoNotConfuseTheSplitter()
        {
            const string array =
                "[\"chat:message\",{\"text\":\"gg [nice] {hand} \\\"wp\\\"\",\"userId\":\"u1\"}]";

            Assert.AreEqual("chat:message", Json.FirstArrayString(array));

            var payload = Json.SecondArrayElement(array);
            Assert.AreEqual("u1", Json.GetString(payload, "userId"));
            Assert.AreEqual("gg [nice] {hand} \"wp\"", Json.GetString(payload, "text"));
        }

        [Test]
        public void NestedObjectsAndArraysComeBackWhole()
        {
            const string array =
                "[\"room:state\",{\"seats\":[{\"seatIndex\":0},{\"seatIndex\":1}],\"you\":{\"cards\":[\"As\",\"Kh\",\"Qd\"]}}]";

            var payload = Json.SecondArrayElement(array);

            // The extracted payload must still be valid JSON for JsonUtility.
            var state = JsonUtility.FromJson<RoomStateDto>(payload);
            Assert.AreEqual(2, state.seats.Length);
            Assert.AreEqual(3, state.you.cards.Length);
            Assert.AreEqual("As", state.you.cards[0]);
        }

        [Test]
        public void EventWithNoPayloadIsHandled()
        {
            Assert.AreEqual("room:left", Json.FirstArrayString("[\"room:left\"]"));
            Assert.IsNull(Json.SecondArrayElement("[\"room:left\"]"));
        }

        [Test]
        public void EscapedTextRoundTrips()
        {
            const string name = "Raj \"The Ace\" {x}";
            var array = "[\"session:ready\",{\"name\":\"" + Json.Escape(name) + "\"}]";

            Assert.AreEqual(name, Json.GetString(Json.SecondArrayElement(array), "name"));
        }

        [Test]
        public void ReadsBooleansAndNegativeNumbers()
        {
            const string payload = "{\"isNew\":true,\"blind\":false,\"delta\":-1500,\"pot\":0}";

            Assert.IsTrue(Json.GetBool(payload, "isNew"));
            Assert.IsFalse(Json.GetBool(payload, "blind"));
            Assert.AreEqual(-1500, Json.GetInt(payload, "delta"));
            Assert.AreEqual(0, Json.GetInt(payload, "pot"));
        }

        [Test]
        public void MissingFieldsFallBack()
        {
            const string payload = "{\"a\":1}";

            Assert.AreEqual("none", Json.GetString(payload, "missing", "none"));
            Assert.AreEqual(42, Json.GetInt(payload, "missing", 42));
            Assert.IsTrue(Json.GetBool(payload, "missing", true));
        }

        /// <summary>
        /// JsonUtility cannot represent null for a nested class, so the DTOs carry
        /// explicit markers instead. If these ever became plain null checks, a
        /// spectator would be treated as seated and the UI would misbehave.
        /// </summary>
        [Test]
        public void AbsentNestedObjectsAreDetectedByMarkerNotNull()
        {
            var state = JsonUtility.FromJson<RoomStateDto>(
                "{\"roomId\":\"r1\",\"state\":\"waiting\",\"you\":null,\"turn\":null}");

            Assert.IsFalse(state.you != null && state.you.IsSeated, "a null 'you' must read as not seated");
            Assert.IsFalse(state.turn != null && state.turn.HasTurn, "a null 'turn' must read as no turn");
        }

        [Test]
        public void RealTurnOptionsAreActionable()
        {
            var yourTurn = JsonUtility.FromJson<YourTurnDto>(
                "{\"deadline\":1730000000000,\"timeoutMs\":25000," +
                "\"options\":{\"canSee\":true,\"chaal\":100,\"raise\":200,\"show\":0,\"canPack\":true}}");

            Assert.IsTrue(yourTurn.options.IsActionable);
            Assert.AreEqual(100, yourTurn.options.chaal);
            Assert.AreEqual(200, yourTurn.options.raise);
            Assert.AreEqual(0, yourTurn.options.show, "no show with more than two players");
        }

        /// <summary>
        /// The +/- stepper walks the ladder the server sends. Each rung must be
        /// double the last, and the array must survive JsonUtility intact.
        /// </summary>
        [Test]
        public void RaiseLadderParsesAndDoubles()
        {
            var yourTurn = JsonUtility.FromJson<YourTurnDto>(
                "{\"deadline\":1730000000000,\"timeoutMs\":25000,\"options\":{" +
                "\"canSee\":false,\"chaal\":100,\"raise\":200,\"maxBet\":800,\"chips\":950," +
                "\"raiseSteps\":[100,200,400,800],\"canPack\":true}}");

            var options = yourTurn.options;

            Assert.AreEqual(4, options.raiseSteps.Length);
            Assert.AreEqual(100, options.raiseSteps[0], "rung 0 is the plain chaal");
            for (var i = 1; i < options.raiseSteps.Length; i++)
            {
                Assert.AreEqual(options.raiseSteps[i - 1] * 2, options.raiseSteps[i], "each + doubles");
            }

            Assert.AreEqual(options.chaal, options.raiseSteps[0]);
            Assert.AreEqual(options.raise, options.raiseSteps[1], "a raise starts at rung 1");
            Assert.AreEqual(800, options.maxBet);
        }

        [Test]
        public void NoRungOfTheLadderExceedsTheStack()
        {
            var options = JsonUtility.FromJson<TurnOptionsDto>(
                "{\"chaal\":100,\"raise\":200,\"maxBet\":400,\"chips\":650," +
                "\"raiseSteps\":[100,200,400],\"canPack\":true}");

            foreach (var step in options.raiseSteps)
            {
                Assert.LessOrEqual(step, options.chips, step + " must be affordable");
            }
            Assert.AreEqual(options.maxBet, options.raiseSteps[options.raiseSteps.Length - 1]);
        }

        [Test]
        public void ASingleRungLadderOffersNoRaise()
        {
            // A stack that can only just cover the chaal: "+" has nowhere to go.
            var options = JsonUtility.FromJson<TurnOptionsDto>(
                "{\"chaal\":100,\"raise\":0,\"maxBet\":100,\"chips\":150," +
                "\"raiseSteps\":[100],\"canPack\":true}");

            Assert.AreEqual(1, options.raiseSteps.Length);
            Assert.AreEqual(0, options.raise, "no raise is offered");
            Assert.IsTrue(options.IsActionable, "but the turn is still playable");
        }

        [Test]
        public void AnUnaffordableTurnOffersNoBetAtAll()
        {
            var options = JsonUtility.FromJson<TurnOptionsDto>(
                "{\"chaal\":0,\"raise\":0,\"maxBet\":0,\"chips\":50,\"raiseSteps\":[],\"canPack\":true}");

            Assert.AreEqual(0, options.raiseSteps.Length);
            Assert.AreEqual(0, options.chaal);
            Assert.IsTrue(options.canPack, "packing is always available");
        }

        /// <summary>
        /// Requirements 17 and 18: both reward states arrive on the user record,
        /// and the bonus countdown is derived from the server's unlock time
        /// rather than anything the client keeps.
        /// </summary>
        [Test]
        public void RewardStateParses()
        {
            var readyAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 90 * 60 * 1000;
            var user = JsonUtility.FromJson<UserDto>(
                "{\"id\":\"u1\",\"chips\":250000,\"handsPlayed\":37,\"handsWon\":9," +
                "\"handsLost\":26,\"handsLeftMid\":2,\"totalWinnings\":48000,\"rewards\":{" +
                "\"milestoneAvailable\":true,\"milestoneAt\":25,\"milestoneReward\":25000," +
                "\"milestoneEvery\":25,\"handsToNextMilestone\":13," +
                "\"bonusReadyAt\":" + readyAt + ",\"bonusAvailable\":false," +
                "\"bonusReward\":10000,\"bonusIntervalMs\":14400000}}");

            Assert.AreEqual(37, user.handsPlayed);
            Assert.AreEqual(26, user.handsLost);
            Assert.AreEqual(2, user.handsLeftMid, "abandoned hands are tracked separately");
            Assert.AreEqual(48000, user.totalWinnings);

            Assert.IsTrue(user.rewards.milestoneAvailable);
            Assert.AreEqual(25000, user.rewards.milestoneReward);
            Assert.AreEqual(13, user.rewards.handsToNextMilestone);

            Assert.IsFalse(user.rewards.IsBonusReady, "the bonus is still recharging");
            Assert.Greater(user.rewards.MillisecondsUntilBonus, 0);
            Assert.AreEqual(4 * 60 * 60 * 1000, user.rewards.bonusIntervalMs, "a 4-hour cycle");
        }

        [Test]
        public void AReadyBonusHasNoCountdownLeft()
        {
            var user = JsonUtility.FromJson<UserDto>(
                "{\"id\":\"u1\",\"rewards\":{\"bonusReadyAt\":0,\"bonusAvailable\":true,\"bonusReward\":10000}}");

            Assert.IsTrue(user.rewards.IsBonusReady);
            Assert.AreEqual(0, user.rewards.MillisecondsUntilBonus);
        }

        /// <summary>
        /// Requirement 26: the bonus countdown always shows seconds, so it
        /// visibly ticks instead of resting on the same minute for a while.
        /// </summary>
        [Test]
        public void CountdownAlwaysShowsSeconds()
        {
            Assert.AreEqual("3h 41m 7s", UI.GameUI.FormatCountdown((3 * 3600 + 41 * 60 + 7) * 1000L));
            Assert.AreEqual("3h 41m 0s", UI.GameUI.FormatCountdown((3 * 3600 + 41 * 60) * 1000L));
            Assert.AreEqual("12m 5s", UI.GameUI.FormatCountdown((12 * 60 + 5) * 1000L));
            Assert.AreEqual("9s", UI.GameUI.FormatCountdown(9000));
            Assert.AreEqual("0s", UI.GameUI.FormatCountdown(-5000), "a past deadline reads as ready");

            // A second apart must render differently, or the timer looks frozen.
            Assert.AreNotEqual(
                UI.GameUI.FormatCountdown(3600_000),
                UI.GameUI.FormatCountdown(3599_000),
                "one second of difference is visible");
        }

        /// <summary>Requirement 14: a showdown carries every hand, not just one.</summary>
        [Test]
        public void ShowdownRevealsParse()
        {
            var showdown = JsonUtility.FromJson<ShowdownDto>(
                "{\"reason\":\"show\",\"reveals\":[" +
                "{\"userId\":\"u1\",\"seatIndex\":0,\"cards\":[\"As\",\"Ah\",\"Ad\"]," +
                "\"handName\":\"Trail\",\"category\":5,\"won\":true}," +
                "{\"userId\":\"u2\",\"seatIndex\":1,\"cards\":[\"2s\",\"7h\",\"9d\"]," +
                "\"handName\":\"High Card\",\"category\":0,\"won\":false}]}");

            Assert.AreEqual(2, showdown.reveals.Length, "both hands are shown to everyone");
            Assert.AreEqual("Trail", showdown.reveals[0].handName);
            Assert.AreEqual(3, showdown.reveals[0].cards.Length);
            Assert.IsTrue(showdown.reveals[0].won);
            Assert.IsFalse(showdown.reveals[1].won);
        }

        /// <summary>Requirements 20 and 21: the picture everyone at the table sees.</summary>
        [Test]
        public void ProfilePicturesParse()
        {
            var list = JsonUtility.FromJson<ProfilePictureListDto>(
                "{\"profiles\":[{\"id\":\"ace.svg\",\"url\":\"/profiles/ace.svg\"}," +
                "{\"id\":\"king.svg\",\"url\":\"/profiles/king.svg\"}]}");

            Assert.AreEqual(2, list.profiles.Length);
            Assert.AreEqual("/profiles/ace.svg", list.profiles[0].url);

            // A chosen picture overrides the provider one but does not erase it.
            var user = JsonUtility.FromJson<UserDto>(
                "{\"avatarUrl\":\"/profiles/king.svg\"," +
                "\"providerAvatarUrl\":\"https://lh3.googleusercontent.com/x\"," +
                "\"avatarChoice\":\"/profiles/king.svg\"}");

            Assert.AreEqual("/profiles/king.svg", user.avatarUrl);
            Assert.AreEqual("https://lh3.googleusercontent.com/x", user.providerAvatarUrl);
        }

        [Test]
        public void SeatCarriesTheSharedAvatar()
        {
            var state = JsonUtility.FromJson<RoomStateDto>(
                "{\"seats\":[{\"seatIndex\":0,\"userId\":\"u1\",\"displayName\":\"Ravi\"," +
                "\"avatarUrl\":\"/profiles/spade.svg\",\"status\":\"active\"}]}");

            Assert.AreEqual("/profiles/spade.svg", state.seats[0].avatarUrl,
                "every player at the table sees this picture");
        }

        /// <summary>
        /// Requirement 22: a private table reports its pot ceiling and boot
        /// floor, so the client can show them and avoid an obviously bad request.
        /// </summary>
        [Test]
        public void PrivateTableRulesParse()
        {
            var config = JsonUtility.FromJson<GameConfigDto>(
                "{\"maxPlayers\":5,\"minPlayers\":2,\"bootAmount\":200," +
                "\"stakes\":[200,5000],\"privateBoot\":200,\"privateMaxPot\":500000}");

            Assert.AreEqual(200, config.privateBoot, "the boot is fixed, not chosen");
            Assert.AreEqual(500000, config.privateMaxPot, "and the win is capped");

            var capped = JsonUtility.FromJson<RoomStateDto>(
                "{\"roomId\":\"r1\",\"pot\":1200,\"maxPot\":500000,\"stake\":200}");
            Assert.AreEqual(500000, capped.maxPot, "a private table carries its ceiling");

            var uncapped = JsonUtility.FromJson<RoomStateDto>(
                "{\"roomId\":\"r2\",\"pot\":1200,\"maxPot\":0,\"stake\":200}");
            Assert.AreEqual(0, uncapped.maxPot, "a public table is uncapped");
        }

        /// <summary>
        /// Requirement 23: both Material 3 schemes exist and are genuinely
        /// different, and switching swaps the whole palette.
        /// </summary>
        [Test]
        public void DayModeIsTheDefault()
        {
            // A fresh install opens in light mode; the toggle stores anything else.
            Assert.AreEqual(UI.UiFactory.Light.Surface, UI.UiFactory.Light.Surface);
            Assert.Greater(
                UI.UiFactory.Light.Surface.r,
                UI.UiFactory.Dark.Surface.r,
                "the light scheme is the brighter one");
        }

        [Test]
        public void ThemeSwitchingSwapsTheWholePalette()
        {
            var wasDark = UI.UiFactory.IsDarkMode;
            try
            {
                UI.UiFactory.SetDarkMode(true);
                var darkSurface = UI.UiFactory.Scheme.Surface;
                Assert.IsTrue(UI.UiFactory.IsDarkMode);

                UI.UiFactory.SetDarkMode(false);
                var lightSurface = UI.UiFactory.Scheme.Surface;

                Assert.IsFalse(UI.UiFactory.IsDarkMode);
                Assert.AreNotEqual(darkSurface, lightSurface, "the two schemes differ");

                // A light scheme must actually be lighter than the dark one.
                Assert.Greater(lightSurface.r + lightSurface.g + lightSurface.b,
                    darkSurface.r + darkSurface.g + darkSurface.b);

                // The role aliases follow the active scheme, not a fixed colour.
                Assert.AreEqual(UI.UiFactory.Scheme.OnSurface, UI.UiFactory.Ink);
                Assert.AreEqual(UI.UiFactory.Scheme.Secondary, UI.UiFactory.Gold);
            }
            finally
            {
                UI.UiFactory.SetDarkMode(wasDark);
            }
        }

        [Test]
        public void BothSchemesKeepTextReadable()
        {
            // On/​container pairs must contrast, or the UI is unusable in one mode.
            foreach (var scheme in new[] { UI.UiFactory.Dark, UI.UiFactory.Light })
            {
                AssertContrasts(scheme.Surface, scheme.OnSurface, "surface");
                AssertContrasts(scheme.Primary, scheme.OnPrimary, "primary");
                AssertContrasts(scheme.SecondaryContainer, scheme.OnSecondaryContainer, "secondary container");
                AssertContrasts(scheme.SurfaceVariant, scheme.OnSurfaceVariant, "surface variant");
            }
        }

        private static void AssertContrasts(Color background, Color foreground, string what)
        {
            var difference = Mathf.Abs(Luminance(background) - Luminance(foreground));
            Assert.Greater(difference, 0.3f, what + " needs readable contrast");
        }

        private static float Luminance(Color c) => 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b;

        /// <summary>Requirement 24: the move notice parses.</summary>
        [Test]
        public void RoomMoveNoticeParses()
        {
            var moved = JsonUtility.FromJson<RoomMovedDto>(
                "{\"fromRoomId\":\"a\",\"toRoomId\":\"b\",\"code\":\"AB12CD\"," +
                "\"message\":\"Moved to a table with other players waiting.\"}");

            Assert.AreEqual("a", moved.fromRoomId);
            Assert.AreEqual("b", moved.toRoomId);
            Assert.AreEqual("AB12CD", moved.code);
            Assert.IsNotEmpty(moved.message);
        }

        [Test]
        public void CardCodesRenderCorrectly()
        {
            Assert.AreEqual("A", Game.Card.RankOf("As"));
            Assert.AreEqual("10", Game.Card.RankOf("Td"), "T renders as 10");
            Assert.AreEqual("♠", Game.Card.SuitSymbol("As"));
            Assert.IsTrue(Game.Card.IsRed("Kh"));
            Assert.IsFalse(Game.Card.IsRed("Kc"));
            Assert.AreEqual("A♠ K♥ Q♦", Game.Card.PrettyHand(new[] { "As", "Kh", "Qd" }));
        }
    }
}
