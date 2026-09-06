using UnityEngine;

namespace KingTeenPatti.Game
{
    /// <summary>
    /// Display helpers for the server's card codes.
    ///
    /// The wire format is a rank character followed by a suit letter — "As",
    /// "Td", "7h" — matching src/game/deck.js on the server.
    /// </summary>
    public static class Card
    {
        public static readonly Color Red = new Color(0.78f, 0.16f, 0.16f);
        public static readonly Color Black = new Color(0.09f, 0.09f, 0.11f);

        public static string RankOf(string code)
        {
            if (string.IsNullOrEmpty(code)) return "?";
            return code[0] == 'T' ? "10" : code[0].ToString();
        }

        public static char SuitOf(string code) =>
            string.IsNullOrEmpty(code) || code.Length < 2 ? '?' : code[1];

        public static string SuitSymbol(string code)
        {
            switch (SuitOf(code))
            {
                case 's': return "♠"; // ♠
                case 'h': return "♥"; // ♥
                case 'd': return "♦"; // ♦
                case 'c': return "♣"; // ♣
                default: return "?";
            }
        }

        public static bool IsRed(string code)
        {
            var suit = SuitOf(code);
            return suit == 'h' || suit == 'd';
        }

        public static Color ColorOf(string code) => IsRed(code) ? Red : Black;

        /// <summary>"As" -> "A♠", for logs and result lines.</summary>
        public static string Pretty(string code) => RankOf(code) + SuitSymbol(code);

        public static string PrettyHand(string[] codes)
        {
            if (codes == null || codes.Length == 0) return string.Empty;
            var parts = new string[codes.Length];
            for (var i = 0; i < codes.Length; i++) parts[i] = Pretty(codes[i]);
            return string.Join(" ", parts);
        }
    }
}
