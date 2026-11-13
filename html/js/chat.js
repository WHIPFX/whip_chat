/* ========================================
   whip_chat — renderer

   The message log. Speaks the stock cfx chat NUI protocol (ON_MESSAGE, ON_TEMPLATE_ADD, ...).
   There is no text input here: the player types into whip_core's capsule, which holds the
   keyboard while chat is open. ON_SET_ACTIVE says when the composer is open; ON_SCROLL carries
   the PageUp/PageDown keys whip_core forwards.
   ======================================== */

'use strict';

const MAX_MESSAGES   = 150;   // DOM rows kept; older ones are dropped
const SCROLL_PAGE    = 0.4;   // fraction of the visible height one PageUp/PageDown moves
const SCROLL_MS      = 100;   // how long that movement takes
// How long one message stays at full opacity. Same value as RECENT_MS today, but tuned separately.
const FRESH_MS       = 8000;
const RECENT_MS      = 8000;  // how long the list stays on screen at all in "when active" mode

const HIDE_WHEN_ACTIVE = 0;
const HIDE_ALWAYS_SHOW = 1;
const HIDE_ALWAYS_HIDE = 2;

/* ---- Elements ---- */
const elChat     = document.getElementById('chat');
const elMessages = document.getElementById('chat-messages');

/* ========================================
   RESOLUTION SCALING

   Designed at 1440p like every whip screen: --ui-scale = window height / 1440 (the same as
   whip_core's utils.js). SetChatScale (client/main.lua) multiplies on top.
   ======================================== */
let userScale = 1;

function applyScale() {
    document.documentElement.style.setProperty('--ui-scale', (window.innerHeight / 1440) * userScale);
}
applyScale();
window.addEventListener('resize', applyScale);

/* ---- State ----
   `isOpen`: the player is composing (told by ON_SET_ACTIVE). addMessage uses it to avoid yanking
   someone out of scrollback. */
let isOpen      = false;
let templates   = {};      // [id] = html
let recentTimer = null;
let hideState   = HIDE_WHEN_ACTIVE;

/* ========================================
   COLOUR CODES

   ^0-^9, the GTA convention, mapped to whip's tokens (^1 error red, ^2 success green, ^3 warning amber).
   ======================================== */
const COLOR_CODES = {
    '0': 'rgba(255,255,255,0.85)',   // reset / default
    '1': '#f87171',                  // --ui-error
    '2': '#4ade80',                  // --ui-success
    '3': '#fbbf24',                  // --ui-warning
    '4': '#60a5fa',                  // --ui-accent
    '5': '#22d3ee',                  // cyan
    '6': '#c084fc',                  // purple
    '7': 'rgba(255,255,255,0.85)',   // white — the usual "back to normal"
    '8': '#fb923c',                  // orange
    '9': 'rgba(255,255,255,0.45)',   // dim
};

