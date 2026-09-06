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
