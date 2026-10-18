// Simul site: the app's orbit mark, drawn live, and a small scripted Simul
// you can use (the demo). No dependencies. Without JS the demo shows its HTML
// as-is.

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

/* ---------- Demo script ----------
   Each session has transcript lines that appear at given times (ms after
   the demo starts) and state changes: working → done | waiting. */

const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
const prompt = (t) => `<span class="t-prompt">› ${esc(t)}</span>`;
const step = (t) => `<span class="t-dot">●</span> ${t}`;
const note = (t) => `  <span class="t-dim">${t}</span>`;
const done = (t) => `<span class="t-done">✓</span> ${esc(t)}`;

const SESSIONS = [
  {
    startedAgo: 0,
    state: 'working',
    lines: [
      [0, prompt('Make the checkout tests pass again')],
      [900, step('Reading tests/checkout.spec.ts')],
      [2000, step('The price fixture still uses the old currency format')],
      [3100, note('Editing src/price.ts <span class="t-add">+3</span> <span class="t-del">−1</span>')],
      [4200, step('Running npm test…')],
      [5600, note('48 passed')],
      [6800, done('Done. Two files changed.')],
    ],
    events: [[6800, 'done']],
  },
  {
    startedAgo: 95,
    state: 'working',
    lines: [
      [0, prompt('Add a yearly toggle to the pricing table')],
      [0, step('Updated PricingTable.tsx and plans.ts')],
      [1400, step('Ran the component tests')],
      [2400, note('12 passed')],
      [3500, done('Ready for review on feat/plans.')],
    ],
    events: [[3500, 'done']],
  },
  {
    startedAgo: 40,
    state: 'working',
    lines: [
      [0, prompt('Add an index for orders by customer')],
      [1500, step('Wrote migration 0042_orders_customer_idx')],
      [5200, step('Want me to apply it to your local database?')],
    ],
    events: [[5200, 'waiting']],
    question: 'Run <code>npm run migrate</code>?',
    afterYes: [
      [300, step('Running npm run migrate…')],
      [1500, note('Applied 0042_orders_customer_idx (38 ms)')],
      [2300, done('Done.')],
    ],
  },
  {
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

  const sessions = SESSIONS.map((s) => ({ ...s, shown: [], unread: false, answered: null }));
  let selected = 0;
  let t0 = null;
  let timers = [];

  const later = (ms, fn) => { timers.push(setTimeout(fn, instant ? 0 : ms)); };

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
      const status = tab.querySelector('[data-status]');
      if (s.state === 'working') {
        status.innerHTML = `<span class="elapsed">${elapsed(s)}</span><span class="pixel-loader" aria-label="working">${'<i></i>'.repeat(9)}</span>`;
      } else if (s.state === 'waiting') {
        status.innerHTML = '<span class="pixel-label is-ember">needs you</span>';
      } else if (s.state === 'done' && s.unread) {
        status.innerHTML = '<span class="pixel-label">done</span>';
      } else {
        status.innerHTML = '';
      }
      const label = `${tab.querySelector('.s-title').textContent}: ${
        { working: 'working', waiting: 'needs your answer', done: 'done', idle: 'idle' }[s.state]}`;
      tab.setAttribute('aria-label', label);
    });
  }

  function renderTerminal() {
    const s = sessions[selected];
    let html = s.shown.map((l) => `<p class="t-line">${l}</p>`).join('');
    if (s.state === 'waiting') {
      html += `<p class="t-line t-ask">  ${s.question}
        <button type="button" class="answer" data-answer="yes">Yes</button>
        <button type="button" class="answer" data-answer="no">No</button></p>`;
    } else if (s.state === 'working') {
      html += '<p class="t-line"><span class="cursor"></span></p>';
    }
    terminal.innerHTML = html;
    terminal.scrollTop = terminal.scrollHeight;
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
    s.shown.push(`  ${s.question} <span class="t-dim">${yes ? 'yes' : 'no'}</span>`);
    if (!yes) {
      s.shown.push(note('Okay, leaving the database as it is.'));
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
    if (!instant) setInterval(renderTabs, 1000); // elapsed timers
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
