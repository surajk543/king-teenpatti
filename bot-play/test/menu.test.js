/**
 * Following the server's menu (src/menu.js): staffing only what the server
 * offers, and choosing only tables whose stack band admits the bot.
 *
 * The rules that matter:
 *
 *   * the configured list is the owner's choice — the menu can take entries
 *     out of it and give them back, never add one;
 *   * a band admits exactly its limits at either end, and 0 means no limit,
 *     as the server's assertWithinTableBand has it;
 *   * wherever a bot CHOOSES a table (a hop, the too-rich fallback, the move
 *     after a refusal) the band is respected on top of the boots-to-sit bar,
 *     so the fleet never walks into over_entry_cap or below_table_minimum.
 *
 * All of it against pure functions and fakes — no live server.
 */
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { Bot } from '../src/bot.js';
import { config } from '../src/config.js';
import { Fleet } from '../src/fleet.js';
import {
  TableMenu, bandAdmits, fallbackTable, keyOf, menuKey, readMenu, sameTable, splitByMenu, tablesToChoose,
} from '../src/menu.js';

const LAKH = 100_000;
const CRORE = 100 * LAKH;

/**
 * GET /api/tables' `tables[]` as production serves it on 27 Sep 2026
 * (go-server v1.6.0): the Teen Patti entries with their bands, and a poker
 * entry whose floor is its buy-in. Extra keys ride along as they do on the
 * wire, and a private template is mixed in to prove it is skipped.
 */
const entry = (category, bootAmount, minChips = 0, maxChips = 0, extra = {}) => ({
  category, bootAmount, minChips, maxChips,
  key: menuKey(category, bootAmount), engine: 'teen_patti', isPrivate: false, maxPot: 0, sortOrder: 0,
  ...extra,
});
const PRODUCTION = [
  entry('seen', 200),
  entry('blind', 200, 0, 20 * LAKH),
  entry('blind', 5000, 0, 20 * CRORE),
  entry('blind', 50000, 0, 200 * CRORE),
  entry('blind', 2_000_000, 50 * CRORE),
  entry('variation', 50000, 0, 200 * CRORE),
  entry('variation', 2_000_000, 50 * CRORE),
  entry('seen', 50000),
  entry('texas_holdem', 50000, 5 * LAKH, 0, { engine: 'poker', game: 'poker' }),
  entry('seen', 200, 0, 0, { key: 'private:seen', isPrivate: true }),
];

/** The fleet's default list (config.categories), restated so the tests do not depend on argv. */
const SEEN_200 = { category: 'seen', boot: 200 };
const BLIND_200 = { category: 'blind', boot: 200 };
const BLIND_5000 = { category: 'blind', boot: 5000 };
const VARIATION_50000 = { category: 'variation', boot: 50000, pool: 45, online: [12, 18] };
const CONFIGURED = [SEEN_200, BLIND_200, BLIND_5000, VARIATION_50000];

const productionMenu = (entries = CONFIGURED, log = () => {}) => {
  const menu = new TableMenu({ entries, log });
  assert.equal(menu.apply(PRODUCTION, { version: 'v1', source: 'test' }), true);
  return menu;
};

describe('reading the menu', () => {
  it('keys every public table by category:boot and keeps its band', () => {
    const menu = readMenu(PRODUCTION);
    assert.equal(menu.size, 9, 'nine public tables; the private template is not one');
    assert.deepEqual(menu.get('blind:200'), { minChips: 0, maxChips: 20 * LAKH });
    assert.deepEqual(menu.get('blind:2000000'), { minChips: 50 * CRORE, maxChips: 0 });
    assert.deepEqual(menu.get('seen:200'), { minChips: 0, maxChips: 0 });
    assert.equal(menu.get('seen:200'), menu.get(keyOf(SEEN_200)));
  });

  it('reads a missing or garbled band as no limit, and skips an entry it cannot key', () => {
    const menu = readMenu([
      { category: 'seen', bootAmount: 200 },
      { category: 'blind', bootAmount: '5000', minChips: -3, maxChips: 'lots' },
      { category: 'blind' },
      { bootAmount: 200 },
      null,
    ]);
    assert.deepEqual([...menu.keys()], ['seen:200', 'blind:5000']);
    assert.deepEqual(menu.get('seen:200'), { minChips: 0, maxChips: 0 });
    assert.deepEqual(menu.get('blind:5000'), { minChips: 0, maxChips: 0 });
  });

  it('knows no menu from an answer that is not one, but an empty list is any pair', () => {
    assert.equal(readMenu(undefined), null);
    assert.equal(readMenu({ tables: [] }), null);
    assert.equal(readMenu([{ nonsense: true }]), null, 'a list with nothing readable is not a menu that offers nothing');
    assert.equal(readMenu([]).size, 0);
    assert.deepEqual(splitByMenu(CONFIGURED, readMenu([])), { offered: CONFIGURED, dropped: [] });
  });
});

