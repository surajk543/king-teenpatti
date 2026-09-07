/**
 * Browser client for King Teen Patti.
 *
 * It speaks exactly the same Socket.IO protocol as the Unity client, so it
 * doubles as a reference implementation and as a way to test the server (and
 * to fill a table with real players) without a Unity build.
 */
(() => {
  const $ = (id) => document.getElementById(id);
  const SUITS = { s: '♠', h: '♥', d: '♦', c: '♣' };
  const RED = new Set(['h', 'd']);

  const state = {
    token: localStorage.getItem('tp_token'),
    user: null,
    socket: null,
    room: null,
    options: null,
    deadline: 0,
    timerHandle: null,
    /** Which rung of the bet ladder the +/- stepper is on. 0 = the plain chaal. */
    betIndex: 0,
    /** Lobby selection: "seen" shows every stack, "blind" hides other players'. */
    categories: ['seen', 'blind'],
    stakes: [200, 5000],
    /** Room chat, mirrored from the server for as long as we are in the room. */
    chat: [],
    chatOpen: false,
    unread: 0,
    /** Pictures bundled with the game, for the profile picker. */
    profiles: [],
    showdownTimer: null,
    rewardToast: null,
    /** Interval driving the "starting game in N" countdown. */
    startTimer: null,
  };

  const show = (screenId) => {
    for (const id of ['login', 'lobby', 'table']) $(id).hidden = id !== screenId;
    // The rotate hint (and the landscape layout) only apply at the table.
    document.body.classList.toggle('at-table', screenId === 'table');
    document.body.classList.toggle('at-lobby', screenId === 'lobby');
    // The corner rewards are lobby furniture; they would clash with the chat
    // button and the bet controls at a table.
    showCornerRewards(screenId === 'lobby');
    if (screenId === 'table') lockLandscape();
  };

  /**
   * Play-by-play. The on-screen log was removed — the table itself shows what
   * is happening — so this keeps the last few lines for the console only.
   * Anything a player genuinely needs to see goes to the status line or chat.
   */
  const history = [];
  const log = (text) => {
    history.push(text);
    if (history.length > 60) history.shift();
  };

  // ------------------------------------------------------------------ theme

  /**
   * Light/dark switching (requirement 23).
   *
   * The whole palette lives in Material 3 tokens, so a theme is one attribute
   * on <html>. The choice is remembered; with none stored the operating
   * system's preference is followed.
   */
  const THEME_KEY = 'tp_theme';

  function preferredTheme() {
    const stored = localStorage.getItem(THEME_KEY);
    if (stored === 'light' || stored === 'dark') return stored;
    // Day mode is the default; the toggle remembers anything else.
    return 'light';
  }

  function applyTheme(theme) {
    const light = theme === 'light';
    document.documentElement.setAttribute('data-theme', light ? 'light' : 'dark');
    document.documentElement.style.colorScheme = light ? 'light' : 'dark';

    // The toggle shows the theme it will switch *to*.
    for (const button of document.querySelectorAll('.theme-toggle')) {
      button.textContent = light ? '🌙' : '☀️';
      button.setAttribute('aria-label', light ? 'Switch to dark mode' : 'Switch to light mode');
    }

    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', light ? '#f5fbf5' : '#0d1411');

    localStorage.setItem(THEME_KEY, light ? 'light' : 'dark');
  }

  applyTheme(preferredTheme());

  for (const button of document.querySelectorAll('.theme-toggle')) {
    button.onclick = () => {
      const current = document.documentElement.getAttribute('data-theme');
      applyTheme(current === 'light' ? 'dark' : 'light');
    };
  }

  /**
   * Asks the phone to stay in landscape while at a table. The Screen
   * Orientation API only works from a user gesture in a fullscreen context, so
   * the CSS "turn your phone" hint is the fallback that always works.
   */
  async function lockLandscape() {
    try {
      await screen.orientation?.lock?.('landscape');
    } catch {
      // Not permitted here; the rotate hint covers it.
    }
  }

  // ------------------------------------------------------------------ device

  /** A stable per-browser id, which is what the guest account is keyed on. */
  const deviceId = (() => {
    let id = localStorage.getItem('tp_device');
    if (!id) {
      id = `web-${crypto.randomUUID()}`;
      localStorage.setItem('tp_device', id);
    }
    return id;
  })();

  // -------------------------------------------------------------------- auth

  async function login(body) {
    const response = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message || data.error || 'Login failed');
    return data;
  }

  async function signIn(body) {
    $('loginError').hidden = true;
    try {
      const result = await login(body);
      state.token = result.token;
      state.user = result.user;
      localStorage.setItem('tp_token', result.token);
      if (result.isNew) log(`Welcome! ${result.welcomeChips.toLocaleString()} chips added.`, true);
      connect();
    } catch (error) {
      $('loginError').textContent = error.message;
      $('loginError').hidden = false;
    }
  }

  $('guestBtn').onclick = () =>
    signIn({ provider: 'guest', deviceId, displayName: $('nameInput').value.trim() || undefined });

  // Google and Facebook use the same endpoint; a production build swaps these
  // for the real SDK flows and sends the resulting idToken / accessToken.
  $('googleBtn').onclick = () =>
    signIn({
      provider: 'google',
      providerUserId: `web-google-${deviceId}`,
      displayName: $('nameInput').value.trim() || 'Google Player',
    });

  $('facebookBtn').onclick = () =>
    signIn({
      provider: 'facebook',
      providerUserId: `web-fb-${deviceId}`,
      displayName: $('nameInput').value.trim() || 'Facebook Player',
    });

  // ------------------------------------------------------------------ socket

  function connect() {
    state.socket = io({ auth: { token: state.token }, transports: ['websocket', 'polling'] });
    const socket = state.socket;

    socket.on('connect_error', (error) => {
      // A stale token means the account is gone or the secret rotated.
      if (/invalid_session|unknown_user|unauthorized/.test(error.message)) {
        localStorage.removeItem('tp_token');
        state.token = null;
        show('login');
        $('loginError').textContent = 'Session expired — please sign in again.';
        $('loginError').hidden = false;
      }
    });

    socket.on('session:ready', ({ user, config }) => {
      state.user = user;
      $('lobbyName').textContent = user.displayName;
      $('lobbyProvider').textContent = user.provider;
      $('lobbyChips').textContent = user.chips.toLocaleString();
      // The lobby renders whatever stakes the server offers.
      if (config && Array.isArray(config.stakes) && config.stakes.length) {
        state.stakes = config.stakes;
      }
      if (config && Array.isArray(config.categories) && config.categories.length) {
        state.categories = config.categories;
      }
      if (config?.privateBoot) {
        $('privateHint').textContent =
          `Private table: fixed boot of ${config.privateBoot.toLocaleString()}`
          + `, maximum win ${(config.privateMaxPot ?? 0).toLocaleString()}`
          + ', one double per turn.';
      }
      renderTableCards();
      renderProfile(user);
      loadProfilePictures();
      show('lobby');
    });

    socket.on('session:replaced', () => {
      alert('You signed in from another device.');
      show('login');
    });

    socket.on('room:joined', (room) => {
      // The server sends this room's backlog right after the join.
      state.chat = [];
      state.unread = 0;
      setChatOpen(false);
      render(room);
      show('table');
      log(`Joined table ${room.code}.`, true);
    });

    socket.on('room:state', render);

    // Requirement 24: two half-empty rooms were merged and this player was
    // moved. The server sends the new room right after, so this is only a note.
    socket.on('room:moved', ({ message }) => {
      state.chat = [];
      state.unread = 0;
      log(message ?? 'Moved to another table.', true);
    });

    socket.on('room:left', () => {
      state.room = null;
      refreshProfile();
      // Leaving the room means leaving its chat; nothing is carried forward.
      state.chat = [];
      state.unread = 0;
      setChatOpen(false);
      show('lobby');
    });

    socket.on('room:closed', () => {
      state.room = null;
      refreshProfile();
      show('lobby');
      $('lobbyError').textContent = 'That table closed.';
      $('lobbyError').hidden = false;
    });

    socket.on('game:handStarted', ({ handNo, pot }) => {
      $('seeBtn').hidden = true;
      hideShowdown();
      log(`— Hand #${handNo} dealt. Boot collected, pot ${pot}. —`, true);
    });

    socket.on('player:cards', ({ cards }) => {
      $('seeBtn').hidden = true;
      renderCards(cards, true);
    });

    socket.on('game:turn', ({ userId, deadline }) => {
      const name = seatName(userId);
      $('status').textContent = userId === state.user.id ? 'Your turn' : `${name} to act`;
      startTimer(deadline);
    });

    socket.on('game:yourTurn', ({ options, deadline }) => {
      state.options = options;
      state.deadline = deadline;
      // Each turn starts the stepper back at the plain chaal — the ladder is
      // recalculated from the new stake, so a previous index would be wrong.
      state.betIndex = 0;
      renderActions();
    });

    socket.on('game:action', ({ userId, action, amount, reason }) => {
      const name = seatName(userId);
      const suffix = reason === 'timeout' ? ' (timed out)' : '';
      const money = amount ? ` ${amount}` : '';
      log(`${name}: ${action}${money}${suffix}`);
      if (userId === state.user.id && (action === 'chaal' || action === 'raise' || action === 'pack' || action === 'show')) {
        state.options = null;
        renderActions();
        stopTimer();
      }
    });

    socket.on('game:showdown', ({ reveals }) => {
      for (const reveal of reveals) {
        log(`${seatName(reveal.userId)} shows ${reveal.cards.join(' ')} — ${reveal.handName}`, true);
      }
      // Requirement 14: every remaining hand is shown to everyone in the room.
      renderShowdown(reveals, null);
    });

    socket.on('game:handEnded', ({ winnerName, winnerId, pot, reason, reveals }) => {
      stopTimer();
      state.options = null;
      renderActions();

      const who = winnerId === state.user?.id ? 'You win' : `${winnerName || 'Nobody'} wins`;
      $('status').textContent = `${who} ${pot.toLocaleString()}`;
      log(`${who} the pot of ${pot.toLocaleString()} (${reason.replace(/_/g, ' ')}).`, true);

      // Requirement 14: the revealed hands stay up with the result written
      // across the middle of the table until the next deal.
      renderShowdown(reveals ?? [], { who, pot });
      clearTimeout(state.showdownTimer);
      state.showdownTimer = setTimeout(hideShowdown, 5000);
    });

    socket.on('game:error', ({ message }) => {
      $('status').textContent = message;
      log(`⚠ ${message}`);
    });

    // --- room chat -------------------------------------------------------
    // History lives on the server only for as long as the room does, so the
    // client simply renders what it is sent and keeps nothing of its own.
    socket.on('chat:history', ({ messages }) => {
      state.chat = messages ?? [];
      renderChat();
    });

    socket.on('chat:message', (message) => {
      state.chat.push(message);
      if (state.chat.length > 100) state.chat.shift();
      renderChat();
      if (!state.chatOpen && !message.system) bumpChatBadge();
    });
  }

  // -------------------------------------------------------------------- chat

  function renderChat() {
    const box = $('chatMessages');
    box.innerHTML = '';

    if (state.chat.length === 0) {
      box.innerHTML = '<div class="empty">No messages yet. Say hello.</div>';
      return;
    }

    for (const message of state.chat) {
      const div = document.createElement('div');
      if (message.system) {
        div.className = 'msg system';
        div.textContent = message.text;
      } else {
        div.className = `msg${message.userId === state.user?.id ? ' mine' : ''}`;
        const author = document.createElement('span');
        author.className = 'author';
        author.textContent = message.userId === state.user?.id ? 'You:' : `${message.displayName}:`;
        div.append(author, document.createTextNode(message.text));
      }
      box.append(div);
    }

    // Keep the newest message in view.
    box.scrollTop = box.scrollHeight;
  }

  function bumpChatBadge() {
    state.unread += 1;
    const badge = $('chatBadge');
    badge.textContent = state.unread > 9 ? '9+' : String(state.unread);
    badge.hidden = false;
  }

  function setChatOpen(open) {
    state.chatOpen = open;
    $('chatPanel').hidden = !open;
    $('chatToggle').hidden = open;
    if (!open) return;
    state.unread = 0;
    $('chatBadge').hidden = true;
    renderChat();
    $('chatInput').focus();
  }

  $('chatToggle').onclick = () => setChatOpen(true);
  $('chatClose').onclick = () => setChatOpen(false);

  $('chatForm').onsubmit = (event) => {
    event.preventDefault();
    const input = $('chatInput');
    const text = input.value.trim();
    if (!text) return;

    state.socket.emit('chat:message', { text }, (ack) => {
      const error = $('chatError');
      if (ack && ack.ok === false) {
        error.textContent = ack.message;
        error.hidden = false;
      } else {
        error.hidden = true;
      }
    });

    input.value = '';
  };

  // ------------------------------------------------------------------- lobby

  const emit = (event, payload = {}) =>
    new Promise((resolve) => {
      state.socket.emit(event, payload, (ack) => {
        const failed = ack && ack.ok === false;
        $('lobbyError').textContent = failed ? ack.message : '';
        $('lobbyError').hidden = !failed;
        resolve(ack);
      });
    });

  // A private table's boot is fixed by the server, so none is sent.
  $('createBtn').onclick = () => emit('room:create', { category: 'blind', isPrivate: true });
  $('joinCodeBtn').onclick = () => emit('room:joinCode', { code: $('codeInput').value.trim().toUpperCase() });
  /**
   * Requirement 25: leaving is confirmed first. The wording changes when a
   * hand is live, because that is when leaving actually costs the player
   * something — their stake stays in the pot.
   */
  function askToLeave() {
    const midHand = state.room?.state === 'betting' && state.room?.you?.status === 'active';
    $('leaveBody').textContent = midHand
      ? 'You are in a hand. Leaving packs your cards and your stake stays in the pot.'
      : 'You can join another table straight away.';
    $('leaveDialog').hidden = false;
    $('leaveCancel').focus();
  }

  const closeLeaveDialog = () => { $('leaveDialog').hidden = true; };

  $('leaveBtn').onclick = askToLeave;
  $('leaveCancel').onclick = closeLeaveDialog;
  $('leaveConfirm').onclick = () => {
    closeLeaveDialog();
    emit('room:leave');
  };

  // Clicking the scrim, or pressing Escape, is the same as choosing to stay.
  $('leaveDialog').onclick = (event) => {
    if (event.target === $('leaveDialog')) closeLeaveDialog();
  };
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !$('leaveDialog').hidden) closeLeaveDialog();
  });

  /**
   * Builds one card per table on offer, from the categories and stakes the
   * server advertises.
   *
   * The whole card is the button — a far better touch target on a phone than a
   * link tucked inside one — and the rail scrolls sideways, so the lobby never
   * needs a vertical scroll.
   */
  function renderTableCards() {
    const box = $('tableCards');
    if (!box) return;
    box.innerHTML = '';

    const describe = (category) =>
      category === 'blind'
        ? 'Only your own chips are visible'
        : "Everyone's chips are visible";

    for (const category of state.categories) {
      for (const stake of state.stakes) {
        const card = document.createElement('button');
        card.type = 'button';
        card.className = `tablecard ${category}`;

        const cat = document.createElement('span');
        cat.className = 'cat';
        cat.textContent = category;

        const amount = document.createElement('span');
        amount.className = 'amount';
        amount.textContent = stake.toLocaleString();

        const desc = document.createElement('span');
        desc.className = 'desc';
        desc.textContent = describe(category);

        const hint = document.createElement('span');
        // Not "seats": that class is the ring of players on the table screen.
        hint.className = 'cta';
        hint.textContent = 'Tap to sit down';

        card.append(cat, amount, desc, hint);
        card.onclick = () => emit('room:quickJoin', { bootAmount: stake, category });
        box.append(card);
      }
    }
  }

  // ------------------------------------------------------------------ render

  const seatName = (userId) => {
    const seat = state.room?.seats.find((entry) => entry.userId === userId);
    if (!seat) return 'Player';
    return seat.userId === state.user?.id ? 'You' : seat.displayName;
  };

  function render(room) {
    state.room = room;
    $('tableCode').textContent = room.code;
    $('tableCategory').textContent = room.category === 'blind' ? 'blind' : 'seen';
    $('handNo').textContent = room.handNo;
    $('pot').textContent = room.pot.toLocaleString();
    $('stake').textContent = room.stake.toLocaleString()
      + (room.maxPot ? ` · max win ${room.maxPot.toLocaleString()}` : '');
    if (room.you) $('myChips').textContent = room.you.chips.toLocaleString();

    const seats = $('seats');
    // Keep the centre (the pot) and replace only the seats around it.
    for (const old of seats.querySelectorAll('.seat')) old.remove();

    for (const seat of room.seats) {
      const div = document.createElement('div');
      // The place class fixes this seat's spot on the ring.
      const classes = ['seat', `seat--${seat.seatIndex}`, seat.status];
      if (room.turn && room.turn.seatIndex === seat.seatIndex && room.state === 'betting') classes.push('turn');
      if (seat.status !== 'empty' && !seat.connected) classes.push('offline');
      div.className = classes.join(' ');

      if (seat.status === 'empty') {
        div.innerHTML = '<div class="st">empty</div>';
      } else {
        const isYou = seat.userId === state.user?.id;
        const dealer = seat.seatIndex === room.dealerSeat ? '<span class="dealer">D</span> ' : '';
        const backs = '<i></i>'.repeat(seat.cardCount);
        // On a blind table the server sends null for other players' stacks —
        // the figure never reaches this client, so there is nothing to reveal.
        const chipText = seat.chips === null || seat.chips === undefined
          ? '•••'
          : seat.chips.toLocaleString();
        const pic = seat.avatarUrl
          ? `<img class="pic" src="${escapeHtml(seat.avatarUrl)}" alt="" />`
          : '';
        div.innerHTML =
          pic +
          `<div class="nm">${dealer}${isYou ? 'You' : escapeHtml(seat.displayName)}</div>` +
          `<div class="ch${seat.chips === null ? ' hidden' : ''}">${chipText}</div>` +
          `<div class="st">${seat.status === 'active' ? (seat.isBlind ? 'blind' : 'seen') : seat.status}` +
          `${seat.contributed ? ` · ${seat.contributed}` : ''}</div>` +
          `<div class="mini">${backs}</div>`;
      }
      seats.append(div);
    }

    if (room.state === 'waiting') {
      $('status').textContent = `Waiting for players (${room.minPlayers} needed)`;
      stopStartCountdown();
    } else if (room.state === 'starting') {
      startCountdown(room.startsAt);
    } else {
      stopStartCountdown();
    }

    // Own cards: shown only once this player has seen them.
    renderCards(room.you?.cards ?? [], (room.you?.cards ?? []).length > 0);

    if (room.you?.options) {
      state.options = room.you.options;
      if (room.turn?.deadline) startTimer(room.turn.deadline);
    } else if (room.turn?.userId !== state.user?.id) {
      state.options = null;
    }
    renderActions();
  }

  function renderCards(cards, faceUp) {
    const box = $('myCards');
    box.innerHTML = '';
    const count = faceUp ? cards.length : state.room?.you?.status === 'active' ? 3 : 0;

    for (let i = 0; i < count; i += 1) {
      const div = document.createElement('div');
      if (!faceUp) {
        div.className = 'card back';
      } else {
        const code = cards[i];
        const rank = code[0] === 'T' ? '10' : code[0];
        const suit = code[1];
        div.className = `card ${RED.has(suit) ? 'red' : ''}`;
        div.innerHTML = `<span class="r">${rank}</span><span class="s">${SUITS[suit]}</span>`;
      }
      box.append(div);
    }
  }

  function renderActions() {
    const box = $('actions');
    box.innerHTML = '';
    const options = state.options;

    // "See Cards" lives on top of the cards, not in this row. It is only
    // offered on your turn, because that is when the server accepts it.
    $('seeBtn').hidden = !(options && options.canSee);

    if (!options) return;

    const send = (action, amount) => {
      state.options = null;
      renderActions();
      state.socket.emit('game:action', amount === undefined ? { action } : { action, amount });
    };

    const steps = options.raiseSteps ?? [];
    if (state.betIndex < 0 || state.betIndex >= steps.length) state.betIndex = 0;
    const amount = steps[state.betIndex];

    // The bet control, left to right:  [ Chaal 6,400 ] [ − ] [ + ]
    //
    // Chaal sits on the left and is the only thing that places a bet; the
    // steppers beside it only change how much. Raising is therefore "press +,
    // then press Chaal", which keeps committing and adjusting distinct.
    if (steps.length > 0) {
      const chaal = document.createElement('button');
      chaal.className = 'btn primary bet';
      chaal.innerHTML =
        `<span class="lbl">Chaal</span><span class="amt">${amount.toLocaleString()}</span>`;
      // Anything above the base rung is a raise to the server and to the hand
      // history, even though the player presses one button.
      chaal.onclick = () => send(amount === steps[0] ? 'chaal' : 'raise', amount);
      box.append(chaal);

      const stepper = document.createElement('div');
      stepper.className = 'stepper';

      const step = (label, delta, disabled, title) => {
        const button = document.createElement('button');
        button.className = 'btn step';
        button.textContent = label;
        button.disabled = disabled;
        button.title = title;
        button.onclick = (event) => {
          event.stopPropagation();
          state.betIndex = Math.min(steps.length - 1, Math.max(0, state.betIndex + delta));
          renderActions();
        };
        stepper.append(button);
      };

      step('−', -1, state.betIndex <= 0, 'Halve the amount');
      step('+', +1, state.betIndex >= steps.length - 1,
        state.betIndex >= steps.length - 1 ? 'This is the most you can bet' : 'Double the amount');

      box.append(stepper);
    }

    const plain = (label, action, className) => {
      const button = document.createElement('button');
      button.className = `btn ${className}`;
      button.textContent = label;
      button.onclick = () => send(action);
      box.append(button);
    };

    if (options.show) plain(`Show ${options.show.toLocaleString()}`, 'show', 'tonal');
    plain('Pack', 'pack', 'danger');
  }

  // Seeing the cards is a free action, so it can be sent straight from here.
  $('seeBtn').onclick = () => {
    $('seeBtn').hidden = true;
    state.socket.emit('game:action', { action: 'see' });
  };

  // -------------------------------------------------------------- showdown

  /**
   * Requirement 14: shows every revealed hand to everyone at the table, with
   * the winner and the amount written across the middle.
   *
   * `reveals` comes from the server; a client is never told a card it was not
   * sent, so there is nothing here that could leak a hand early.
   */
  function renderShowdown(reveals, result) {
    if ((!reveals || reveals.length === 0) && !result) return;

    const hands = $('showdownHands');
    hands.innerHTML = '';

    for (const reveal of reveals ?? []) {
      const box = document.createElement('div');
      box.className = `showdownhand${reveal.won ? ' winner' : ''}`;

      const who = document.createElement('div');
      who.className = 'who';
      who.textContent =
        (reveal.userId === state.user?.id ? 'You' : seatName(reveal.userId)) + (reveal.won ? ' ✓' : '');

      const cards = document.createElement('div');
      cards.className = 'cards';
      for (const code of reveal.cards ?? []) cards.append(cardElement(code));

      const rank = document.createElement('div');
      rank.className = 'rank';
      rank.textContent = reveal.handName ?? '';

      box.append(who, cards, rank);
      hands.append(box);
    }

    const banner = $('showdownResult');
    banner.innerHTML = '';
    if (result) {
      banner.append(document.createTextNode(result.who));
      const amount = document.createElement('span');
      amount.className = 'amt';
      amount.textContent = result.pot.toLocaleString();
      banner.append(amount);
    }

    $('showdown').hidden = false;
  }

  function hideShowdown() {
    clearTimeout(state.showdownTimer);
    $('showdown').hidden = true;
    $('showdownHands').innerHTML = '';
    $('showdownResult').innerHTML = '';
  }

  /** Builds one face-up card element from a server card code such as "As". */
  function cardElement(code) {
    const div = document.createElement('div');
    const rank = code[0] === 'T' ? '10' : code[0];
    const suit = code[1];
    div.className = `card ${RED.has(suit) ? 'red' : ''}`;
    div.innerHTML = `<span class="r">${rank}</span><span class="s">${SUITS[suit]}</span>`;
    return div;
  }

  // --------------------------------------------------------------- rewards

  /**
   * Formats the bonus countdown. Seconds are always shown (requirement 26), so
   * the timer visibly ticks rather than sitting on the same minute for a while.
   */
  function formatCountdown(ms) {
    const total = Math.max(0, Math.ceil(ms / 1000));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;

    if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
    if (minutes > 0) return `${minutes}m ${seconds}s`;
    return `${seconds}s`;
  }

  /**
   * Renders both rewards. The milestone unlocks every 25 hands played; the
   * bonus recharges over 4 hours, and its unlock time comes from the server so
   * the countdown cannot be skipped by reloading.
   */
  function renderRewards(user) {
    const rewards = user?.rewards;
    if (!rewards) return;

    // Bottom-right: the milestone every 25 hands played (requirement 27).
    const milestoneReady = rewards.milestoneAvailable;
    const milestone = $('milestoneCorner');
    milestone.classList.toggle('ready', milestoneReady);
    milestone.disabled = !milestoneReady;
    $('milestoneMeta').textContent = milestoneReady
      ? `Collect ${rewards.milestoneReward.toLocaleString()}`
      : `${rewards.handsToNextMilestone} hand${rewards.handsToNextMilestone === 1 ? '' : 's'} to go`;

    // Top-left: the 4-hour bonus, counting down in seconds (requirement 26).
    const bonusReady = Date.now() >= rewards.bonusReadyAt;
    const bonus = $('bonusCorner');
    bonus.classList.toggle('ready', bonusReady);
    bonus.disabled = !bonusReady;
    $('bonusMeta').textContent = bonusReady
      ? `Collect ${rewards.bonusReward.toLocaleString()}`
      : formatCountdown(rewards.bonusReadyAt - Date.now());
  }

  /** The corner rewards belong to the lobby, not to a live table. */
  function showCornerRewards(visible) {
    $('bonusCorner').hidden = !visible;
    $('milestoneCorner').hidden = !visible;
    if (!visible) $('rewardMsg').hidden = true;
  }

  const rewardMessage = (text) => {
    const box = $('rewardMsg');
    box.textContent = text;
    box.hidden = !text;

    clearTimeout(state.rewardToast);
    if (text) state.rewardToast = setTimeout(() => { box.hidden = true; }, 4000);
  };

  async function claimReward(path) {
    const response = await fetch(path, {
      method: 'POST',
      headers: { authorization: `Bearer ${state.token}` },
    });
    const data = await response.json();

    if (!response.ok) {
      rewardMessage(data.message ?? 'That reward is not available yet.');
      if (data.user) applyUser(data.user);
      return;
    }

    applyUser(data.user);
    rewardMessage(`Collected ${data.amount.toLocaleString()} chips.`);
  }

  $('milestoneCorner').onclick = () => claimReward('/api/rewards/milestone');
  $('bonusCorner').onclick = () => claimReward('/api/rewards/bonus');

  // The bonus countdown ticks locally between server updates.
  setInterval(() => {
    if (!$('lobby').hidden && state.user) renderRewards(state.user);
  }, 500);

  // -------------------------------------------------------- profile picture

  /** Re-reads the signed-in account so the lobby shows current chips and stats. */
  async function refreshProfile() {
    if (!state.token) return;
    try {
      const response = await fetch('/api/auth/me', {
        headers: { authorization: `Bearer ${state.token}` },
      });
      if (!response.ok) return;
      const { user } = await response.json();
      applyUser(user);
    } catch {
      // Offline or mid-reconnect; the next update will catch up.
    }
  }

  /** Applies a fresh user record from the server across the whole lobby. */
  function applyUser(user) {
    if (!user) return;
    state.user = user;
    $('lobbyChips').textContent = user.chips.toLocaleString();
    renderProfile(user);
  }

  function renderProfile(user) {
    if (!user) return;
    $('currentAvatar').src = user.avatarUrl || '/profiles/ace.svg';
    renderStats(user);
    renderRewards(user);
    renderAvatarGrid();

    // Requirement 21: the picture is locked while seated, because it is
    // already on screen for everyone else at the table.
    const seated = Boolean(state.room);
    $('avatarHint').textContent = seated
      ? 'You cannot change your picture while you are at a table.'
      : 'Pick a picture. Everyone at your table sees it.';
    $('avatarClearBtn').disabled = seated;
  }

  async function loadProfilePictures() {
    try {
      const { profiles } = await (await fetch('/api/profiles')).json();
      state.profiles = profiles ?? [];
      renderAvatarGrid();
    } catch {
      state.profiles = [];
    }
  }

  function renderAvatarGrid() {
    const grid = $('avatarGrid');
    if (!grid) return;
    grid.innerHTML = '';

    const seated = Boolean(state.room);
    for (const profile of state.profiles) {
      const button = document.createElement('button');
      button.type = 'button';
      button.disabled = seated;
      button.classList.toggle('on', state.user?.avatarUrl === profile.url);

      const img = document.createElement('img');
      img.src = profile.url;
      img.alt = profile.id;
      button.append(img);

      button.onclick = () => chooseAvatar(profile.id);
      grid.append(button);
    }
  }

  async function chooseAvatar(avatar) {
    const response = await fetch('/api/profile/avatar', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${state.token}` },
      body: JSON.stringify({ avatar }),
    });
    const data = await response.json();

    if (!response.ok) {
      $('avatarHint').textContent = data.message ?? 'Could not change your picture.';
      return;
    }
    applyUser(data.user);
  }

  $('avatarClearBtn').onclick = () => chooseAvatar(null);

  // ------------------------------------------------------------------ stats

  /** Requirement 16: played, won, lost, abandoned and total winnings. */
  function renderStats(user) {
    const grid = $('statGrid');
    if (!grid) return;

    const rows = [
      ['Played', user.handsPlayed],
      ['Won', user.handsWon],
      ['Lost', user.handsLost],
      ['Left', user.handsLeftMid],
      ['Winnings', user.totalWinnings],
      ['Best pot', user.biggestPot],
    ];

    grid.innerHTML = '';
    for (const [label, value] of rows) {
      const cell = document.createElement('div');
      cell.innerHTML =
        `<div class="v">${(value ?? 0).toLocaleString()}</div><div class="k">${label}</div>`;
      grid.append(cell);
    }
  }

  // -------------------------------------------------------- start countdown

  /**
   * Requirement 24: once more than one player is at the table, the room counts
   * down to the deal. The deadline comes from the server, so every client sees
   * the same number regardless of clock drift.
   */
  function startCountdown(startsAt) {
    stopStartCountdown();
    if (!startsAt) {
      $('status').textContent = 'Starting…';
      return;
    }

    const tick = () => {
      const left = startsAt - Date.now();
      if (left <= 0) {
        $('status').textContent = 'Dealing…';
        stopStartCountdown();
        return;
      }
      const seconds = Math.ceil(left / 1000);
      $('status').textContent = `Starting game in ${seconds} second${seconds === 1 ? '' : 's'}`;
    };

    tick();
    state.startTimer = setInterval(tick, 250);
  }

  function stopStartCountdown() {
    if (state.startTimer) clearInterval(state.startTimer);
    state.startTimer = null;
  }

  // ------------------------------------------------------------------ timer

  function startTimer(deadline) {
    stopTimer();
    const total = state.room?.turnTimeoutMs || 25000;
    state.timerHandle = setInterval(() => {
      const left = Math.max(0, deadline - Date.now());
      const pct = Math.max(0, Math.min(100, (left / total) * 100));
      $('timerFill').style.width = `${pct}%`;
      $('timerFill').classList.toggle('low', left < 6000);
      if (left === 0) stopTimer();
    }, 100);
  }

  function stopTimer() {
    if (state.timerHandle) clearInterval(state.timerHandle);
    state.timerHandle = null;
    $('timerFill').style.width = '0%';
  }

  const escapeHtml = (text) =>
    String(text).replace(/[&<>"']/g, (char) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));

  // Resume an existing session on reload.
  if (state.token) connect();
  else show('login');
})();
