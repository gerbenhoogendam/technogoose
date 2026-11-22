// Scroll-linked motion for the Techno Goose site. Only transform and opacity change per frame.
// [data-depth]: parallax offset relative to the viewport centre. [data-scene]: a tall section with a sticky stage,
// driven by its scroll progress p (0 at the top, 1 when its stage is about to scroll away).
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
if (reduce) document.documentElement.classList.add('reduce');

const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const seg = (p, a, b) => clamp((p - a) / (b - a));
const lerp = (a, b, t) => a + (b - a) * t;
const ease = x => (x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
const $ = (el, s) => el.querySelector(s), $$ = (el, s) => [...el.querySelectorAll(s)];

const THEMES = [
  ['Nova Midnight', '#ff4f9a40'], ['Nova Daylight', '#6c5ce740'], ['Neon Pond', '#2ef2c840'], ['Macintosh 512K', '#ffffff26'], ['Label Lime', '#d4ff0040'],
];

const scenes = {
  hero(p, el) {
    const e = ease(seg(p, 0, .75)), vh = innerHeight;
    $(el, '.hero-shot').style.transform = `translate(-50%, ${lerp(.46, innerWidth > 820 ? -.4 : -.16, e) * vh}px) rotateX(${lerp(56, 0, e)}deg) scale(${lerp(.8, 1, e)})`;
    const copy = $(el, '.hero-copy');
    copy.style.transform = `translateY(${-p * .55 * vh}px) scale(${1 - .1 * p})`;
    copy.style.opacity = 1 - seg(p, .12, .45);
    $(el, '.grid').style.transform = `rotateX(62deg) translateY(${(p * 320) % 80}px)`;
  },
  sync(p, el) {
    // 0–.22 zoom to the button · .22–.62 the three directions · .62–.95 the dry run sheet rises
    const z = ease(seg(p, .02, .22)), out = ease(seg(p, .6, .72));
    $(el, '.zoom').style.transform = `scale(${lerp(1, 2.6, z) - .9 * out})`;
    $(el, '.ring').style.opacity = z > .9 && out < .5 ? 1 : 0;
    $(el, '.dim').style.opacity = .6 * out;
    const s = ease(seg(p, .66, .8)), sheet = $(el, '.sheet');
    sheet.style.opacity = s;
    sheet.style.transform = `translate(-50%, ${lerp(60, -50, s)}%) scale(${lerp(.9, 1.06, seg(p, .8, 1))})`;
    $$(el, '.step').forEach((st, i) => {
      const a = [.2, .34, .48, .64][i], b = i < 3 ? a + .14 : 1.1;
      const v = Math.min(seg(p, a, a + .05), 1 - seg(p, b - .03, b));
      st.style.opacity = v;
      st.style.transform = `translateY(${(1 - v) * (p < a + .05 ? 40 : -40)}px)`;
    });
  },
  undo(p, el) {
    $(el, '.pan img').style.transform = `scale(${lerp(1, 2.1, ease(seg(p, .15, .85)))})`;
  },
  four(p, el) {
    const img = $(el, '.wide img'), box = img.parentElement;
    const room = img.getBoundingClientRect().width - box.getBoundingClientRect().width;
    img.style.transform = `translateX(${-room * ease(seg(p, .08, .92))}px)`;
  },
  themes(p, el) {
    // .0–.2 the stack fans out · then each card takes the stage in turn
    const cards = $$(el, '.card'), fan = ease(seg(p, 0, .2)), focus = seg(p, .22, .98) * (cards.length - .001), active = Math.floor(focus);
    const wide = innerWidth > 820;
    cards.forEach((c, i) => {
      const d = i - focus, near = Math.max(0, 1 - Math.abs(d)), spread = wide ? 30 : 46;
      const x = lerp((i - (cards.length - 1) / 2) * 6, d * spread * .8, fan), y = lerp(i * -2, Math.abs(d) * 4, fan);
      c.style.transform = `translate(-50%, -50%) translate(${x}vw, ${y}vh) perspective(1400px) rotateY(${-d * 14 * fan}deg) scale(${lerp(.75, .62 + .38 * near, fan)})`;
      c.style.opacity = fan < 1 ? 1 : clamp(.35 + near);
      c.style.zIndex = Math.round(10 - Math.abs(d) * 2);
    });
    const name = $(el, '.theme-name'), t = THEMES[fan < 1 ? 0 : active];
    if (name.textContent !== t[0]) name.textContent = t[0];
    $(el, '.tint').style.setProperty('--glow', t[1]);
  },
};

const sceneEls = $$(document, '[data-scene]'), depthEls = $$(document, '[data-depth]'), drift = $$(document, '[data-drift]');
function frame() {
  ticking = false;
  const vh = innerHeight;
  for (const el of sceneEls) {
    const r = el.getBoundingClientRect();
    scenes[el.dataset.scene](clamp(-r.top / Math.max(1, r.height - vh)), el);
  }
  for (const el of depthEls) {
    const r = el.parentElement.getBoundingClientRect();   // the parent, so our own transform doesn't feed back
    const d = clamp(r.top + r.height / 2 - vh / 2, -vh, vh);   // only near the viewport, so nothing drifts into a neighbouring section
    el.style.transform = `translate3d(0, ${d * -el.dataset.depth}px, 0)`;
  }
  for (const el of drift) el.style.transform = `translate3d(${(el.parentElement.getBoundingClientRect().top - vh) * el.dataset.drift}px, 0, 0)`;
}
let ticking = false;
const request = () => { if (!ticking) { ticking = true; requestAnimationFrame(frame); } };
if (!reduce) {
  addEventListener('scroll', request, { passive: true });
  addEventListener('resize', request);
  frame();
}