describe('staffing only what the server offers', () => {
  it('drops a configured entry the menu does not list, and never adds one', () => {
    const menu = readMenu(PRODUCTION.filter((t) => !(t.category === 'blind' && t.bootAmount === 5000)));
    const { offered, dropped } = splitByMenu(CONFIGURED, menu);
    assert.deepEqual(offered, [SEEN_200, BLIND_200, VARIATION_50000], 'in the configured order');
    assert.deepEqual(dropped, [BLIND_5000]);
    assert.ok(!offered.some((e) => e.boot === 2_000_000 || e.category === 'texas_holdem'),
      'a table the server offers but the owner did not configure is never staffed');
  });

  it('offers every configured entry while no menu is known', () => {
    assert.deepEqual(splitByMenu(CONFIGURED, null), { offered: CONFIGURED, dropped: [] });
    const menu = new TableMenu({ entries: CONFIGURED });
    assert.equal(menu.known, false);
    assert.deepEqual(menu.offered(), CONFIGURED);
    assert.ok(CONFIGURED.every((e) => menu.admits(e, 1)), 'no bands known, so none enforced');
  });

  it('logs each dropped entry once, and again only when it comes back', () => {
    const lines = [];
    const menu = new TableMenu({ entries: CONFIGURED, log: (m) => lines.push(m) });
    const without = PRODUCTION.filter((t) => t.category !== 'variation');
    menu.apply(without, { version: 'v1', source: 'GET /api/tables' });
    assert.deepEqual(lines, ['table menu (GET /api/tables): not staffing variation/50000 — the server does not offer it']);
    assert.equal(menu.isOffered(VARIATION_50000), false);

    menu.apply(without, { version: 'v2', source: 'session:ready' });
    assert.equal(lines.length, 1, 'still dropped: not said twice');

    menu.apply(PRODUCTION, { version: 'v3', source: 'session:ready' });
    assert.equal(lines.length, 2);
    assert.match(lines[1], /variation\/50000 is offered again — staffing it/);
    assert.equal(menu.isOffered(VARIATION_50000), true);
  });

  it('refreshes from a session only when its catalogue version differs', () => {
    const menu = productionMenu();
    const without = PRODUCTION.filter((t) => t.bootAmount !== 5000);
    menu.noticeSession({ tableConfigVersion: 'v1', tables: without });
    assert.equal(menu.isOffered(BLIND_5000), true, 'same version: the menu held stands');
    menu.noticeSession({ tables: without });
    assert.equal(menu.isOffered(BLIND_5000), true, 'no version, and a menu is held: ignored');
    menu.noticeSession({ tableConfigVersion: 'v2', tables: without });
    assert.equal(menu.isOffered(BLIND_5000), false, 'a new version replaces the menu');
    assert.equal(menu.version, 'v2');
    menu.noticeSession(undefined);
    assert.equal(menu.version, 'v2');
  });

  it('takes the first session\'s menu when none could be read, versioned or not', () => {
    const menu = new TableMenu({ entries: CONFIGURED });
    menu.noticeSession({ tables: PRODUCTION.filter((t) => t.bootAmount !== 5000) });
    assert.equal(menu.known, true);
    assert.equal(menu.isOffered(BLIND_5000), false);
    assert.deepEqual(menu.bandFor(BLIND_200), { minChips: 0, maxChips: 20 * LAKH });
    menu.noticeSession({ tables: PRODUCTION });
    assert.equal(menu.isOffered(BLIND_5000), false, 'the first session\'s menu is kept until a version says otherwise');
  });

  it('loads GET /api/tables, and on failure keeps today\'s behaviour until a session supplies it', async () => {
    const answer = (status, body) => async (url) => {
      assert.equal(url, 'http://server/api/tables');
      return { ok: status === 200, status, json: async () => body };
    };
    const good = new TableMenu({ entries: CONFIGURED });
    assert.equal(await good.load('http://server', answer(200, { version: 'abc', tables: PRODUCTION })), true);
    assert.equal(good.version, 'abc');
    assert.deepEqual(good.bandFor(BLIND_5000), { minChips: 0, maxChips: 20 * CRORE });

    for (const fetchImpl of [
      answer(404, { error: 'not_found' }),
      answer(200, { version: 'abc' }),
      async () => { throw new Error('ECONNREFUSED'); },
    ]) {
      const lines = [];
      const menu = new TableMenu({ entries: CONFIGURED, log: (m) => lines.push(m) });
      assert.equal(await menu.load('http://server', fetchImpl), false);
      assert.equal(menu.known, false);
      assert.deepEqual(menu.offered(), CONFIGURED);
      assert.equal(lines.length, 1);
      assert.match(lines[0], /could not read http:\/\/server\/api\/tables .* taking it from the first session:ready/);
    }
  });

  it('retires an entry the server refused as not offered, once, until the next menu', () => {
    const lines = [];
    const menu = productionMenu(CONFIGURED, (m) => lines.push(m));
    menu.retire(BLIND_5000, 'The lobby offers: seen 200');
    menu.retire({ ...BLIND_5000 });
    assert.equal(lines.length, 1, 'sixty bots refused together log it once');
    assert.equal(menu.isOffered(BLIND_5000), false);
    assert.ok(!menu.offered().some((e) => sameTable(e, BLIND_5000)));
    assert.equal(menu.admits(BLIND_5000, 10 * LAKH), false);
    menu.apply(PRODUCTION, { version: 'v2' });
    assert.equal(menu.isOffered(BLIND_5000), true, 'a fresh menu says afresh what is offered');
  });
});

