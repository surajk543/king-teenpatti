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
    category: 'seen',
    stakes: [200, 5000],
    stake: 200,
    /** Room chat, mirrored from the server for as long as we are in the room. */
    chat: [],
    chatOpen: false,
    unread: 0,
  };

  const show = (screen) => {
    for (const id of ['login', 'lobby', 'table']) $(id).hidden = id !== screen;
  };

  const log = (text, highlight = false) => {
    const line = document.createElement('div');
    if (highlight) line.className = 'hl';
    line.textContent = text;
    $('log').prepend(line);
    while ($('log').childElementCount > 60) $('log').lastElementChild.remove();
  };

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
        state.stake = config.stakes[0];
      }
      renderStakes();
      show('lobby');
    });

    socket.on('session:replaced', () => {
      alert('You signed in from another device.');
      show('login');
    });

    socket.on('room:joined', (room) => {
      $('log').innerHTML = '';
      // The server sends this room's backlog right after the join.
      state.chat = [];
      state.unread = 0;
      setChatOpen(false);
      render(room);
      show('table');
      log(`Joined table ${room.code}.`, true);
    });

    socket.on('room:state', render);

    socket.on('room:left', () => {
      state.room = null;
      // Leaving the room means leaving its chat; nothing is carried forward.
      state.chat = [];
      state.unread = 0;
      setChatOpen(false);
      show('lobby');
    });

    socket.on('room:closed', () => {
      show('lobby');
      $('lobbyError').textContent = 'That table closed.';
      $('lobbyError').hidden = false;
    });

    socket.on('game:handStarted', ({ handNo, pot }) => {
      log(`— Hand #${handNo} dealt. Boot collected, pot ${pot}. —`, true);
    });

    socket.on('player:cards', ({ cards }) => renderCards(cards, true));

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
    });

    socket.on('game:handEnded', ({ winnerName, winnerId, pot, reason }) => {
      stopTimer();
      state.options = null;
      renderActions();
      const who = winnerId === state.user?.id ? 'You win' : `${winnerName || 'Nobody'} wins`;
      $('status').textContent = `${who} ${pot.toLocaleString()}`;
      log(`${who} the pot of ${pot.toLocaleString()} (${reason.replace(/_/g, ' ')}).`, true);
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
        if (ack && ack.ok === false) {
          $('lobbyError').textContent = ack.message;
          $('lobbyError').hidden = false;
        }
        resolve(ack);
      });
    });

  $('quickJoinBtn').onclick = () =>
    emit('room:quickJoin', { bootAmount: state.stake, category: state.category });
  $('createBtn').onclick = () =>
    emit('room:create', { bootAmount: state.stake, category: state.category, isPrivate: true });
  $('joinCodeBtn').onclick = () => emit('room:joinCode', { code: $('codeInput').value.trim().toUpperCase() });
  // --- lobby selectors -------------------------------------------------
  for (const button of $('categorySelect').querySelectorAll('button')) {
    button.onclick = () => {
      state.category = button.dataset.category;
      for (const other of $('categorySelect').querySelectorAll('button')) {
        other.classList.toggle('on', other === button);
      }
    };
  }

  function renderStakes() {
    const box = $('stakeSelect');
    box.innerHTML = '';
    for (const stake of state.stakes) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = stake.toLocaleString();
      button.classList.toggle('on', stake === state.stake);
      button.onclick = () => {
        state.stake = stake;
        renderStakes();
      };
      box.append(button);
    }
  }
  $('leaveBtn').onclick = () => emit('room:leave');

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
    $('stake').textContent = room.stake.toLocaleString();
    if (room.you) $('myChips').textContent = room.you.chips.toLocaleString();

    const seats = $('seats');
    seats.innerHTML = '';
    for (const seat of room.seats) {
      const div = document.createElement('div');
      const classes = ['seat', seat.status];
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
        div.innerHTML =
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
    } else if (room.state === 'starting') {
      $('status').textContent = 'Starting…';
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
    if (!options) return;

    const send = (action, amount) => {
      state.options = null;
      renderActions();
      state.socket.emit('game:action', amount === undefined ? { action } : { action, amount });
    };

    const button = (label, action, enabled = true, amount) => {
      const btn = document.createElement('button');
      btn.className = `btn ${action === 'pack' ? '' : 'primary'}`;
      btn.textContent = label;
      btn.disabled = !enabled;
      btn.onclick = () => send(action, amount);
      box.append(btn);
    };

    if (options.canSee) button('See Cards', 'see');

    // The bet control: [ − ][ Chaal <amount> ][ + ].
    //
    // "+" doubles the amount and "−" halves it, walking the ladder the server
    // sent. The amount lives on the Chaal button, and Chaal is the only thing
    // that places the bet — the steppers just choose how much.
    const steps = options.raiseSteps ?? [];
    if (steps.length > 0) {
      if (state.betIndex < 0 || state.betIndex >= steps.length) state.betIndex = 0;
      const amount = steps[state.betIndex];

      const stepper = document.createElement('div');
      stepper.className = 'stepper';

      const minus = document.createElement('button');
      minus.className = 'btn step';
      minus.textContent = '−';
      minus.disabled = state.betIndex <= 0;
      minus.title = 'Halve the amount';
      minus.onclick = (event) => {
        event.stopPropagation();
        state.betIndex = Math.max(0, state.betIndex - 1);
        renderActions();
      };

      const chaal = document.createElement('button');
      chaal.className = 'btn primary raise';
      chaal.innerHTML =
        `<span class="lbl">Chaal</span><span class="amt">${amount.toLocaleString()}</span>`;
      // Anything above the base rung is a raise as far as the server (and the
      // hand history) is concerned, even though the player taps one button.
      chaal.onclick = () => send(amount === steps[0] ? 'chaal' : 'raise', amount);

      const plus = document.createElement('button');
      plus.className = 'btn step';
      plus.textContent = '+';
      plus.disabled = state.betIndex >= steps.length - 1;
      plus.title = state.betIndex >= steps.length - 1
        ? 'This is the most you can bet'
        : 'Double the amount';
      plus.onclick = (event) => {
        event.stopPropagation();
        state.betIndex = Math.min(steps.length - 1, state.betIndex + 1);
        renderActions();
      };

      stepper.append(minus, chaal, plus);
      box.append(stepper);
    }

    if (options.show) button(`Show ${options.show.toLocaleString()}`, 'show');
    button('Pack', 'pack');
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