/** Escape first, always: message args are player-controlled text. */
function escapeHtml(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Turn ^N codes into spans. Must run on already-escaped text, so a player can't inject markup.
 */
function applyColorCodes(escaped) {
    if (escaped.indexOf('^') === -1) return escaped;

    let out = '';
    let open = 0;

    for (let i = 0; i < escaped.length; i++) {
        const ch = escaped[i];
        const next = escaped[i + 1];

        if (ch === '^' && next !== undefined && COLOR_CODES[next] !== undefined) {
            if (open > 0) { out += '</span>'; open--; }
            out += '<span style="color:' + COLOR_CODES[next] + '">';
            open++;
            i++;                     // consume the digit
            continue;
        }
        out += ch;
    }

    while (open > 0) { out += '</span>'; open--; }
    return out;
}

/** An arg as it should appear inside a template: escaped, then coloured. */
function renderArg(value) {
    return applyColorCodes(escapeHtml(value === undefined || value === null ? '' : value));
}

/** `color` may be [r,g,b] (stock) or any CSS colour string. */
function resolveColor(color) {
    if (!color) return null;
    if (Array.isArray(color)) {
        const [r, g, b] = color;
        if ([r, g, b].every((n) => typeof n === 'number')) return `rgb(${r},${g},${b})`;
        return null;
    }
    return typeof color === 'string' ? color : null;
}

/**
 * Fill {0} {1} ... and {name} placeholders.
 * The template comes from a resource (chat:addTemplate) and is trusted; the values come from
 * players, so each goes through renderArg.
 */
function fillTemplate(template, args, params) {
    let html = template;

    html = html.replace(/\{(\d+)\}/g, (_, index) => renderArg(args[Number(index)]));

    if (params) {
        html = html.replace(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (whole, key) =>
            Object.prototype.hasOwnProperty.call(params, key) ? renderArg(params[key]) : whole);
    }

    return html;
}

/**
 * No template given: one arg is a bare line (a notice); two or more render as `Name: message`.
 */
function defaultTemplate(args) {
    if (!args || args.length === 0) return '';
    if (args.length === 1) return '{0}';
    return '<span class="chat-author">{0}</span>: '
        + args.slice(1).map((_, i) => `{${i + 1}}`).join(' ');
}

/* ========================================
   MESSAGES
   ======================================== */

function addMessage(message) {
    if (!message) return;
    if (typeof message === 'string') message = { args: [message] };

    const args   = Array.isArray(message.args) ? message.args : [];
    const params = message.params || null;

    let template = message.template;
    if (!template && message.templateId) template = templates[message.templateId];
    if (!template) template = defaultTemplate(args);

    const row = document.createElement('div');
    // `fresh` = full opacity until its own timer (below) drops it to the resting level.
    row.className = 'chat-msg fresh';

    // `multiline` defaults to true in every stock caller that sets it; false means clip.
    if (message.multiline === false) row.classList.add('single-line');
    if (message.templateId === 'print') row.classList.add('is-print');
    if (message.whipKind === 'command') row.classList.add('is-command');

    const color = resolveColor(message.color);
    if (color) row.style.color = color;

    row.innerHTML = fillTemplate(template, args, params);

    elMessages.appendChild(row);

    while (elMessages.children.length > MAX_MESSAGES) {
        elMessages.removeChild(elMessages.firstChild);
    }

    // Auto-scroll only if the player is already at the bottom (or not composing).
    const atBottom = elMessages.scrollHeight - elMessages.scrollTop - elMessages.clientHeight < 60;
    if (atBottom || !isOpen) {
        // Stop a running scroll animation, or its next frame undoes this jump.
        cancelScrollAnim();
        elMessages.scrollTop = elMessages.scrollHeight;
    }

    // One timer per row, so each message gets its full time.
    setTimeout(() => row.classList.remove('fresh'), FRESH_MS);

    markRecent();
}

function markRecent() {
    elChat.classList.add('recent');
    if (recentTimer) clearTimeout(recentTimer);
    recentTimer = setTimeout(() => {
        elChat.classList.remove('recent');
        recentTimer = null;
    }, RECENT_MS);
}

function clearMessages() {
    elMessages.innerHTML = '';
}

/* ========================================
   COMPOSING

   The input, suggestions and modes are whip_core's (html/js/composer.js). Lua only tells this
   page when composing starts and stops.
   ======================================== */

/** The composer opened or closed: un-dim the log while composing. */
function setActive(active) {
    isOpen = !!active;
    elChat.classList.toggle('focused', isOpen);

    if (isOpen) {
        // Jump to the newest line on open.
        cancelScrollAnim();
        elMessages.scrollTop = elMessages.scrollHeight;
    }
}

/* ========================================
   SCROLLING
   ======================================== */

let scrollAnim = null;

/** Stop any animation in flight, so a direct scrollTop write is not overwritten next frame. */
function cancelScrollAnim() {
    if (scrollAnim !== null) {
        cancelAnimationFrame(scrollAnim);
        scrollAnim = null;
    }
}

/**
 * Scroll by `delta` pixels over SCROLL_MS. Hand-animated because `scroll-behavior: smooth` can't
 * be made this short.
 */
function smoothScrollBy(delta) {
    const start = elMessages.scrollTop;
    const limit = elMessages.scrollHeight - elMessages.clientHeight;
    const target = Math.max(0, Math.min(start + delta, limit));

    cancelScrollAnim();
    if (target === start) return;      // already pinned at an end

    const began = performance.now();

    const step = (now) => {
        const t = Math.min(1, (now - began) / SCROLL_MS);
        // ease-out cubic
        const eased = 1 - Math.pow(1 - t, 3);

        elMessages.scrollTop = start + (target - start) * eased;

        scrollAnim = t < 1 ? requestAnimationFrame(step) : null;
    };

    scrollAnim = requestAnimationFrame(step);
}

/**
 * Scroll the log by one page. This page never gets key events (whip_core's frame holds the
 * keyboard); PageUp/PageDown arrive as ON_SCROLL.
 *
 * @param {number} delta -1 for a page up, 1 for a page down
 */
function scrollByPage(delta) {
    smoothScrollBy(delta * elMessages.clientHeight * SCROLL_PAGE);
}

/* ========================================
   NUI TRANSPORT
   ======================================== */

/**
 * Callbacks go to `https://<resource>/<name>`, not the page's own origin (cfx-nui-<resource>).
 * A root-relative fetch fails silently. GetParentResourceName survives a folder rename; the
 * literal is a fallback for opening the page outside the game.
 */
const RESOURCE_NAME = (typeof GetParentResourceName === 'function')
    ? GetParentResourceName()
    : 'whip_chat';

function post(name, body) {
    fetch(`https://${RESOURCE_NAME}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body),
    }).catch(() => { /* the game closing mid-post is not an error worth surfacing */ });
}

function applyHideState(state) {
    hideState = state;
    elChat.classList.toggle('hidden', state === HIDE_ALWAYS_HIDE);

    // Don't toggle `when-active` while hiding: `hidden` fades the container and `when-active` the
    // list inside it, and changing both in one frame flashes. `hidden` alone hides everything.
    if (state !== HIDE_ALWAYS_HIDE) {
        elChat.classList.toggle('when-active', state === HIDE_WHEN_ACTIVE);
    }
}

window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || !data.type) return;

    switch (data.type) {
        case 'ON_MESSAGE':
            addMessage(data.message);
            break;

        case 'ON_CLEAR':
            clearMessages();
            break;

        case 'ON_TEMPLATE_ADD':
            if (data.template && data.template.id) {
                templates[data.template.id] = data.template.html || '';
            }
            break;

        // The composer opened or closed.
        case 'ON_SET_ACTIVE':
            setActive(data.active);
            break;

        // PageUp / PageDown, forwarded from whip_core's composer.
        case 'ON_SCROLL':
            scrollByPage(data.delta || 0);
            break;

        case 'ON_SCREEN_STATE_CHANGE':
            applyHideState(data.hideState);
            if (data.fromUserInteraction) markRecent();
            break;

        // A multiplier on top of the resolution scale (see applyScale).
        case 'ON_SET_SCALE':
            userScale = Number(data.scale) > 0 ? Number(data.scale) : 1;
            applyScale();
            break;
    }
});

// Tell Lua we are up; it replies with the saved hide state and modes. client/main.lua warns if
// this never arrives.
post('loaded', {});
