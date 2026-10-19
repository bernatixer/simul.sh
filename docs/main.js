// Simul site: the app's orbit mark, drawn live, and a small scripted Simul
// you can use (the demo). No dependencies. Without JS the demo shows its HTML
// as-is.

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

/* ---------- Demo script ----------
   Each session has transcript lines that appear at given times (ms after
   the demo starts) and state changes: working → done | waiting. Lines are
   styled roughly like each agent's own TUI. */

const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
const user = (t) => `<span class="t-user">❯ ${esc(t)}</span>`;
const tool = (name, arg) => `<span class="t-ok">●</span> <b>${name}</b>(${esc(arg)})`;
const out = (t) => `  <span class="t-dim">⎿</span>  ${t}`;
const say = (t) => `● ${t}`;
const churned = (t) => `<span class="t-dim">✻ ${t}</span>`;
const codexUser = (t) => `<span class="t-user">› ${esc(t)}</span>`;
const codex = (t) => `<span class="t-dim">•</span> ${t}`;
const codexOut = (t) => `  <span class="t-dim">└</span> ${t}`;

const SESSIONS = [
  {
    agent: 'claude',
    startedAgo: 0,
    state: 'working',
    lines: [
      [0, user('Make the checkout tests pass again')],
      [900, tool('Read', 'tests/checkout.test.js')],
      [900, out('Read 24 lines')],
      [2200, say('The price fixture still uses the old currency format.')],
      [3300, tool('Update', 'src/price.ts')],
      [3300, out('Updated src/price.ts with <span class="t-add">3 additions</span> and <span class="t-del">1 removal</span>')],
      [4600, tool('Bash', 'npm test')],
      [5800, out('48 passed')],
      [6900, say('Done. Euros now format as €19.99; two files changed.')],
      [6900, churned('Churned for 47s')],
    ],
    events: [[6900, 'done']],
  },
  {
    agent: 'claude',
    startedAgo: 40,
    state: 'working',
    lines: [
      [0, user('Add an index for orders by customer')],
      [1500, tool('Write', 'migrations/0042_orders_customer_idx.sql')],
      [1500, out('Wrote 3 lines')],
    ],
    events: [[5200, 'waiting']],
    question: '<b>Bash command</b>\n\n  npm run migrate\n  Apply the new migration to your local database\n\nDo you want to proceed?',
    afterYes: [
      [300, tool('Bash', 'npm run migrate')],
      [1500, out('Applied 0042_orders_customer_idx (38 ms)')],
      [2300, say('Done. The index is in place.')],
      [2300, churned('Cooked for 1m 12s')],
    ],
  },
  {
    agent: 'codex',
    startedAgo: 95,
    state: 'working',
    lines: [
      [0, codexUser('Review the orders API for N+1 queries')],
      [0, codex('Explored')],
      [0, codexOut('Read orders.ts, customers.ts')],
      [1400, codex('Found one: <code>listOrders</code> loads each customer separately.')],
      [2600, codex('Edited orders.ts (<span class="t-add">+9</span> <span class="t-del">-4</span>)')],
      [3500, codex('Ran npm test')],
      [3500, codexOut('31 passed')],
      [4200, '<span class="t-dim">─ Worked for 1m 41s ─</span>'],
    ],
    events: [[4200, 'done']],
  },
  {
    agent: 'shell',
    startedAgo: 0,
    state: 'idle',
    lines: [
      [0, '<span class="t-dim">~/docs main $</span> git status'],
      [0, 'On branch main'],
      [0, 'nothing to commit, working tree clean'],
      [0, '<span class="t-dim">~/docs main $</span> <span class="cursor"></span>'],
    ],
    events: [],
  },
];

