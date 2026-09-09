/**
 * Who the bots are.
 *
 * Two hundred names that read like a real lobby rather than Bot001…Bot198,
 * because a player who notices they are only ever seated with numbered
 * accounts has learned something you did not mean to tell them.
 *
 * A bot's device id is derived from its index and never changes, so the same
 * bot keeps the same account, the same chips and the same name across
 * restarts. That matters more than it looks: a fresh device id is a fresh
 * account, and every fresh account is another welcome bonus minted out of
 * nothing.
 */
const FIRST = [
  'Aarav', 'Vivaan', 'Aditya', 'Vihaan', 'Arjun', 'Sai', 'Reyansh', 'Krishna',
  'Ishaan', 'Rudra', 'Kabir', 'Ansh', 'Dhruv', 'Yash', 'Rohan', 'Aryan',
  'Kunal', 'Nikhil', 'Manav', 'Tanish', 'Harsh', 'Devansh', 'Om', 'Parth',
  'Rehan', 'Samar', 'Veer', 'Yuvan', 'Zayan', 'Ayaan',
  'Ananya', 'Diya', 'Aadhya', 'Saanvi', 'Pari', 'Anika', 'Navya', 'Riya',
  'Meera', 'Kavya', 'Isha', 'Sneha', 'Pooja', 'Neha', 'Priya', 'Tara',
  'Nitya', 'Aarohi', 'Mahi', 'Siya', 'Ira', 'Myra', 'Kiara', 'Avni',
  'Rhea', 'Anvi', 'Trisha', 'Vaani', 'Zara', 'Amaira',
];

const SUFFIX = [
  '', '', '', '', '', // most people just use a name
  '_07', '_99', '_11', '21', '_x', 'raja', 'king', 'ji', '_pro', '143',
  '_gaming', '01', '_bhai', 'star', '786',
];

/**
 * A stable identity for bot `index`.
 *
 * The suffix is picked from the index too, so the same bot is the same person
 * every run. Display names are capped at the server's DISPLAY_NAME_MAX (24).
 */
export function identityFor(index) {
  const first = FIRST[index % FIRST.length];
  const suffix = SUFFIX[Math.floor(index / FIRST.length) % SUFFIX.length];
  const name = `${first}${suffix}`.slice(0, 24);
  return {
    name,
    // Namespaced so these can never collide with the practice bots in tools/
    // or with the ramp test's `ramp-bot-*` accounts.
    deviceId: `botplay-v1-${index}`,
  };
}

/**
 * A throwaway identity for a bot that went broke and is being rotated.
 *
 * Deliberately carries the generation in the device id: a rotated bot is a new
 * account, and being able to count them in the database later is the only way
 * to answer "how many chips has the fleet created?" after the fact.
 */
export function rotatedIdentity(index, generation) {
  const base = identityFor(index);
  return {
    name: base.name,
    deviceId: `botplay-v1-${index}-g${generation}`,
  };
}