describe('a table\'s stack band', () => {
  it('admits exactly its limits, and 0 is no limit', () => {
    const band = { minChips: 50 * CRORE, maxChips: 200 * CRORE };
    assert.equal(bandAdmits(band, 50 * CRORE - 1), false);
    assert.equal(bandAdmits(band, 50 * CRORE), true);
    assert.equal(bandAdmits(band, 200 * CRORE), true);
    assert.equal(bandAdmits(band, 200 * CRORE + 1), false);
    assert.equal(bandAdmits({ minChips: 0, maxChips: 0 }, Number.MAX_SAFE_INTEGER), true);
    assert.equal(bandAdmits({ minChips: 0, maxChips: 20 * LAKH }, 0), true);
    assert.equal(bandAdmits(null, 1), true);
  });
});

describe('choosing a table', () => {
  const menu = productionMenu();
  const bandFor = (e) => menu.bandFor(e);
  const choose = (current, chips, bootsToSit = 8) => tablesToChoose({
    entries: CONFIGURED, current, chips, bootsToSit, bandFor,
  });

  it('gives a fresh bot (10 Lakh welcome) every other configured table', () => {
    assert.deepEqual(choose(SEEN_200, 10 * LAKH), [BLIND_200, BLIND_5000, VARIATION_50000],
      '8 × 50,000 is four Lakh, so the welcome reaches variation');
  });

  it('never offers blind 200 past its 20 Lakh cap — exactly the cap is allowed', () => {
    assert.ok(!choose(SEEN_200, 20 * LAKH + 1).some((e) => sameTable(e, BLIND_200)));
    assert.ok(choose(SEEN_200, 20 * LAKH).some((e) => sameTable(e, BLIND_200)));
  });

  it('keeps the boots-to-sit bar on top of the band', () => {
    assert.deepEqual(choose(SEEN_200, 3 * LAKH), [BLIND_200, BLIND_5000], 'three Lakh is six variation boots');
    assert.deepEqual(choose(SEEN_200, 1000), [], 'a thousand chips covers no other table eight times');
  });

  it('respects a floor: the 20 Lakh tables open only from 50 Crore', () => {
    const TWENTY_LAKH_BLIND = { category: 'blind', boot: 2_000_000 };
    const entries = [...CONFIGURED, TWENTY_LAKH_BLIND];
    const wide = productionMenu(entries);
    const pick = (chips) => tablesToChoose({
      entries, current: SEEN_200, chips, bootsToSit: 8, bandFor: (e) => wide.bandFor(e),
    });
    assert.ok(!pick(50 * CRORE - 1).some((e) => sameTable(e, TWENTY_LAKH_BLIND)), 'below the floor');
    assert.ok(pick(50 * CRORE).some((e) => sameTable(e, TWENTY_LAKH_BLIND)), 'exactly the floor');
    assert.deepEqual(wide.choices(SEEN_200, 49 * CRORE, 8).map(keyOf), ['variation:50000'],
      'nor through the menu, where blind 200 and blind 5000 are shut past 20 Lakh and 20 Crore');
  });

  it('never chooses a table whose band would refuse the stack, at any stack', () => {
    for (let chips = 0; chips <= 300 * CRORE; chips = chips < 1000 ? chips + 137 : Math.ceil(chips * 1.37)) {
      for (const current of CONFIGURED) {
        for (const next of menu.choices(current, chips, 8)) {
          assert.ok(!sameTable(next, current));
          assert.ok(bandAdmits(menu.bandFor(next), chips), `${keyOf(next)} refuses ${chips}`);
          assert.ok(chips >= next.boot * 8);
        }
        const fallback = menu.fallback(current, chips);
        if (fallback) {
          assert.ok(!sameTable(fallback, current));
          assert.ok(bandAdmits(menu.bandFor(fallback), chips), `fallback ${keyOf(fallback)} refuses ${chips}`);
          assert.ok(chips >= fallback.boot);
        }
      }
    }
  });

  it('falls back to the cheapest other table the band admits and the stack covers', () => {
    // A bot too rich for blind 200 with nothing passing boots-to-sit (a high bar).
    const fallback = (current, chips) => fallbackTable({ entries: CONFIGURED, current, chips, bandFor });
    assert.deepEqual(fallback(BLIND_200, 25 * LAKH), SEEN_200);
    assert.deepEqual(fallback(SEEN_200, 25 * LAKH), BLIND_5000, 'blind 200 is the cheapest, and it is shut to 25 Lakh');
    assert.deepEqual(fallback(SEEN_200, 1000), BLIND_200);
    assert.equal(fallback(SEEN_200, 100), null, 'nothing covers a hundred chips');
    assert.equal(
      fallbackTable({ entries: [BLIND_200], current: SEEN_200, chips: 25 * LAKH, bandFor }),
      null,
      'no offered table admits this stack',
    );
  });

  it('chooses only among offered tables', () => {
    const narrow = new TableMenu({ entries: CONFIGURED });
    narrow.apply(PRODUCTION.filter((t) => !(t.category === 'variation')), { version: 'v1' });
    assert.ok(!narrow.choices(SEEN_200, 10 * LAKH, 8).some((e) => sameTable(e, VARIATION_50000)));
    narrow.retire(BLIND_5000);
    assert.deepEqual(narrow.choices(SEEN_200, 10 * LAKH, 8), [BLIND_200]);
    assert.deepEqual(narrow.fallback(BLIND_200, 25 * LAKH), SEEN_200);
  });
});

