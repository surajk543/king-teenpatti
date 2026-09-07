using System;

namespace KingTeenPatti.Models
{
    /// <summary>
    /// Wire models for every server payload.
    ///
    /// These are shaped for Unity's JsonUtility: plain [Serializable] classes
    /// with public fields whose names match the server's JSON exactly. Fields
    /// the server may omit simply stay at their default, which is why ids are
    /// strings and money is long — a chip balance and a millisecond deadline
    /// both overflow int.
    /// </summary>

    /// <summary>
    /// The two collectable rewards: a milestone every 25 hands played, and a
    /// bonus that recharges over 4 hours. Both unlock times come from the
    /// server, so a countdown cannot be skipped by restarting the app.
    /// </summary>
    [Serializable]
    public class RewardsDto
    {
        public bool milestoneAvailable;
        public int milestoneAt;
        public long milestoneReward;
        public int milestoneEvery;
        public int handsToNextMilestone;
        /// <summary>Epoch ms the timed bonus unlocks; 0 means it is ready now.</summary>
        public long bonusReadyAt;
        public bool bonusAvailable;
        public long bonusReward;
        public long bonusIntervalMs;

        /// <summary>Milliseconds until the bonus is collectable, 0 when ready.</summary>
        public long MillisecondsUntilBonus =>
            Math.Max(0, bonusReadyAt - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

        public bool IsBonusReady => MillisecondsUntilBonus <= 0;
    }

    [Serializable]
    public class UserDto
    {
        public string id;
        public string provider;
        public string displayName;
        public string email;
        /// <summary>The picture to show: a chosen one, else the Google/Facebook one.</summary>
        public string avatarUrl;
        /// <summary>The picture Google or Facebook gave us, kept even when overridden.</summary>
        public string providerAvatarUrl;
        /// <summary>The bundled picture the player picked, or null.</summary>
        public string avatarChoice;
        public long chips;
        public int handsPlayed;
        public int handsWon;
        public int handsLost;
        /// <summary>Hands abandoned before they finished.</summary>
        public int handsLeftMid;
        /// <summary>Gross chips taken in pots won.</summary>
        public long totalWinnings;
        public long biggestPot;
        public RewardsDto rewards;
        public long createdAt;
        public long lastLoginAt;
    }

    /// <summary>One picture from the bundled profiles folder.</summary>
    [Serializable]
    public class ProfilePictureDto
    {
        public string id;
        public string url;
    }

    [Serializable]
    public class ProfilePictureListDto
    {
        public ProfilePictureDto[] profiles;
    }

    /// <summary>Reply from a reward claim.</summary>
    [Serializable]
    public class RewardClaimDto
    {
        public bool claimed;
        public long amount;
        public int milestone;
        public long readyAt;
        public string error;
        public string message;
        public UserDto user;
    }

    [Serializable]
    public class LoginResponse
    {
        public string token;
        public UserDto user;
        public bool isNew;
        public long welcomeChips;
    }

    [Serializable]
    public class ErrorResponse
    {
        public string error;
        public string message;
    }

    [Serializable]
    public class GameConfigDto
    {
        public int maxPlayers;
        public int minPlayers;
        public long bootAmount;
        public int turnTimeoutMs;
        public long welcomeChips;
        public int maxBetRounds;
        /// <summary>The categories the lobby offers, e.g. ["seen", "blind"].</summary>
        public string[] categories;
        /// <summary>The stakes the lobby offers, e.g. [200, 5000].</summary>
        public long[] stakes;
        /// <summary>A private table's fixed boot (requirement 22). Not chosen.</summary>
        public long privateBoot;
        /// <summary>Most a private table can pay out; 0 when uncapped.</summary>
        public long privateMaxPot;
    }

    [Serializable]
    public class SessionReadyDto
    {
        public UserDto user;
        public GameConfigDto config;
    }

    [Serializable]
    public class SeatDto
    {
        public int seatIndex;
        public string userId;
        public string displayName;
        /// <summary>Shown to everyone at the table (requirements 20 and 21).</summary>
        public string avatarUrl;
        /// <summary>
        /// This player's stack. On a blind table the server sends null for every
        /// seat but yours; JsonUtility cannot hold null in a long, so it arrives
        /// as 0. Always check <see cref="ChipsKnown"/> before displaying it.
        /// </summary>
        public long chips;
        /// <summary>empty | waiting | active | packed | lost | won</summary>
        public string status;
        public bool isBlind;
        public long contributed;
        public bool connected;
        public int cardCount;

