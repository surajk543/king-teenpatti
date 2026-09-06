import test from 'node:test';
import assert from 'node:assert/strict';
import { RoomChat } from '../src/game/chat.js';
import Table from '../src/game/table.js';
import createFakeTimers from './helpers/fakeTimers.js';

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: 100,
  turnTimeoutMs: 25000,
  maxBetRounds: 20,
  potLimitMultiplier: 1024,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
};

function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const table = new Table({
    id: 'room-chat',
    code: 'CHAT01',
    config: { ...baseConfig, ...overrides },
    timers,
    settle: () => ({}),
  });

  const chatEvents = [];
  table.on('chat', (message) => chatEvents.push(message));

  const seat = (id, name = id) =>
    table.addPlayer({ userId: id, displayName: name, avatarUrl: null, chips: 200000, socketId: `s-${id}` });

  return { table, advance, chatEvents, seat };
}

// -------------------------------------------------------------- the buffer

test('messages are stored in order with author and timestamp', () => {
  const chat = new RoomChat();
  chat.add({ userId: 'u1', displayName: 'Alice', text: 'hello' });
  chat.add({ userId: 'u2', displayName: 'Bob', text: 'gg' });

  const history = chat.history();
  assert.equal(history.length, 2);
  assert.equal(history[0].text, 'hello');
  assert.equal(history[0].displayName, 'Alice');
  assert.equal(history[0].userId, 'u1');
  assert.ok(history[0].at > 0);
  assert.ok(history[0].id);
  assert.equal(history[1].text, 'gg');
});

test('history is capped at 100 messages, keeping the newest', () => {
  const chat = new RoomChat();

  for (let i = 1; i <= 150; i += 1) {
    chat.add({ userId: 'u1', displayName: 'Alice', text: `msg ${i}` });
  }

  const history = chat.history();
  assert.equal(history.length, 100, 'the buffer never exceeds the cap');
  assert.equal(history[0].text, 'msg 51', 'the oldest messages were dropped');
  assert.equal(history[99].text, 'msg 150', 'the newest message is kept');
});

test('the cap is configurable', () => {
  const chat = new RoomChat({ maxHistory: 3 });
  for (const text of ['a', 'b', 'c', 'd', 'e']) chat.add({ userId: 'u', displayName: 'U', text });

  assert.deepEqual(chat.history().map((message) => message.text), ['c', 'd', 'e']);
});

test('empty and whitespace-only messages are dropped', () => {
  const chat = new RoomChat();
  assert.equal(chat.add({ userId: 'u', displayName: 'U', text: '' }), null);
  assert.equal(chat.add({ userId: 'u', displayName: 'U', text: '    ' }), null);
  assert.equal(chat.add({ userId: 'u', displayName: 'U', text: null }), null);
  assert.equal(chat.size, 0);
});

test('control characters are stripped and long messages are trimmed', () => {
  const chat = new RoomChat({ maxLength: 20 });

  // The escape byte is removed; the "[31m" after it is ordinary printable text
  // and is left alone, so the sequence can no longer colour a terminal.
  const sneaky = chat.add({ userId: 'u', displayName: 'U', text: 'hi \u001b[31m there' });
  assert.equal(sneaky.text, 'hi [31m there');
  assert.ok(!sneaky.text.includes('\u001b'), 'no control character reaches a client');

  const newlines = chat.add({ userId: 'u', displayName: 'U', text: 'one\ntwo\r\nthree' });
  assert.equal(newlines.text, 'one two three', 'newlines collapse into spaces');

  const long = chat.add({ userId: 'u', displayName: 'U', text: 'x'.repeat(200) });
  assert.equal(long.text.length, 20);
});

test('clearing drops the whole history', () => {
  const chat = new RoomChat();
  chat.add({ userId: 'u', displayName: 'U', text: 'hello' });
  chat.clear();
  assert.equal(chat.size, 0);
  assert.deepEqual(chat.history(), []);
});

// --------------------------------------------------------------- the table

test('a seated player can post to their room', () => {
  const { table, seat, chatEvents } = makeTable();
  seat('alice', 'Alice');

  const message = table.postChat('alice', 'good luck everyone');

  assert.equal(message.text, 'good luck everyone');
  assert.equal(message.displayName, 'Alice');
  assert.ok(chatEvents.some((event) => event.text === 'good luck everyone'));
});

test('a player who is not at the table cannot post to it', () => {
  const { table, seat } = makeTable();
  seat('alice');

  assert.throws(() => table.postChat('stranger', 'let me in'), (error) => error.code === 'not_in_room');
});

test('joining and leaving are announced in the room log', () => {
  const { table, seat } = makeTable();
  seat('alice', 'Alice');
  seat('bob', 'Bob');
  table.removePlayer('bob');

  const lines = table.chatHistory().map((message) => message.text);
  assert.ok(lines.includes('Alice joined the table'));
  assert.ok(lines.includes('Bob joined the table'));
  assert.ok(lines.includes('Bob left the table'));

  for (const message of table.chatHistory()) {
    if (message.system) assert.equal(message.userId, null, 'system lines have no author');
  }
});

test('a player who joins later sees the existing history', () => {
  const { table, seat } = makeTable();
  seat('alice', 'Alice');
  table.postChat('alice', 'anyone here?');
  table.postChat('alice', 'hello?');

  seat('carol', 'Carol');

  const visible = table.chatHistory().map((message) => message.text);
  assert.ok(visible.includes('anyone here?'), 'the backlog is still there for the new player');
  assert.ok(visible.includes('hello?'));
  assert.ok(visible.includes('Carol joined the table'));
});

test('destroying the room deletes its chat history', () => {
  const { table, seat } = makeTable();
  seat('alice', 'Alice');
  table.postChat('alice', 'secret table talk');
  assert.ok(table.chatHistory().length > 0);

  table.destroy();

  assert.equal(table.chatHistory().length, 0, 'nothing survives the room');
});

test('two tables never see each other\'s messages', () => {
  const first = makeTable();
  const second = makeTable();

  first.seat('alice', 'Alice');
  second.seat('bob', 'Bob');

  first.table.postChat('alice', 'table one only');

  const secondLines = second.table.chatHistory().map((message) => message.text);
  assert.ok(!secondLines.includes('table one only'), 'chat is scoped to one room');
  assert.ok(first.table.chatHistory().some((message) => message.text === 'table one only'));
});

test('chat keeps working while a hand is in progress', () => {
  const { table, seat, advance } = makeTable();
  seat('alice', 'Alice');
  seat('bob', 'Bob');
  advance(baseConfig.nextHandDelayMs);

  assert.ok(table.hand, 'a hand is live');
  const message = table.postChat('alice', 'nice cards');
  assert.equal(message.text, 'nice cards');
});

test('chat history is never part of the table snapshot', () => {
  const { table, seat } = makeTable();
  seat('alice', 'Alice');
  table.postChat('alice', 'do not leak me');

  const snapshot = JSON.stringify(table.serializeFor('alice'));
  assert.ok(!snapshot.includes('do not leak me'), 'chat travels on its own events, not in state');
});