describe('the fleet', () => {
  /** Just enough of a Bot for Fleet.tick. */
  const fakeBot = (home, online) => ({
    home,
    online,
    seated: online,
    stopped: false,
    leaving: false,
    wrappingUp: false,
    restUntil: 0,
    identity: { name: `${home.category}${home.boot}` },
    cameOnline: 0,
    async comeOnline() { this.cameOnline += 1; this.online = true; },
    wrapUp() { this.wrappingUp = true; },
  });

  it('wants nobody at an entry the menu leaves out', () => {
    const menu = productionMenu(CONFIGURED);
    menu.retire(BLIND_5000);
    const fleet = new Fleet({ bots: [], log: () => {}, menu });
    assert.equal(fleet.wantedOnline(BLIND_5000, 66), 0);
    assert.ok(fleet.wantedOnline(SEEN_200, 66) >= 1);
  });

  it('sends a dropped entry\'s bots home one a tick and brings none back', async () => {
    const small = { category: 'seen', boot: 200, pool: 2, online: [2, 2] };
    const dropped = { category: 'blind', boot: 5000, pool: 3, online: [3, 3] };
    const menu = new TableMenu({ entries: [small, dropped] });
    menu.apply(PRODUCTION.filter((t) => !(t.category === 'blind' && t.bootAmount === 5000)), { version: 'v1' });
    const staffed = [fakeBot(small, true), fakeBot(small, true)];
    const stranded = [fakeBot(dropped, true), fakeBot(dropped, true), fakeBot(dropped, true), fakeBot(dropped, false)];
    const fleet = new Fleet({ bots: [...staffed, ...stranded], log: () => {}, menu });
    try {
      await fleet.tick();
      assert.equal(stranded.filter((b) => b.wrappingUp).length, 1);
      await fleet.tick();
      assert.equal(stranded.filter((b) => b.wrappingUp).length, 2);
      assert.equal(stranded.reduce((n, b) => n + b.cameOnline, 0), 0, 'the resting one stays resting');
      assert.ok(staffed.every((b) => !b.wrappingUp), 'the offered entry is untouched');
      assert.match(fleet.summary(), /wanted 2\)/);
    } finally {
      fleet.stop();
    }
  });

  it('staffs an entry again when a later menu lists it', async () => {
    const back = { category: 'blind', boot: 5000, pool: 1, online: [1, 1] };
    const menu = new TableMenu({ entries: [back] });
    menu.apply(PRODUCTION.filter((t) => t.bootAmount !== 5000), { version: 'v1' });
    const bot = fakeBot(back, false);
    const fleet = new Fleet({ bots: [bot], log: () => {}, menu });
    try {
      await fleet.tick();
      assert.equal(bot.cameOnline, 0);
      menu.noticeSession({ tableConfigVersion: 'v2', tables: PRODUCTION });
      await fleet.tick();
      assert.equal(bot.cameOnline, 1, 'wanted again at once, not on some later tick\'s redraw');
    } finally {
      fleet.stop();
    }
  });

  it('does not start a bot whose entry the first session has just dropped', async () => {
    // GET /api/tables failed, so the opening list was drawn with no menu and
    // both bots of this entry are in it. The first to start brings a
    // session:ready whose menu leaves the entry out; the second stays resting.
    // (One entry, so the fleet's shuffle cannot change which bot is first.)
    const dropped = { category: 'blind', boot: 5000, pool: 2, online: [2, 2] };
    const menu = new TableMenu({ entries: [dropped] });
    const bots = [fakeBot(dropped, false), fakeBot(dropped, false)];
    for (const bot of bots) {
      bot.start = async function start() {
        this.cameOnline += 1;
        this.online = true;
        menu.noticeSession({ tableConfigVersion: 'v1', tables: PRODUCTION.filter((t) => t.bootAmount !== 5000) });
      };
    }
    const stagger = config.startStaggerMs;
    config.startStaggerMs = 0;
    const fleet = new Fleet({ bots, log: () => {}, menu });
    try {
      await fleet.start();
      assert.equal(bots.reduce((n, b) => n + b.cameOnline, 0), 1, 'no login only to get straight back up');
      assert.match(fleet.summary(), /wanted 0\)/, 'the entry wants nobody now');
    } finally {
      fleet.stop();
      config.startStaggerMs = stagger;
    }
  });
});