        public bool IsOccupied => status != "empty";

        /// <summary>
        /// False when this seat's stack was withheld (a blind table, someone
        /// else's seat). JsonUtility cannot represent null for a long, so a
        /// withheld stack arrives as 0 — which is indistinguishable from a
        /// player who is genuinely broke. RoomStateDto.chipsHidden disambiguates
        /// it, and TableView passes that in here.
        /// </summary>
        public bool ChipsKnown(bool chipsHidden, string viewerUserId) =>
            !chipsHidden || userId == viewerUserId;
    }

    /// <summary>The two amounts a player may bet, plus what else is legal right now.</summary>
    [Serializable]
    public class TurnOptionsDto
    {
        public bool canSee;
        /// <summary>Bet the same amount. 0 when the player cannot afford it.</summary>
        public long chaal;
        /// <summary>Bet double. 0 when the player cannot afford it.</summary>
        public long raise;
        /// <summary>
        /// Every legal bet, ascending, each double the last: base, 2x, 4x, …
        /// This is what the "+" and "−" buttons step through. The server has
        /// already capped it to the pot limit and to the player's own chips, so
        /// any rung here is affordable and no rung above it exists.
        /// Index 0 is the plain chaal, so a raise starts at index 1.
        /// </summary>
        public long[] raiseSteps;
        /// <summary>The largest bet available right now; 0 when none is.</summary>
        public long maxBet;
        /// <summary>Cost of calling a show; 0 unless exactly two players remain.</summary>
        public long show;
        public bool canPack;
        public bool isBlind;
        public long currentStake;
        /// <summary>The player's remaining stack, for the "you have N left" hint.</summary>
        public long chips;
        public long pot;

        /// <summary>
        /// True when these options are real rather than a JsonUtility placeholder.
        ///
        /// The server sends <c>options: null</c> when it is not your turn, but
        /// Unity's JsonUtility cannot represent a null nested object — it hands
        /// back a zeroed instance instead. Packing is legal on every real turn,
        /// so <c>canPack</c> is the reliable "these options exist" marker.
        /// </summary>
        public bool IsActionable => canPack;
    }

    [Serializable]
    public class SelfDto
    {
        public int seatIndex;
        public long chips;
        public string status;
        public bool isBlind;
        public long contributed;
        /// <summary>Empty until this player has seen their cards.</summary>
        public string[] cards;
        public TurnOptionsDto options;

        /// <summary>False when the server sent <c>you: null</c> (not seated).</summary>
        public bool IsSeated => !string.IsNullOrEmpty(status);
    }

    [Serializable]
    public class TurnDto
    {
        public int seatIndex;
        public string userId;
        public long deadline;

        /// <summary>False when the server sent <c>turn: null</c> (no hand in progress).</summary>
        public bool HasTurn => !string.IsNullOrEmpty(userId);
    }

    /// <summary>A full table snapshot, redacted for the receiving player.</summary>
    [Serializable]
    public class RoomStateDto
    {
        public string roomId;
        public string code;
        /// <summary>"seen" — all stacks visible; "blind" — only your own.</summary>
        public string category;
        /// <summary>True when other players' chip stacks are withheld.</summary>
        public bool chipsHidden;
        /// <summary>waiting | starting | betting | showdown</summary>
        public string state;
        public int handNo;
        public int dealerSeat;
        public int maxPlayers;
        public int minPlayers;
        public long bootAmount;
        public int turnTimeoutMs;
        public long startsAt;
        public long pot;
        /// <summary>
        /// The table's pot ceiling, or 0 when uncapped. Private tables set this
        /// (requirement 22); once it is reached the hand goes to a showdown.
        /// </summary>
        public long maxPot;
        public long stake;
        public int round;
        public TurnDto turn;
        public SelfDto you;
        public SeatDto[] seats;
    }

    [Serializable]
    public class HandStartedDto
    {
        public string roomId;
        public string handId;
        public int handNo;
        public int dealerSeat;
        public long bootAmount;
        public long pot;
        public long stake;
        public string[] participants;
    }

    [Serializable]
    public class TurnChangedDto
    {
        public string roomId;
        public string userId;
        public int seatIndex;
        public long deadline;
        public int timeoutMs;
    }