function setupDemo() {
  const demo = document.querySelector('[data-demo]');
  if (!demo) return;
  const tabs = [...demo.querySelectorAll('[data-session]')];
  const terminal = demo.querySelector('[data-terminal]');
  const instant = reducedMotion.matches;

  const sessions = SESSIONS.map((s) => ({ ...s, shown: [], unread: false }));
  let selected = 0;
  let t0 = null;

  const later = (ms, fn) => setTimeout(fn, instant ? 0 : ms);

  function show(i, html) {
    sessions[i].shown.push(html);
    if (i === selected) renderTerminal();
  }

  function setState(i, state) {
    const s = sessions[i];
    s.state = state;
    if (i !== selected && (state === 'done' || state === 'waiting')) s.unread = true;
    renderTabs();
    if (i === selected) renderTerminal();
  }

  function elapsed(s) {
    const seconds = Math.floor(s.startedAgo + (t0 ? (performance.now() - t0) / 1000 : 0));
    return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m`;
  }

  function renderTabs() {
    tabs.forEach((tab, i) => {
      const s = sessions[i];
      tab.setAttribute('aria-selected', String(i === selected));
      tab.tabIndex = i === selected ? 0 : -1;
      tab.classList.toggle('is-selected', i === selected);
      tab.classList.toggle('is-unread', s.unread);
      tab.querySelector('.tile').classList.toggle('is-working', s.state === 'working');
      tab.querySelector('[data-status]').textContent = s.state === 'working' ? elapsed(s) : '';
      const label = `${tab.querySelector('.s-title').textContent}: ${
        { working: 'working', waiting: 'needs your answer', done: 'done', idle: 'idle' }[s.state]}`;
      tab.setAttribute('aria-label', label);
    });
  }

  function renderTerminal() {
    const s = sessions[selected];
    let html = s.shown.map((l) => `<p class="t-line">${l}</p>`).join('');
    if (s.state === 'waiting') {
      html += `<div class="t-line t-ask">${s.question}
<button type="button" class="answer" data-answer="yes">❯ 1. Yes</button><button type="button" class="answer" data-answer="no">  2. No</button></div>`;
    } else if (s.state === 'working' && s.agent === 'claude') {
      html += `<p class="t-line t-claude">✻ Wibbling… <span class="t-dim">(${elapsed(s)} · esc to interrupt)</span></p>`;
    } else if (s.state === 'working') {
      html += `<p class="t-line"><span class="t-dim">• Working (${elapsed(s)} · esc to interrupt)</span></p>`;
    }
    let input = '';
    if (s.agent === 'claude') {
      input = `<p class="t-line t-input">❯ ${s.state === 'waiting' ? '' : '<span class="cursor"></span>'}</p><p class="t-line t-hint">? for shortcuts</p>`;
    } else if (s.agent === 'codex') {
      input = '<p class="t-line t-input">› <span class="cursor"></span></p><p class="t-line t-hint">⏎ send   ⌃J newline</p>';
    }
    terminal.innerHTML = `<div class="t-scroll">${html}</div>${input}`;
    const scroll = terminal.firstElementChild;
    scroll.scrollTop = scroll.scrollHeight;
  }

  function select(i) {
    selected = i;
    sessions[i].unread = false;
    renderTabs();
    renderTerminal();
  }

  function answer(yes) {
    const i = selected;
    const s = sessions[i];
    if (s.state !== 'waiting') return;
    if (!yes) {
      s.shown.push(out('<span class="t-dim">No, leaving the database as it is.</span>'));
      setState(i, 'idle');
      return;
    }
    setState(i, 'working');
    s.afterYes.forEach(([ms, line]) => later(ms, () => show(i, line)));
    later(s.afterYes[s.afterYes.length - 1][0], () => setState(i, 'done'));
  }

  function start() {
    t0 = performance.now();
    sessions.forEach((s, i) => {
      s.lines.forEach(([ms, line]) => (ms === 0 ? s.shown.push(line) : later(ms, () => show(i, line))));
      s.events.forEach(([ms, state]) => later(ms, () => setState(i, state)));
    });
    renderTabs();
    renderTerminal();
    // Elapsed timers, on the cards and the spinner line.
    if (!instant) {
      setInterval(() => {
        renderTabs();
        if (sessions[selected].state === 'working') renderTerminal();
      }, 1000);
    }
  }

  tabs.forEach((tab, i) => tab.addEventListener('click', () => select(i)));
  demo.addEventListener('click', (event) => {
    const button = event.target.closest('[data-answer]');
    if (button) answer(button.dataset.answer === 'yes');
  });
  // Inside the demo only: 1–4 switch sessions, arrows move between them,
  // y/n answer a question. Never hijacks keys elsewhere on the page.
  demo.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const n = Number(event.key);
    if (n >= 1 && n <= tabs.length) { select(n - 1); tabs[n - 1].focus(); event.preventDefault(); }
    else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      const next = (selected + (event.key === 'ArrowDown' ? 1 : tabs.length - 1)) % tabs.length;
      select(next); tabs[next].focus(); event.preventDefault();
    } else if (event.key === 'y' || event.key === 'n') answer(event.key === 'y');
  });

  renderTabs();
  renderTerminal();
  if (instant || !('IntersectionObserver' in window)) { start(); return; }
  new IntersectionObserver(([entry], observer) => {
    if (!entry.isIntersecting) return;
    observer.disconnect();
    start();
  }, { threshold: 0.35 }).observe(demo);
}

/* ---------- Orbit ----------
   A port of UI/Components/DotMatrix.swift's .orbit source: eight boards on a
   dotted ring around the player, with a light moving from board to board. */

function orbitCells(n) {
  const center = (n - 1) / 2;
  const orbit = n * 0.34;
  const boards = Array.from({ length: 8 }, (_, i) => {
    const angle = i * Math.PI / 4 - Math.PI / 2;
    return [center + orbit * Math.cos(angle), center + orbit * Math.sin(angle)];
  });
  const disc = (distance, radius) => Math.min(1, Math.max(0, radius + 0.5 - distance));
  const cells = new Float32Array(n * n);
  for (let row = 0; row < n; row++) {
    for (let col = 0; col < n; col++) {
      const distance = Math.hypot(col - center, row - center);
      let coverage = Math.abs(distance - orbit) < 0.5 && (row + col) % 2 === 0 ? 0.25 : 0;
      for (const [bx, by] of boards) coverage = Math.max(coverage, disc(Math.hypot(col - bx, row - by), n * 0.065));
      cells[row * n + col] = Math.max(coverage, disc(distance, n * 0.12));
    }
  }
  return cells;
}

// Same stable per-dot noise as the Swift version, so the dots match the icon.
function hash(row, col) {
  let x = (Math.imul(row, 73856093) ^ Math.imul(col, 19349663)) >>> 0;
  x = (x ^ (x >>> 13)) >>> 0;
  x = Math.imul(x, 0x5bd1e995) >>> 0;
  x = (x ^ (x >>> 15)) >>> 0;
  return (x % 10000) / 10000;
}

function setupOrbit() {
  const canvas = document.querySelector('[data-orbit]');
  if (!canvas) return;
  const n = 36;
  const cells = orbitCells(n);
  const center = (n - 1) / 2;
  const context = canvas.getContext('2d');

  function draw(time) {
    const size = canvas.width;
    const cell = size / n;
    const dot = cell * 0.62;
    context.clearRect(0, 0, size, size);
    for (let row = 0; row < n; row++) {
      for (let col = 0; col < n; col++) {
        const coverage = cells[row * n + col];
        if (coverage <= 0.12) continue;
        const noise = hash(row, col);
        const angle = Math.atan2(row - center, col - center);
        const sweep = Math.pow(Math.max(0, Math.cos(angle - time * 1.6)), 10) * 0.55;
        const brightness = Math.min(1, 0.22 + 0.6 * coverage * (0.55 + 0.45 * noise) + sweep);
        context.fillStyle = noise < 0.07 ? `rgba(115, 189, 219, ${brightness})` : `rgba(255, 255, 255, ${brightness})`;
        context.beginPath();
        context.roundRect(col * cell + (cell - dot) / 2, row * cell + (cell - dot) / 2, dot, dot, dot * 0.2);
        context.fill();
      }
    }
  }

  let visible = false;
  let last = 0;
  function frame(now) {
    if (!visible) return;
    if (now - last > 1000 / 24) { last = now; draw(now / 1000); }
    requestAnimationFrame(frame);
  }

  function resize() {
    const px = Math.round(canvas.clientWidth * devicePixelRatio);
    if (canvas.width !== px) { canvas.width = canvas.height = px; }
    draw(reducedMotion.matches ? -0.5 : performance.now() / 1000);
  }
  new ResizeObserver(resize).observe(canvas);
  if (reducedMotion.matches) return;
  // Only animate while on screen.
  new IntersectionObserver(([entry]) => {
    const was = visible;
    visible = entry.isIntersecting;
    if (visible && !was) requestAnimationFrame(frame);
  }).observe(canvas);
}

setupOrbit();
setupDemo();
