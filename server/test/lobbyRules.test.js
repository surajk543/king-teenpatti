/**
 * Requirement 29 (display names) and requirement 30 (the entry cap on the
 * cheapest blind table).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import RoomManager from '../src/game/roomManager.js';
import { normalizeDisplayName } from '../src/db/users.js';
import config from '../src/config/index.js';
import createFakeTimers from './helpers/fakeTimers.js';

// ------------------------------------------------- requirement 29: names

test('a display name keeps letters, numbers and single spaces', () => {
  assert.equal(normalizeDisplayName('  Suraj  Kumar '), 'Suraj Kumar');
  assert.equal(normalizeDisplayName('Player7'), 'Player7');
});

test('a name may be written in any script', () => {
  assert.equal(normalizeDisplayName('सूरज'), 'सूरज');
  assert.equal(normalizeDisplayName('সুরজ'), 'সুরজ');
});

test('an empty or blank name is refused', () => {
  for (const bad of ['', '   ', '\t', null, undefined]) {
    assert.throws(() => normalizeDisplayName(bad), /empty_name/);
  }
});

test('special characters are refused', () => {
  for (const bad of ['Su<b>raj', 'a@b', 'hi!', '--', 'x_y', 'drop;table']) {
    assert.throws(() => normalizeDisplayName(bad), /invalid_name/);
  }
});

test('a name cannot start with a space or a digit-only decoration', () => {
  assert.throws(() => normalizeDisplayName(' '.repeat(3)), /empty_name/);
  assert.throws(() => normalizeDisplayName('!Suraj'), /invalid_name/);
});

test('an over-long name is refused', () => {
  assert.throws(
    () => normalizeDisplayName('a'.repeat(30), { maxLength: 24 }),
    /name_too_long/,
  );
});

// ------------------------------------------- requirement 30: the entry cap

const cap = config.game.entryCapMaxChips;
const capBoot = config.game.entryCapBoot;
const capCategory = config.game.entryCapCategory;

function makeRooms() {
  const { timers } = createFakeTimers();
  return new RoomManager({ timers, settle: () => ({}) });
}

let seq = 0;
// A distinct account each time: deriving the id from the stack made two
// players with the same chips the same person.
const player = (chips) => ({
  id: `u${(seq += 1)}-${chips}`,
  displayName: `Player${seq}`,
  avatarUrl: null,
  chips,
});

test('a big stack cannot join the capped table', () => {
  const rooms = makeRooms();
  assert.throws(
    () => rooms.quickJoin(player(cap + 1), { bootAmount: capBoot, category: capCategory }),
    (error) => error.code === 'over_entry_cap',
  );
});

test('a stack exactly at the cap may still join', () => {
  const rooms = makeRooms();
  assert.doesNotThrow(
    () => rooms.quickJoin(player(cap), { bootAmount: capBoot, category: capCategory }),
  );
});

test('the cap applies only to that stake and category', () => {
  const rooms = makeRooms();
  const rich = player(cap + 1);

  // The same stake in the other category is open.
  const other = capCategory === 'blind' ? 'seen' : 'blind';
  assert.doesNotThrow(
    () => rooms.quickJoin(rich, { bootAmount: capBoot, category: other }),
  );
  rooms.leave(rich.id);

  // And so is the higher stake in the capped category.
  const bigger = config.game.tableStakes.find((s) => s !== capBoot);
  if (bigger) {
    assert.doesNotThrow(
      () => rooms.quickJoin(rich, { bootAmount: bigger, category: capCategory }),
    );
  }
});

test('joining the capped table by code is refused too', () => {
  const rooms = makeRooms();
  // Somebody eligible opens the table first.
  const table = rooms.quickJoin(player(1000), {
    bootAmount: capBoot,
    category: capCategory,
  });

  assert.throws(
    () => rooms.joinByCode(player(cap + 1), table.code),
    (error) => error.code === 'over_entry_cap',
  );
});

test('the lobby is told the rule so it can grey the table out', () => {
  const options = RoomManager.lobbyOptions();
  assert.equal(options.entryCapBoot, capBoot);
  assert.equal(options.entryCapCategory, capCategory);
  assert.equal(options.entryCapMaxChips, cap);
});

test('names in Indic scripts survive their vowel marks', () => {
  // Every one of these carries a combining mark, which is the case that a
  // letters-only pattern silently rejects.
  for (const name of ['सूरज', 'সুরজ', 'સૂરજ', 'ਸੂਰਜ', 'प्रिया']) {
    assert.equal(normalizeDisplayName(name), name);
  }
});

// ------------------------------------- the cap guards the lobby, not a switch

test('a switch is not blocked by the entry cap', () => {
  const rooms = makeRooms();
  const rich = player(cap + 1);

  // Two capped-category tables exist, opened by players who were eligible.
  const first = rooms.quickJoin(player(1000), { bootAmount: capBoot, category: capCategory });
  const second = rooms.createTable({ bootAmount: capBoot, category: capCategory });
  rooms.join(second, player(2000));

  // The rich player is at one of them — they got in before their stack grew,
  // which is what the seat below stands in for.
  rooms.join(first, rich);

  const { table } = rooms.switchTable(rich);
  assert.equal(table.id, second.id, 'moved to the other table');
  assert.equal(rooms.getTableForPlayer(rich.id).id, second.id);
});

test('but the lobby route still refuses them', () => {
  const rooms = makeRooms();
  assert.throws(
    () => rooms.quickJoin(player(cap + 1), { bootAmount: capBoot, category: capCategory }),
    (error) => error.code === 'over_entry_cap',
  );
});

test('a switch never changes the stake or the category', () => {
  const rooms = makeRooms();
  const other = capCategory === 'blind' ? 'seen' : 'blind';

  const home = rooms.quickJoin(player(1000), { bootAmount: capBoot, category: capCategory });
  // A table of a different kind is not a candidate, however empty it is.
  rooms.createTable({ bootAmount: capBoot, category: other });
  const bigger = config.game.tableStakes.find((s) => s !== capBoot);
  if (bigger) rooms.createTable({ bootAmount: bigger, category: capCategory });

  const mover = player(1000);
  rooms.join(home, mover);

  assert.throws(
    () => rooms.switchTable(mover),
    (error) => error.code === 'no_other_table',
    'the only tables around are the wrong kind',
  );
});

test('switching keeps the seat when there is nowhere to go', () => {
  const rooms = makeRooms();
  const home = rooms.quickJoin(player(1000), { bootAmount: capBoot, category: capCategory });
  const mover = player(1000);
  rooms.join(home, mover);

  assert.throws(() => rooms.switchTable(mover), (e) => e.code === 'no_other_table');
  assert.equal(rooms.getTableForPlayer(mover.id)?.id, home.id, 'still seated where they were');
});

test('a player who is not seated cannot switch', () => {
  const rooms = makeRooms();
  assert.throws(
    () => rooms.switchTable(player(1000)),
    (error) => error.code === 'not_in_room',
  );
});