    [Serializable]
    public class YourTurnDto
    {
        public string roomId;
        public long deadline;
        public int timeoutMs;
        public TurnOptionsDto options;
    }

    [Serializable]
    public class ActionDto
    {
        public string roomId;
        public string userId;
        /// <summary>see | chaal | raise | pack | show</summary>
        public string action;
        public long amount;
        public long pot;
        public long stake;
        /// <summary>"timeout" when the player was packed by the turn clock.</summary>
        public string reason;
    }

    [Serializable]
    public class RevealDto
    {
        public string userId;
        public int seatIndex;
        public string[] cards;
        public string handName;
        public int category;
        public bool won;
    }

    [Serializable]
    public class ShowdownDto
    {
        public string roomId;
        public string reason;
        public RevealDto[] reveals;
    }

    [Serializable]
    public class HandSummaryRowDto
    {
        public string userId;
        public string displayName;
        public int seatIndex;
        public long contributed;
        public string status;
        public bool sawCards;
        public string[] cards;
    }

    [Serializable]
    public class HandEndedDto
    {
        public string roomId;
        public string handId;
        public int handNo;
        public string winnerId;
        public string winnerName;
        public long pot;
        /// <summary>last_standing | show | forced_showdown</summary>
        public string reason;
        public RevealDto[] reveals;
        public HandSummaryRowDto[] summary;
        public long nextHandAt;
    }

    [Serializable]
    public class PlayerCardsDto
    {
        public string roomId;
        public string[] cards;
    }

    [Serializable]
    public class GameErrorDto
    {
        public string code;
        public string message;
    }

    [Serializable]
    public class JoinAckDto
    {
        public bool ok;
        public string roomId;
        public string code;
        /// <summary>The category the server actually seated you in.</summary>
        public string category;
        /// <summary>Set when ok is false.</summary>
        public string message;
    }

    [Serializable]
    public class TableSummaryDto
    {
        public string roomId;
        public string code;
        /// <summary>"seen" or "blind".</summary>
        public string category;
        public string state;
        public int players;
        public int maxPlayers;
        public long bootAmount;
        public long pot;
    }

    [Serializable]
    public class TableListDto
    {
        public TableSummaryDto[] tables;
    }

    /// <summary>
    /// One room chat message.
    ///
    /// Chat is scoped to a single table and kept in server memory only — it is
    /// never written to the database, and the whole log is discarded when the
    /// last player leaves the room.
    /// </summary>
    [Serializable]
    public class ChatMessageDto
    {
        public string id;
        public string roomId;
        /// <summary>Null for system lines such as "Bob joined the table".</summary>
        public string userId;
        public string displayName;
        public string text;
        public long at;
        /// <summary>True for table announcements rather than player messages.</summary>
        public bool system;
    }

    /// <summary>The room's backlog, oldest first, sent right after joining.</summary>
    [Serializable]
    public class ChatHistoryDto
    {
        public string roomId;
        public ChatMessageDto[] messages;
    }

    [Serializable]
    public class SessionReplacedDto
    {
        public string message;
    }

    /// <summary>
    /// Requirement 24: two rooms that had dwindled to one player each were
    /// merged, and this player was moved. The new room follows immediately as a
    /// normal room:joined, so this only explains why.
    /// </summary>
    [Serializable]
    public class RoomMovedDto
    {
        public string fromRoomId;
        public string toRoomId;
        public string code;
        public string message;
    }

    /// <summary>Actions the client may send. Mirrors the server's ACTION constants.</summary>
    public static class GameAction
    {
        public const string See = "see";
        public const string Chaal = "chaal";
        public const string Raise = "raise";
        public const string Pack = "pack";
        public const string Show = "show";
    }

    /// <summary>
    /// Table categories. These control chip visibility, not betting:
    /// "seen" shows every player's stack, "blind" shows only your own.
    /// </summary>
    public static class TableCategory
    {
        public const string Seen = "seen";
        public const string Blind = "blind";
    }

    public static class TableState
    {
        public const string Waiting = "waiting";
        public const string Starting = "starting";
        public const string Betting = "betting";
        public const string Showdown = "showdown";
    }

    public static class SeatState
    {
        public const string Empty = "empty";
        public const string Waiting = "waiting";
        public const string Active = "active";
        public const string Packed = "packed";
        public const string Lost = "lost";
        public const string Won = "won";
    }
}
