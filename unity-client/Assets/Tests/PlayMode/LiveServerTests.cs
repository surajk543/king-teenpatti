using System;
using System.Collections;
using System.Collections.Generic;
using KingTeenPatti.Game;
using KingTeenPatti.Models;
using KingTeenPatti.Net;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace KingTeenPatti.Tests
{
    /// <summary>
    /// End-to-end tests: the real Unity client code against a real running
    /// server. These exercise <see cref="SocketIOClient"/>'s Engine.IO handshake,
    /// auth packet, ping/pong, event and ack framing, and the DTO parsing — the
    /// parts that only a live server can prove.
    ///
    /// Start the server first:
    ///     cd server && npm start
    ///
    /// The tests skip themselves (rather than fail) when no server is reachable,
    /// so the suite stays runnable on a machine without one.
    /// </summary>
    public class LiveServerTests
    {
        private const string ServerUrl = "http://localhost:3000";
        private static bool? _serverAvailable;

        private readonly List<GameConnection> _open = new List<GameConnection>();

        [TearDown]
        public void TearDown()
        {
            foreach (var connection in _open) connection.Disconnect();
            _open.Clear();
        }

        /// <summary>Pumps a connection every frame, the way GameClient.Update does.</summary>
        private IEnumerator PumpUntil(GameConnection connection, Func<bool> done, float timeoutSeconds = 15f)
        {
            var deadline = Time.realtimeSinceStartup + timeoutSeconds;
            while (!done())
            {
                connection.Tick();
                if (Time.realtimeSinceStartup > deadline) yield break;
                yield return null;
            }
            connection.Tick();
        }

        private IEnumerator PumpBoth(
            GameConnection a, GameConnection b, Func<bool> done, float timeoutSeconds = 20f)
        {
            var deadline = Time.realtimeSinceStartup + timeoutSeconds;
            while (!done())
            {
                a.Tick();
                b.Tick();
                if (Time.realtimeSinceStartup > deadline) yield break;
                yield return null;
            }
            a.Tick();
            b.Tick();
        }

        private IEnumerator EnsureServer()
        {
            if (_serverAvailable.HasValue)
            {
                if (!_serverAvailable.Value) Assert.Ignore("No server at " + ServerUrl);
                yield break;
            }

            using var request = UnityEngine.Networking.UnityWebRequest.Get(ServerUrl + "/health");
            request.timeout = 5;
            yield return request.SendWebRequest();

            _serverAvailable = request.result == UnityEngine.Networking.UnityWebRequest.Result.Success;
            if (!_serverAvailable.Value)
            {
                Assert.Ignore("No server at " + ServerUrl + " — start it with: cd server && npm start");
            }
        }

        /// <summary>Logs in a throwaway guest account and returns the session token.</summary>
        private IEnumerator Login(string deviceSuffix, Action<LoginResponse> onDone)
        {
            LoginResponse result = null;
            string error = null;

            var deviceId = "unity-playmode-" + deviceSuffix + "-" + Guid.NewGuid().ToString("N").Substring(0, 8);
            var body = "{\"provider\":\"guest\",\"deviceId\":\"" + deviceId +
                       "\",\"displayName\":\"UnityBot" + deviceSuffix + "\"}";

            yield return ApiClient.Login(ServerUrl, body, response => result = response, message => error = message);

            Assert.IsNull(error, "login failed: " + error);
            Assert.IsNotNull(result, "login returned nothing");
            onDone(result);
        }

        private GameConnection Connect(string token)
        {
            var connection = new GameConnection();
            _open.Add(connection);
            connection.Connect(ServerUrl, token);
            return connection;
        }

        /// <summary>
        /// Seats two clients at a private table of their own.
        ///
        /// Quick-join is restricted to the stakes the lobby offers, and would
        /// also drop the pair onto whatever public table happens to be open.
        /// A private table takes any stake and is reached by code, so each test
        /// gets an isolated room whatever the server is configured with.
        /// </summary>
        private IEnumerator SeatTwo(
            GameConnection host,
            GameConnection guest,
            string category,
            Action<RoomStateDto> onHostJoined = null,
            Action<RoomStateDto> onGuestJoined = null)
        {
            RoomStateDto hostRoom = null;
            RoomStateDto guestRoom = null;
            host.RoomJoined += room => hostRoom = room;
            guest.RoomJoined += room => guestRoom = room;

            // A private table's boot is fixed server-side (requirement 22), so
            // none is chosen here; callers read it back off the room state.
            JoinAckDto created = null;
            host.CreateTable(0, true, category, ack => created = ack);
            yield return PumpBoth(host, guest, () => created != null && hostRoom != null);

            Assert.IsNotNull(created, "the table was created");
            Assert.IsTrue(created.ok, "create failed: " + created.message);

            JoinAckDto joined = null;
            guest.JoinByCode(created.code, ack => joined = ack);
            yield return PumpBoth(host, guest, () => joined != null && guestRoom != null);

            Assert.IsTrue(joined.ok, "join by code failed: " + joined?.message);

            onHostJoined?.Invoke(hostRoom);
            onGuestJoined?.Invoke(guestRoom);
        }

        // ------------------------------------------------------------------ auth

        [UnityTest]
        public IEnumerator GuestLoginGrantsWelcomeChips()
        {
            yield return EnsureServer();

            LoginResponse login = null;
            yield return Login("welcome", response => login = response);

            Assert.IsNotNull(login.token, "a session token was issued");
            Assert.IsTrue(login.isNew, "a fresh device is a new account");
            Assert.AreEqual(200000, login.user.chips, "first-time players get 2 lakh chips");
            Assert.AreEqual("guest", login.user.provider);
        }

        [UnityTest]
        public IEnumerator TheSameDeviceReturnsTheSameAccount()
        {
            yield return EnsureServer();

            var deviceId = "unity-stable-" + Guid.NewGuid().ToString("N").Substring(0, 8);
            var body = "{\"provider\":\"guest\",\"deviceId\":\"" + deviceId + "\",\"displayName\":\"Repeat\"}";

            LoginResponse first = null;
            LoginResponse second = null;

            yield return ApiClient.Login(ServerUrl, body, r => first = r, e => Assert.Fail(e));
            yield return ApiClient.Login(ServerUrl, body, r => second = r, e => Assert.Fail(e));

            Assert.AreEqual(first.user.id, second.user.id, "the account is persisted and reused");
            Assert.IsFalse(second.isNew, "the welcome grant only happens once");
        }

        // ------------------------------------------------------------ handshake

        [UnityTest]
        public IEnumerator SocketIoHandshakeSucceeds()
        {
            yield return EnsureServer();

            LoginResponse login = null;
            yield return Login("handshake", response => login = response);

            var connection = Connect(login.token);

            SessionReadyDto ready = null;
            connection.SessionReady += payload => ready = payload;

            yield return PumpUntil(connection, () => ready != null);

            Assert.IsNotNull(ready, "session:ready never arrived — the handshake failed");
            Assert.AreEqual(login.user.id, ready.user.id);
            Assert.AreEqual(5, ready.config.maxPlayers, "server config parsed");
            Assert.AreEqual(2, ready.config.minPlayers);
            Assert.AreEqual(25000, ready.config.turnTimeoutMs);
            Assert.IsTrue(connection.IsConnected);
        }

        [UnityTest]
        public IEnumerator ABadTokenIsRejected()
        {
            yield return EnsureServer();

            var connection = Connect("definitely-not-a-valid-token");

            var connected = false;
            string failure = null;
            connection.SessionReady += _ => connected = true;
            connection.TransportError += error => failure = error;
            connection.Disconnected += reason => failure ??= reason;

            yield return PumpUntil(connection, () => connected || failure != null, 10f);

            Assert.IsFalse(connected, "a bad token must not produce a session");
        }

        // ------------------------------------------------------------- gameplay

        [UnityTest]
        public IEnumerator TwoClientsPlayAHandThroughToSettlement()
        {
            yield return EnsureServer();

            LoginResponse alice = null;
            LoginResponse bob = null;
            yield return Login("alice", r => alice = r);
            yield return Login("bob", r => bob = r);

            var ca = Connect(alice.token);
            var cb = Connect(bob.token);

            var readyA = false;
            var readyB = false;
            ca.SessionReady += _ => readyA = true;
            cb.SessionReady += _ => readyB = true;

            yield return PumpBoth(ca, cb, () => readyA && readyB);
            Assert.IsTrue(readyA && readyB, "both clients connected");

            RoomStateDto joinedA = null;
            RoomStateDto joinedB = null;

            HandStartedDto started = null;
            YourTurnDto turnA = null;
            YourTurnDto turnB = null;
            HandEndedDto ended = null;
            PlayerCardsDto cardsA = null;
            PlayerCardsDto cardsB = null;

            ca.HandStarted += payload => started = payload;
            ca.YourTurn += payload => turnA = payload;
            cb.YourTurn += payload => turnB = payload;
            ca.HandEnded += payload => ended = payload;
            ca.CardsReceived += payload => cardsA = payload;
            cb.CardsReceived += payload => cardsB = payload;

            yield return SeatTwo(ca, cb, TableCategory.Seen,
                room => joinedA = room, room => joinedB = room);
            var boot = joinedA.bootAmount;

            Assert.IsNotNull(joinedA, "client A joined a table");
            Assert.IsNotNull(joinedB, "client B joined a table");
            Assert.AreEqual(joinedA.roomId, joinedB.roomId, "both were seated at the same table");
            Assert.AreEqual(5, joinedA.maxPlayers);

            // Cards must be hidden on arrival.
            Assert.IsTrue(joinedA.you.cards == null || joinedA.you.cards.Length == 0,
                "cards stay face down until the player looks");

            yield return PumpBoth(ca, cb, () => started != null);
            Assert.IsNotNull(started, "a hand was dealt once two players were seated");
            Assert.AreEqual(boot * 2, started.pot, "both players anted the boot");

            yield return PumpBoth(ca, cb, () => turnA != null || turnB != null);

            var onTurnIsA = turnA != null;
            var actor = onTurnIsA ? ca : cb;
            var options = onTurnIsA ? turnA.options : turnB.options;

            Assert.IsTrue(options.IsActionable, "the player on turn got real options");
            Assert.AreEqual(boot, options.chaal, "a blind player may bet the stake");
            Assert.AreEqual(boot * 2, options.raise, "or double it");
            Assert.IsTrue(options.canSee);

            // Look at our cards: the server should send exactly three, to us only.
            actor.See();
            yield return PumpBoth(ca, cb, () => (onTurnIsA ? cardsA : cardsB) != null);

            var myCards = onTurnIsA ? cardsA : cardsB;
            Assert.IsNotNull(myCards, "player:cards arrived after 'see'");
            Assert.AreEqual(3, myCards.cards.Length, "exactly three cards");
            foreach (var code in myCards.cards)
            {
                Assert.AreEqual(2, code.Length, "card code is rank+suit, e.g. 'As'");
                Assert.IsTrue("shdc".IndexOf(code[1]) >= 0, "valid suit in " + code);
            }

            var opponentCards = onTurnIsA ? cardsB : cardsA;
            Assert.IsNull(opponentCards, "the opponent never receives our card faces");

            // Two players left, so a show is available and ends the hand.
            yield return PumpBoth(ca, cb, () => false, 0.4f);
            actor.Show();

            yield return PumpBoth(ca, cb, () => ended != null, 20f);

            Assert.IsNotNull(ended, "the hand ended");
            Assert.IsNotEmpty(ended.winnerId, "exactly one winner");
            Assert.AreEqual(2, ended.reveals.Length, "both hands were revealed at the show");
            Assert.IsNotEmpty(ended.reveals[0].handName, "the hand name parsed, e.g. 'Pair'");
            Assert.Greater(ended.pot, 0);

            // And the result was written to the database.
            UserDto profile = null;
            var winnerToken = ended.winnerId == alice.user.id ? alice.token : bob.token;
            yield return ApiClient.GetProfile(ServerUrl, winnerToken, user => profile = user, e => Assert.Fail(e));

            Assert.IsNotNull(profile);
            Assert.AreEqual(1, profile.handsWon, "the win was persisted");
            Assert.Greater(profile.chips, 200000, "winnings reached the database");

            // "Played" counts only for a player who committed chips beyond the
            // boot, so it is checked against whoever paid for the show.
            UserDto caller = null;
            var callerToken = onTurnIsA ? alice.token : bob.token;
            yield return ApiClient.GetProfile(ServerUrl, callerToken, user => caller = user, e => Assert.Fail(e));

            Assert.AreEqual(1, caller.handsPlayed, "paying for the show counts as playing");
        }

        /// <summary>
        /// The +/- stepper against the real server: the ladder doubles, stays
        /// inside the player's stack, and a rung placed as a bet is accepted
        /// while an off-ladder amount is refused.
        ///
        /// This uses a public blind table, which is the only kind that keeps the
        /// open-ended ladder — seen and private tables allow one double per turn.
        /// </summary>
        [UnityTest]
        public IEnumerator RaiseLadderIsUsableAndBounded()
        {
            yield return EnsureServer();

            LoginResponse alice = null;
            LoginResponse bob = null;
            yield return Login("ladderA", r => alice = r);
            yield return Login("ladderB", r => bob = r);

            var ca = Connect(alice.token);
            var cb = Connect(bob.token);

            GameConfigDto serverConfig = null;
            var readyB = false;
            ca.SessionReady += payload => serverConfig = payload.config;
            cb.SessionReady += _ => readyB = true;
            yield return PumpBoth(ca, cb, () => serverConfig != null && readyB);

            // The biggest stake the lobby offers gives the ladder room to run.
            var boot = serverConfig.stakes[serverConfig.stakes.Length - 1];

            YourTurnDto turnA = null;
            YourTurnDto turnB = null;
            ca.YourTurn += payload => turnA = payload;
            cb.YourTurn += payload => turnB = payload;

            ca.QuickJoin(boot, TableCategory.Blind);
            cb.QuickJoin(boot, TableCategory.Blind);

            yield return PumpBoth(ca, cb, () => turnA != null || turnB != null);

            var onTurnIsA = turnA != null;
            var actor = onTurnIsA ? ca : cb;
            var options = (onTurnIsA ? turnA : turnB).options;

            // The ladder must double on every rung and never exceed the stack.
            Assert.GreaterOrEqual(options.raiseSteps.Length, 3, "a blind table keeps doubling");
            Assert.AreEqual(boot, options.raiseSteps[0], "rung 0 is the chaal");
            for (var i = 1; i < options.raiseSteps.Length; i++)
            {
                Assert.AreEqual(options.raiseSteps[i - 1] * 2, options.raiseSteps[i], "each + doubles");
            }
            foreach (var step in options.raiseSteps)
            {
                Assert.LessOrEqual(step, options.chips, "never more than the player holds");
            }

            // An amount that is not on the ladder must be refused.
            JoinAckDto badAck = null;
            actor.Bet(GameAction.Raise, options.raiseSteps[1] + 1, ack => badAck = ack);
            yield return PumpBoth(ca, cb, () => badAck != null);

            Assert.IsNotNull(badAck);
            Assert.IsFalse(badAck.ok, "an off-ladder amount is rejected");

            // A bet far beyond the stack must be refused too.
            JoinAckDto hugeAck = null;
            actor.Bet(GameAction.Raise, 100000000, ack => hugeAck = ack);
            yield return PumpBoth(ca, cb, () => hugeAck != null);
            Assert.IsFalse(hugeAck.ok, "a bet beyond the stack is rejected");

            // Two taps of "+" — rung 2 — is accepted, and the pot grows by it.
            var chosen = options.raiseSteps[2];
            ActionDto placed = null;
            ca.PlayerActed += payload =>
            {
                if (payload.action == GameAction.Raise) placed = payload;
            };

            JoinAckDto goodAck = null;
            actor.Bet(GameAction.Raise, chosen, ack => goodAck = ack);
            yield return PumpBoth(ca, cb, () => goodAck != null && placed != null);

            Assert.IsTrue(goodAck.ok, "a rung of the ladder is accepted");
            Assert.AreEqual(chosen, placed.amount, "the exact chosen amount was staked");
            Assert.AreEqual(boot * 2 + chosen, placed.pot, "the pot grew by that amount");
        }

        [UnityTest]
        public IEnumerator ActingOutOfTurnIsRefused()
        {
            yield return EnsureServer();

            LoginResponse login = null;
            yield return Login("outofturn", r => login = r);

            var connection = Connect(login.token);
            var ready = false;
            connection.SessionReady += _ => ready = true;
            yield return PumpUntil(connection, () => ready);

            // Not at a table at all, so any action must come back refused.
            JoinAckDto ack = null;
            connection.SendAction(GameAction.Chaal, result => ack = result);
            yield return PumpUntil(connection, () => ack != null);

            Assert.IsNotNull(ack, "the server acked the illegal action");
            Assert.IsFalse(ack.ok);
            Assert.IsNotEmpty(ack.message);
        }

        // -------------------------------------------------- blind / seen tables

        /// <summary>
        /// On a seen table every stack is visible; on a blind table only your own
        /// is. The hiding happens server-side, so the client genuinely has no
        /// figure to display for anyone else.
        /// </summary>
        [UnityTest]
        public IEnumerator SeenTablesShowEveryStack()
        {
            yield return EnsureServer();

            LoginResponse alice = null;
            LoginResponse bob = null;
            yield return Login("seenA", r => alice = r);
            yield return Login("seenB", r => bob = r);

            var ca = Connect(alice.token);
            var cb = Connect(bob.token);

            var readyA = false;
            var readyB = false;
            ca.SessionReady += _ => readyA = true;
            cb.SessionReady += _ => readyB = true;
            yield return PumpBoth(ca, cb, () => readyA && readyB);

            RoomStateDto state = null;
            ca.RoomStateChanged += room =>
            {
                var seated = 0;
                foreach (var seat in room.seats)
                {
                    if (seat.IsOccupied) seated++;
                }
                if (seated == 2) state = room;
            };

            yield return SeatTwo(ca, cb, TableCategory.Seen);
            yield return PumpBoth(ca, cb, () => state != null);

            Assert.IsNotNull(state, "both players were seated");
            Assert.AreEqual(TableCategory.Seen, state.category);
            Assert.IsFalse(state.chipsHidden);

            foreach (var seat in state.seats)
            {
                if (!seat.IsOccupied) continue;
                Assert.IsTrue(seat.ChipsKnown(state.chipsHidden, alice.user.id), "every stack is known");
                Assert.Greater(seat.chips, 0, seat.displayName + "'s stack is visible");
            }
        }

        [UnityTest]
        public IEnumerator BlindTablesHideOtherPlayersStacks()
        {
            yield return EnsureServer();

            LoginResponse alice = null;
            LoginResponse bob = null;
            yield return Login("blindA", r => alice = r);
            yield return Login("blindB", r => bob = r);

            var ca = Connect(alice.token);
            var cb = Connect(bob.token);

            var readyA = false;
            var readyB = false;
            ca.SessionReady += _ => readyA = true;
            cb.SessionReady += _ => readyB = true;
            yield return PumpBoth(ca, cb, () => readyA && readyB);

            RoomStateDto state = null;
            ca.RoomStateChanged += room =>
            {
                var seated = 0;
                foreach (var seat in room.seats)
                {
                    if (seat.IsOccupied) seated++;
                }
                if (seated == 2) state = room;
            };

            RoomStateDto joined = null;
            yield return SeatTwo(ca, cb, TableCategory.Blind, room => joined = room);
            yield return PumpBoth(ca, cb, () => state != null);

            Assert.IsNotNull(joined, "the blind table was created and joined");
            Assert.AreEqual(TableCategory.Blind, joined.category, "the server seated us on a blind table");
            Assert.AreEqual(TableCategory.Blind, state.category);
            Assert.IsTrue(state.chipsHidden);

            foreach (var seat in state.seats)
            {
                if (!seat.IsOccupied) continue;

                if (seat.userId == alice.user.id)
                {
                    Assert.IsTrue(seat.ChipsKnown(state.chipsHidden, alice.user.id), "your own stack is known");
                    Assert.Greater(seat.chips, 0);
                }
                else
                {
                    Assert.IsFalse(seat.ChipsKnown(state.chipsHidden, alice.user.id),
                        "another player's stack is withheld");
                    Assert.AreEqual(0, seat.chips, "a withheld stack arrives as the JsonUtility default");
                }
            }

            // You always know what you hold, even on a blind table.
            Assert.IsTrue(state.you.IsSeated);
            Assert.Greater(state.you.chips, 0);
        }

        [UnityTest]
        public IEnumerator BlindAndSeenTablesAreSeparateRooms()
        {
            yield return EnsureServer();

            LoginResponse alice = null;
            LoginResponse bob = null;
            yield return Login("splitA", r => alice = r);
            yield return Login("splitB", r => bob = r);

            var ca = Connect(alice.token);
            var cb = Connect(bob.token);

            GameConfigDto serverConfig = null;
            var readyB = false;
            ca.SessionReady += payload => serverConfig = payload.config;
            cb.SessionReady += _ => readyB = true;
            yield return PumpBoth(ca, cb, () => serverConfig != null && readyB);

            // Quick-join is what routes by category, so this test has to use a
            // stake the lobby actually offers.
            var boot = serverConfig.stakes != null && serverConfig.stakes.Length > 0
                ? serverConfig.stakes[0]
                : serverConfig.bootAmount;

            JoinAckDto blindAck = null;
            JoinAckDto seenAck = null;
            ca.QuickJoin(boot, TableCategory.Blind, result => blindAck = result);
            cb.QuickJoin(boot, TableCategory.Seen, result => seenAck = result);

            yield return PumpBoth(ca, cb, () => blindAck != null && seenAck != null);

            Assert.IsTrue(blindAck.ok);
            Assert.IsTrue(seenAck.ok);
            Assert.AreNotEqual(blindAck.roomId, seenAck.roomId,
                "the same stake in different categories is two rooms");
        }

        /// <summary>
        /// Requirement 22: a private table has a fixed boot, caps what can be
        /// won, and allows one double per turn.
        /// </summary>
        [UnityTest]
        public IEnumerator PrivateTablesAreFixedAndCapped()
        {
            yield return EnsureServer();

            LoginResponse alice = null;
            LoginResponse bob = null;
            yield return Login("privA", r => alice = r);
            yield return Login("privB", r => bob = r);

            var ca = Connect(alice.token);
            var cb = Connect(bob.token);

            GameConfigDto serverConfig = null;
            var readyB = false;
            ca.SessionReady += payload => serverConfig = payload.config;
            cb.SessionReady += _ => readyB = true;
            yield return PumpBoth(ca, cb, () => serverConfig != null && readyB);

            Assert.AreEqual(200, serverConfig.privateBoot, "the fixed boot is advertised");
            Assert.AreEqual(500000, serverConfig.privateMaxPot, "and so is the maximum win");

            // Ask for a wildly different boot: the server fixes it regardless.
            RoomStateDto joined = null;
            RoomStateDto guestRoom = null;
            ca.RoomJoined += room => joined = room;
            cb.RoomJoined += room => guestRoom = room;

            JoinAckDto created = null;
            ca.CreateTable(99999, true, TableCategory.Blind, ack => created = ack);
            yield return PumpBoth(ca, cb, () => created != null && joined != null);

            Assert.IsTrue(created.ok, "create failed: " + created.message);
            Assert.AreEqual(serverConfig.privateBoot, joined.bootAmount,
                "the requested boot is ignored in favour of the fixed one");
            Assert.AreEqual(serverConfig.privateMaxPot, joined.maxPot, "the win is capped");

            YourTurnDto turnA = null;
            YourTurnDto turnB = null;
            ca.YourTurn += payload => turnA = payload;
            cb.YourTurn += payload => turnB = payload;

            JoinAckDto guestAck = null;
            cb.JoinByCode(created.code, ack => guestAck = ack);
            yield return PumpBoth(ca, cb, () => guestAck != null && guestRoom != null);
            Assert.IsTrue(guestAck.ok);

            yield return PumpBoth(ca, cb, () => turnA != null || turnB != null);
            var options = (turnA != null ? turnA : turnB).options;

            Assert.AreEqual(2, options.raiseSteps.Length, "one double per turn, no more");
            Assert.AreEqual(serverConfig.privateBoot, options.raiseSteps[0]);
            Assert.AreEqual(serverConfig.privateBoot * 2, options.raiseSteps[1]);
        }

        // ----------------------------------------------------------- room chat

        [UnityTest]
        public IEnumerator RoomChatDeliversAndBacklogsMessages()
        {
            yield return EnsureServer();

            LoginResponse alice = null;
            LoginResponse bob = null;
            yield return Login("chatA", r => alice = r);
            yield return Login("chatB", r => bob = r);

            var ca = Connect(alice.token);
            var readyA = false;
            ca.SessionReady += _ => readyA = true;
            yield return PumpUntil(ca, () => readyA);

            var boot = 4000 + UnityEngine.Random.Range(1, 500) * 10;

            RoomStateDto joined = null;
            ChatHistoryDto historyA = null;
            ca.RoomJoined += room => joined = room;
            ca.ChatHistoryReceived += payload => historyA = payload;

            JoinAckDto created = null;
            ca.CreateTable(boot, true, TableCategory.Seen, ack => created = ack);
            yield return PumpUntil(ca, () => joined != null && historyA != null && created != null);

            Assert.IsTrue(created.ok, "the table was created");
            Assert.IsNotNull(joined, "joined a table");
            Assert.IsNotNull(historyA, "the room backlog arrived on join");

            ChatMessageDto received = null;
            ca.ChatReceived += message =>
            {
                if (message.text == "hello from unity") received = message;
            };

            ca.SendChat("hello from unity");
            yield return PumpUntil(ca, () => received != null);

            Assert.IsNotNull(received, "the message came back to the room");
            Assert.AreEqual(alice.user.id, received.userId);
            Assert.IsFalse(received.system, "a player message is not a system line");

            // A second player joining the same table must be sent the backlog.
            var cb = Connect(bob.token);
            var readyB = false;
            ChatHistoryDto historyB = null;
            cb.SessionReady += _ => readyB = true;
            cb.ChatHistoryReceived += payload => historyB = payload;

            yield return PumpBoth(ca, cb, () => readyB);
            cb.JoinByCode(joined.code);
            yield return PumpBoth(ca, cb, () => historyB != null);

            Assert.IsNotNull(historyB, "the new player received the room history");

            var sawEarlierMessage = false;
            foreach (var message in historyB.messages)
            {
                if (message.text == "hello from unity") sawEarlierMessage = true;
            }
            Assert.IsTrue(sawEarlierMessage, "the backlog contains the message sent before joining");
        }
    }
}