describe('a bot sitting down', () => {
  /** A socket that answers every quickJoin with the next queued ack, and every leave. */
  const fakeSocket = (...answers) => ({
    connected: true,
    sent: [],
    closed: false,
    emit(event, payload, ack) {
      this.sent.push({ event, payload });
      if (event === 'room:quickJoin') ack?.(answers.shift() ?? { ok: true });
      if (event === 'room:leave') ack?.({ ok: true });
    },
    close() { this.closed = true; this.connected = false; },
  });

  /**
   * The same, as Bot.connect() uses it: connect() registers its handlers with
   * on(), and the test delivers events through them as the server would.
   */
  const wiredSocket = (...answers) => {
    const socket = fakeSocket(...answers);
    socket.handlers = new Map();
    socket.on = function on(event, handler) {
      this.handlers.set(event, handler);
      return this;
    };
    socket.deliver = function deliver(event, payload) {
      this.handlers.get(event)?.(payload);
    };
    return socket;
  };

  /**
   * A bot of `home`, online and headed for `table` — its home, unless it has
   * hopped. With `wired`, the socket is opened by the bot's own connect().
   */
  const botAt = (table, chips, socket, menu = productionMenu(), { home = table, wired = false } = {}) => {
    const lines = [];
    const bot = new Bot({
      index: 7, table: home, log: (m) => lines.push(m), menu, openSocket: () => socket,
    });
    bot.table = table;
    if (wired) bot.connect();
    else bot.socket = socket;
    bot.chips = chips;
    bot.online = true;
    // Chat is a dice roll; nothing here is about chat.
    bot.rng = { ...bot.rng, chance: () => false };
    return { bot, lines };
  };

  const joins = (socket) => socket.sent.filter((s) => s.event === 'room:quickJoin').map((s) => s.payload);

  const without5000 = () => PRODUCTION.filter((t) => t.bootAmount !== 5000);

  it('does not head for a table whose band would refuse its stack', () => {
    const socket = fakeSocket();
    const { bot } = botAt(BLIND_200, 25 * LAKH, socket);
    try {
      bot.join();
      const [asked] = joins(socket);
      assert.ok(asked, 'it still sits down');
      assert.notDeepEqual(asked, { bootAmount: 200, category: 'blind' }, 'but not at blind 200, shut past 20 Lakh');
      assert.ok(bandAdmits(bot.menu.bandFor(bot.table), 25 * LAKH));
    } finally {
      bot.stop();
    }
  });

  for (const code of ['over_entry_cap', 'below_table_minimum']) {
    it(`moves to a table its stack belongs at when refused ${code}`, () => {
      // The bot's idea of its stack says blind 200 is fine; the server knows better.
      const socket = fakeSocket({ ok: false, code, message: 'refused' });
      const { bot } = botAt(BLIND_200, 10 * LAKH, socket);
      try {
        bot.join();
        assert.deepEqual(joins(socket), [{ bootAmount: 200, category: 'blind' }]);
        assert.ok(!sameTable(bot.table, BLIND_200), 'headed somewhere else for the retry');
        assert.ok(bot.menu.admits(bot.table, 10 * LAKH));
        assert.equal(bot.online, true, 'a move, not the end of the sitting');
      } finally {
        bot.stop();
      }
    });
  }

  it('ends its sitting when its own table is refused as not offered, logged once fleet-wide', () => {
    const lines = [];
    const menu = productionMenu(CONFIGURED, (m) => lines.push(m));
    const refusal = { ok: false, code: 'table_not_offered', message: 'The lobby offers: seen 200, blind 200' };
    const firstSocket = fakeSocket(refusal);
    const secondSocket = fakeSocket();
    const first = botAt(BLIND_5000, 10 * LAKH, firstSocket, menu);
    const second = botAt(BLIND_5000, 10 * LAKH, secondSocket, menu);
    try {
      first.bot.join();
      assert.equal(menu.isOffered(BLIND_5000), false);
      assert.deepEqual(joins(firstSocket), [{ bootAmount: 5000, category: 'blind' }], 'the refused ask, and no other');
      assert.equal(first.bot.online, false, 'home, not a seat at another table');
      assert.equal(firstSocket.closed, true);
      assert.match(first.lines.join('\n'), /not on the server's menu/);

      second.bot.join();
      assert.deepEqual(joins(secondSocket), []);
      assert.equal(second.bot.online, false, 'the second never asks: its home is off the menu');
      assert.equal(lines.filter((m) => m.includes('refused as not offered')).length, 1);
    } finally {
      first.bot.stop();
      second.bot.stop();
    }
  });

  it('moves on when a table it was hopping to is refused as not offered', () => {
    const menu = productionMenu();
    const refusal = { ok: false, code: 'table_not_offered', message: 'The lobby offers: seen 200' };
    const socket = fakeSocket(refusal);
    const { bot } = botAt(BLIND_5000, 10 * LAKH, socket, menu, { home: SEEN_200 });
    try {
      bot.join();
      assert.deepEqual(joins(socket), [{ bootAmount: 5000, category: 'blind' }]);
      assert.equal(menu.isOffered(BLIND_5000), false, 'out of every bot\'s choices');
      assert.equal(bot.online, true, 'its home is still staffed: a move, not the end of the sitting');
      assert.ok(!sameTable(bot.table, BLIND_5000));
      assert.ok(menu.isOffered(bot.table));
    } finally {
      bot.stop();
    }
  });

  it('ends its sitting when no offered table will take its stack', () => {
    const socket = fakeSocket();
    const menu = new TableMenu({ entries: [BLIND_200] });
    menu.apply(PRODUCTION, { version: 'v1' });
    const { bot, lines } = botAt(BLIND_200, 25 * LAKH, socket, menu);
    try {
      bot.join();
      assert.deepEqual(joins(socket), [], 'no refusal asked for');
      assert.equal(bot.online, false);
      assert.equal(socket.closed, true);
      assert.match(lines.join('\n'), /no offered table admits a stack of 2500000/);
    } finally {
      bot.stop();
    }
  });

  it('goes home, asking for no seat, when its session:ready drops its own table', (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const socket = wiredSocket();
    const menu = productionMenu();
    const { bot, lines } = botAt(BLIND_5000, 10 * LAKH, socket, menu, { wired: true });
    try {
      // What a (re)connect looks like from the server: the socket connects,
      // session:ready names a changed catalogue, and the bot sits down on its
      // own 2.5 s later when no restored seat has arrived.
      socket.deliver('connect');
      socket.deliver('session:ready', {
        user: { id: 'u7' },
        config: { tableConfigVersion: 'v9', tables: without5000() },
      });
      assert.equal(menu.version, 'v9', 'the handler connect() wired read the session\'s config');
      assert.equal(menu.isOffered(BLIND_5000), false);
      t.mock.timers.tick(2500);
      assert.deepEqual(joins(socket), [], 'no quickJoin, here or at any other table');
      assert.equal(bot.online, false);
      assert.equal(socket.closed, true);
      assert.match(lines.join('\n'), /got up \(its table is not on the server's menu\)/);
    } finally {
      bot.stop();
    }
  });

  it('heads elsewhere when its session:ready drops the table it hopped to', (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const socket = wiredSocket();
    const menu = productionMenu();
    const { bot } = botAt(BLIND_5000, 10 * LAKH, socket, menu, { home: SEEN_200, wired: true });
    try {
      socket.deliver('connect');
      socket.deliver('session:ready', { config: { tableConfigVersion: 'v9', tables: without5000() } });
      t.mock.timers.tick(2500);
      const asked = joins(socket);
      assert.equal(asked.length, 1);
      assert.notEqual(asked[0].bootAmount, 5000);
      assert.equal(bot.online, true);
    } finally {
      bot.stop();
    }
  });

  it('keeps the menu it holds when a session names the same catalogue', () => {
    const socket = wiredSocket();
    const menu = productionMenu();
    const { bot } = botAt(BLIND_5000, 10 * LAKH, socket, menu, { wired: true });
    try {
      socket.deliver('session:ready', { config: { tableConfigVersion: 'v1', tables: without5000() } });
      assert.equal(menu.isOffered(BLIND_5000), true);
      bot.join();
      assert.deepEqual(joins(socket), [{ bootAmount: 5000, category: 'blind' }]);
    } finally {
      bot.stop();
    }
  });
});

describe('a bot asked to get up', () => {
  /** Seated at blind 5000 under --steady, its sitting long past its planned length. */
  const seatedSteady = () => {
    const socket = {
      connected: true,
      sent: [],
      emit(event, payload, ack) {
        this.sent.push({ event, payload });
        if (event === 'room:leave') ack?.({ ok: true });
      },
      close() { this.connected = false; },
    };
    const bot = new Bot({ index: 7, table: BLIND_5000, log: () => {}, menu: productionMenu() });
    bot.socket = socket;
    bot.online = true;
    bot.seated = true;
    bot.plannedHands = 1;
    bot.handsThisSitting = 40;
    bot.view = { you: { contributed: 0 } };
    bot.rng = { ...bot.rng, chance: () => false };
    return { bot, socket };
  };
  const handEnds = (bot) => bot.onHandEnded({ winnerId: 'someone-else', pot: 0, reveals: [] });
  const settle = () => new Promise((resolve) => setImmediate(resolve));

  it('stays seated under --steady until the fleet asks, and then gets up after its hand', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const steady = config.steady;
    config.steady = true;
    const { bot, socket } = seatedSteady();
    try {
      handEnds(bot);
      t.mock.timers.tick(5000);
      await settle();
      assert.equal(bot.online, true, 'nobody gets up of their own accord under --steady');

      // An entry the server stopped offering: the fleet asks (Fleet.tick).
      bot.wrapUp();
      assert.equal(bot.online, true, 'seated: it finishes the hand first');
      handEnds(bot);
      t.mock.timers.tick(1500);
      await settle();
      assert.equal(bot.online, false);
      assert.ok(socket.sent.some((s) => s.event === 'room:leave'));
    } finally {
      bot.stop();
      config.steady = steady;
    }
  });
});
