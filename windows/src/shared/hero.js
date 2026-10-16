// Hero renderer: a port of the macOS HeroRig.swift + Heroes.swift.
//
// Coordinate contract for Renderer.draw(ctx, look, pose):
//   the caller must already have set a transform where the origin is the center between the
//   hero's feet and y points UP (e.g. ctx.translate(feetX, feetY); ctx.scale(s, -s)).
//   The hero is about Renderer.height (250) units tall and faces right; flip x to face left.
//
// Looks are plain JSON objects with the same fields as the Swift HeroLook; colors are "#RRGGBB".
// Loaded as a plain <script>; everything is exposed on globalThis.Hero.
(function () {
    'use strict';

    const PI = Math.PI;
    const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

    // MARK: - Colors

    const parsed = new Map();
    function rgb(c) {
        if (Array.isArray(c)) return c;
        let v = parsed.get(c);
        if (!v) {
            const n = parseInt(String(c).replace('#', ''), 16) || 0;
            v = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
            parsed.set(c, v);
        }
        return v;
    }
    function scaled(c, f) {
        const [r, g, b] = rgb(c);
        const k = (v) => clamp(Math.round(v * f), 0, 255);
        return [k(r), k(g), k(b)];
    }
    function css(c, a = 1) {
        const [r, g, b] = rgb(c);
        return a >= 1 ? `rgb(${r},${g},${b})` : `rgba(${r},${g},${b},${a})`;
    }
    /// Blends toward `other` by `t` (0 = c, 1 = other).
    function mixed(c, other, t) {
        const a = rgb(c), b = rgb(other);
        return a.map((v, i) => Math.round(v * (1 - t) + b[i] * t));
    }
    function hex(c) {
        return '#' + rgb(c).map((v) => v.toString(16).padStart(2, '0')).join('').toUpperCase();
    }

    // MARK: - Paths

    /// A recorded path: builds a Path2D and tracks its bounding box (control points included, like CGPath.boundingBox).
    class P {
        constructor() {
            this.ops = [];
            this.x0 = Infinity; this.y0 = Infinity; this.x1 = -Infinity; this.y1 = -Infinity;
            this._p = null;
        }
        _b(x, y) {
            if (x < this.x0) this.x0 = x;
            if (y < this.y0) this.y0 = y;
            if (x > this.x1) this.x1 = x;
            if (y > this.y1) this.y1 = y;
        }
        M(x, y) { this.ops.push(['M', x, y]); this._b(x, y); return this; }
        L(x, y) { this.ops.push(['L', x, y]); this._b(x, y); return this; }
        Q(cx, cy, x, y) { this.ops.push(['Q', cx, cy, x, y]); this._b(cx, cy); this._b(x, y); return this; }
        C(ax, ay, bx, by, x, y) { this.ops.push(['C', ax, ay, bx, by, x, y]); this._b(ax, ay); this._b(bx, by); this._b(x, y); return this; }
        A(cx, cy, r, a0, a1, ccw = false) { this.ops.push(['A', cx, cy, r, a0, a1, ccw]); this._b(cx - r, cy - r); this._b(cx + r, cy + r); return this; }
        T(x1, y1, x2, y2, r) { this.ops.push(['T', x1, y1, x2, y2, r]); this._b(x1, y1); return this; }
        E(cx, cy, rx, ry) { this.ops.push(['E', cx, cy, rx, ry]); this._b(cx - rx, cy - ry); this._b(cx + rx, cy + ry); return this; }
        R(x, y, w, h, r) { this.ops.push(['R', x, y, w, h, r]); this._b(x, y); this._b(x + w, y + h); return this; }
        Z() { this.ops.push(['Z']); return this; }

        get path() {
            if (this._p) return this._p;
            const p = new Path2D();
            for (const o of this.ops) {
                switch (o[0]) {
                    case 'M': p.moveTo(o[1], o[2]); break;
                    case 'L': p.lineTo(o[1], o[2]); break;
                    case 'Q': p.quadraticCurveTo(o[1], o[2], o[3], o[4]); break;
                    case 'C': p.bezierCurveTo(o[1], o[2], o[3], o[4], o[5], o[6]); break;
                    case 'A': p.arc(o[1], o[2], o[3], o[4], o[5], o[6]); break;
                    case 'T': p.arcTo(o[1], o[2], o[3], o[4], o[5]); break;
                    case 'E': p.moveTo(o[1] + o[3], o[2]); p.ellipse(o[1], o[2], o[3], o[4], 0, 0, 2 * PI); p.closePath(); break;
                    case 'R': p.roundRect(o[1], o[2], o[3], o[4], o[5]); break;
                    case 'Z': p.closePath(); break;
                }
            }
            this._p = p;
            return p;
        }

        get bounds() {
            const w = this.x1 - this.x0, h = this.y1 - this.y0;
            return { x: this.x0, y: this.y0, w, h, maxX: this.x1, maxY: this.y1, midX: this.x0 + w / 2, midY: this.y0 + h / 2 };
        }

        translated(dx, dy) {
            const q = new P();
            for (const o of this.ops) {
                switch (o[0]) {
                    case 'M': q.M(o[1] + dx, o[2] + dy); break;
                    case 'L': q.L(o[1] + dx, o[2] + dy); break;
                    case 'Q': q.Q(o[1] + dx, o[2] + dy, o[3] + dx, o[4] + dy); break;
                    case 'C': q.C(o[1] + dx, o[2] + dy, o[3] + dx, o[4] + dy, o[5] + dx, o[6] + dy); break;
                    case 'A': q.A(o[1] + dx, o[2] + dy, o[3], o[4], o[5], o[6]); break;
                    case 'T': q.T(o[1] + dx, o[2] + dy, o[3] + dx, o[4] + dy, o[5]); break;
                    case 'E': q.E(o[1] + dx, o[2] + dy, o[3], o[4]); break;
                    case 'R': q.R(o[1] + dx, o[2] + dy, o[3], o[4], o[5]); break;
                    case 'Z': q.Z(); break;
                }
            }
            return q;
        }
    }

    /// CGPath(ellipseIn:) equivalent.
    const ell = (x, y, w, h) => new P().E(x + w / 2, y + h / 2, w / 2, h / 2);
    /// CGPath(roundedRect:) equivalent.
    const rrect = (x, y, w, h, r) => new P().R(x, y, w, h, Math.min(r, w / 2, h / 2));

    function roundedPoly(pts, r) {
        const p = new P();
        const n = pts.length;
        p.M((pts[n - 1][0] + pts[0][0]) / 2, (pts[n - 1][1] + pts[0][1]) / 2);
        for (let i = 0; i < n; i++) {
            const a = pts[i], b = pts[(i + 1) % n];
            p.T(a[0], a[1], b[0], b[1], Math.max(0, r));
        }
        p.Z();
        return p;
    }

    // MARK: - HeroLook model

    const Hair = ['short', 'long', 'spiky', 'bun', 'ponytail', 'curly', 'bald'];
    const Mask = ['none', 'domino', 'shades', 'cowl', 'helmet', 'armor', 'fullface'];
    const Ears = ['none', 'pointy', 'cat', 'antenna'];
    const Emblem = ['none', 'star', 'bolt', 'drop', 'circle', 'diamond', 'heart', 'core', 'spider'];
    const Outfit = ['bodysuit', 'tux', 'bare', 'armor'];
    const Build = ['regular', 'big'];
    const Attitude = ['cheerful', 'stoic', 'fierce'];
    const Figure = ['masculine', 'feminine'];

    const h6 = (n) => '#' + n.toString(16).padStart(6, '0').toUpperCase();

    function make(id, name, tagline, voice, o) {
        return {
            id, name, tagline, voice,
            skin: h6(o.skin), hair: h6(o.hair), hairStyle: o.hairStyle,
            suit: h6(o.suit), accent: h6(o.accent), pants: h6(o.pants), boots: h6(o.boots), gloves: h6(o.gloves),
            belt: o.belt ?? true, cape: o.cape != null ? h6(o.cape) : null,
            mask: o.mask ?? 'none', maskColor: h6(o.maskColor ?? 0x222222), ears: o.ears ?? 'none',
            emblem: o.emblem ?? 'none', emblemColor: h6(o.emblemColor ?? 0xFFFFFF), glasses: o.glasses ?? false,
            cup: h6(o.cup ?? 0x4CAE4F),
            outfit: o.outfit ?? 'bodysuit', build: o.build ?? 'regular', beard: o.beard ?? false, attitude: o.attitude ?? 'cheerful',
            figure: 'masculine',
        };
    }

    /// Original characters (no franchise names or logos), each with its own look and voice.
    const heroes = [
        make('ironclad', 'Ironclad', 'Hydration systems: online. ⚙️', "cocky, witty genius inventor; calls water 'coolant' and every sip a 'system upgrade'",
            { skin: 0xE8B894, hair: 0x2A1E18, hairStyle: 'short', suit: 0xB01E28, accent: 0xE0A93A,
              pants: 0xE0A93A, boots: 0xB01E28, gloves: 0xB01E28, belt: false, mask: 'armor', maskColor: 0xB01E28,
              emblem: 'core', emblemColor: 0x9FF3FF, cup: 0xC9CED6, outfit: 'armor' }),
        make('sterling', 'Mr. Sterling', "He's back. And he's thirsty.", 'stoic retired professional; very short, deadly serious sentences; treats hydration like a sacred contract; sometimes mentions his dog',
            { skin: 0xE6BFA0, hair: 0x1A1614, hairStyle: 'long', suit: 0x17181D, accent: 0x0C0C0E,
              pants: 0x17181D, boots: 0x0C0C0E, gloves: 0xE6BFA0, belt: false, cup: 0x9FD8F5,
              outfit: 'tux', beard: true, attitude: 'stoic' }),
        make('skyline', 'Skyline', 'Swinging by to remind you to drink!', 'quippy, upbeat teen hero who cracks jokes nonstop',
            { skin: 0xF2C6A0, hair: 0x3A2A1A, hairStyle: 'short', suit: 0xD62C2C, accent: 0x2347A8,
              pants: 0x2347A8, boots: 0xD62C2C, gloves: 0xD62C2C, belt: false, mask: 'fullface', maskColor: 0xD62C2C,
              emblem: 'spider', emblemColor: 0x141414, cup: 0xD62C2C }),
        make('brawn', 'Brawn', 'BRAWN SMASH… THIRST.', 'huge gentle giant who talks in short ALL-CAPS smash sentences but is secretly very sweet',
            { skin: 0x6DBE45, hair: 0x1B1B1B, hairStyle: 'spiky', suit: 0x6DBE45, accent: 0x6A3D9A,
              pants: 0x6A3D9A, boots: 0x6DBE45, gloves: 0x6DBE45, belt: false, cup: 0x6A3D9A,
              outfit: 'bare', build: 'big', attitude: 'fierce' }),
        make('pixel', 'Pixel', 'Your cozy desk sidekick', 'warm, upbeat, a little goofy',
            { skin: 0xF2C6A0, hair: 0x5A3A2A, hairStyle: 'long', suit: 0x2D2D38, accent: 0xF0F0F0,
              pants: 0x23232B, boots: 0x5A3222, gloves: 0xF2C6A0, belt: false, glasses: true }),
        make('hydro', 'Captain Hydro', 'Defender of the daily 8 glasses!', 'booming heroic announcer who treats every sip like saving the city',
            { skin: 0xC68A5E, hair: 0xF4D06F, hairStyle: 'short', suit: 0x2F6FDE, accent: 0xD93A3A,
              pants: 0x2F6FDE, boots: 0xD93A3A, gloves: 0xF4F4F4, cape: 0xD93A3A, mask: 'domino', maskColor: 0x1E3F8A,
              emblem: 'drop', emblemColor: 0xFFFFFF, cup: 0x9FD8F5 }),
        make('volt', 'Volt', 'Charged up and ready to hydrate ⚡', 'hyper, talks fast, loves puns about energy',
            { skin: 0xFFD9B8, hair: 0x1B1B1B, hairStyle: 'spiky', suit: 0xF4C430, accent: 0x1B1B1B,
              pants: 0x1B1B1B, boots: 0xF4C430, gloves: 0x1B1B1B, emblem: 'bolt', emblemColor: 0x1B1B1B, cup: 0xF4C430 }),
        make('owl', 'Night Owl', 'Watches over your late-night coding 🌙', 'dry, mysterious, speaks in short moody lines with secret warmth',
            { skin: 0xE0B48C, hair: 0x1B1B1B, hairStyle: 'short', suit: 0x5B4E9E, accent: 0x7FE0D0,
              pants: 0x2E2A5A, boots: 0x7FE0D0, gloves: 0x2E2A5A, cape: 0x3A3470, mask: 'cowl', maskColor: 0x2E2A5A,
              ears: 'cat', emblem: 'circle', emblemColor: 0xE8E4FF, cup: 0x7FE0D0 }),
        make('comet', 'Crimson Comet', 'Fastest hydration in the galaxy', 'cocky space racer, competitive, counts everything as a lap record',
            { skin: 0x8D5A3B, hair: 0x1B1B1B, hairStyle: 'bald', suit: 0xC8323C, accent: 0xF2C230,
              pants: 0xC8323C, boots: 0xF2C230, gloves: 0xF2C230, mask: 'helmet', maskColor: 0xC8323C,
              emblem: 'star', emblemColor: 0xF2C230, cup: 0xF2C230 }),
        make('frost', 'Frost', 'Cool, calm and very hydrated ❄️', 'serene and elegant, speaks softly like falling snow',
            { skin: 0xF7DCCB, hair: 0xDDEEFF, hairStyle: 'long', suit: 0xE8F4FF, accent: 0x6CB8F0,
              pants: 0x6CB8F0, boots: 0xE8F4FF, gloves: 0x6CB8F0, cape: 0x9FD3F7, emblem: 'diamond', emblemColor: 0x3A8FD9,
              cup: 0x9FD3F7 }),
        make('cat', 'Shadow Cat', 'Sneaks up when you forget to drink', 'smug feline thief, playful, occasionally says nya',
            { skin: 0xFFE0C2, hair: 0x2B1E3A, hairStyle: 'ponytail', suit: 0x1E1A24, accent: 0x9B59D0,
              pants: 0x1E1A24, boots: 0x9B59D0, gloves: 0x9B59D0, mask: 'domino', maskColor: 0x9B59D0, ears: 'cat',
              emblem: 'heart', emblemColor: 0x9B59D0, cup: 0x9B59D0 }),
        make('astro', 'Astro', 'Mission control says: drink water', 'cheerful astronaut using mission-control jargon',
            { skin: 0xD9A07A, hair: 0x3A2A1A, hairStyle: 'bald', suit: 0xF2F2F2, accent: 0xF28C28,
              pants: 0xF2F2F2, boots: 0x8A8F99, gloves: 0xF28C28, mask: 'helmet', maskColor: 0xF2F2F2, ears: 'antenna',
              emblem: 'star', emblemColor: 0xF28C28, cup: 0xF28C28 }),
        make('ember', 'Ember', 'Hot-headed, but stays hydrated 🔥', 'fiery, dramatic, overreacts to everything',
            { skin: 0xFFD2B0, hair: 0xF2582A, hairStyle: 'spiky', suit: 0x33303A, accent: 0xF28C28,
              pants: 0x33303A, boots: 0xF2582A, gloves: 0xF28C28, cape: 0xF2582A, emblem: 'diamond', emblemColor: 0xF28C28,
              cup: 0xF2582A }),
        make('sprout', 'Sprout', 'A tiny plant parent who needs water too 🌱', 'gentle, wholesome, compares everything to plants',
            { skin: 0x6B4430, hair: 0x2A1A12, hairStyle: 'bun', suit: 0x5DAA68, accent: 0xF7E6B5,
              pants: 0x3E5C8A, boots: 0xF7E6B5, gloves: 0x6B4430, belt: false, cup: 0x5DAA68 }),
        make('ninja', 'Hush', 'Silent. Swift. Sipping.', 'a quiet ninja of few words, speaks in haiku-like fragments',
            { skin: 0xF0C8A0, hair: 0x1B1B1B, hairStyle: 'ponytail', suit: 0x2E3440, accent: 0xC8323C,
              pants: 0x2E3440, boots: 0x1B1B1B, gloves: 0x2E3440, mask: 'shades', maskColor: 0x1B1B1B,
              emblem: 'none', cup: 0xC8323C }),
    ];

    /// A heroine for every hero: same costume and powers, her own name, voice and hair.
    function her(heroID, name, tagline, voice, o = {}) {
        const l = Object.assign({}, heroes.find((h) => h.id === heroID));
        l.id = heroID + '-her';
        l.name = name; l.tagline = tagline; l.voice = voice;
        l.figure = 'feminine';
        l.beard = false;
        if (o.hair) l.hairStyle = o.hair;
        if (o.hairColor != null) l.hair = h6(o.hairColor);
        return l;
    }

    const heroines = [
        her('ironclad', 'Alloy', 'Hydration protocols: engaged. ✨', "brilliant, confident engineer; calls water 'coolant' and every sip an 'efficiency upgrade'",
            { hair: 'ponytail', hairColor: 0x7A3B1E }),
        her('sterling', 'Ms. Sterling', "She's back. And she's thirsty.", 'stoic retired professional; very short, deadly serious sentences; treats hydration like a sacred contract; sometimes mentions her cat',
            { hair: 'long' }),
        her('skyline', 'Skyla', 'Swinging in with your water break!', 'quippy, upbeat teen hero who cracks jokes nonstop',
            { hair: 'ponytail', hairColor: 0xE8C77A }),
        her('brawn', 'Jade', 'JADE SMASH… THIRST.', 'mighty gentle giant who talks in short ALL-CAPS smash sentences but is secretly very sweet',
            { hair: 'long' }),
        her('pixel', 'Pixie', 'Your cozy desk sidekick', 'warm, upbeat, a little goofy', { hair: 'bun' }),
        her('hydro', 'Captain Marina', 'Defender of the daily 8 glasses!', 'booming heroic announcer who treats every sip like saving the city',
            { hair: 'long' }),
        her('volt', 'Volta', 'Charged up and ready to hydrate ⚡', 'hyper, talks fast, loves puns about energy', { hair: 'ponytail' }),
        her('owl', 'Nightingale', 'Watches over your late-night coding 🌙', 'dry, mysterious, speaks in short moody lines with secret warmth',
            { hair: 'ponytail' }),
        her('comet', 'Scarlet Comet', 'Fastest hydration in the galaxy', 'cocky space racer, competitive, counts everything as a lap record'),
        her('frost', 'Flurry', 'Cool, calm and very hydrated ❄️', 'serene and elegant, speaks softly like falling snow'),
        her('cat', 'Velvet', 'Sneaks up when you forget to drink', 'smug feline thief, playful, occasionally says nya'),
        her('astro', 'Astra', 'Mission control says: drink water', 'cheerful astronaut using mission-control jargon'),
        her('ember', 'Blaze', 'Hot-headed, but stays hydrated 🔥', 'fiery, dramatic, overreacts to everything', { hair: 'long' }),
        her('sprout', 'Blossom', 'A tiny plant parent who needs water too 🌸', 'gentle, wholesome, compares everything to plants', { hair: 'curly' }),
        her('ninja', 'Whisper', 'Silent. Swift. Sipping.', 'a quiet ninja of few words, speaks in haiku-like fragments'),
    ];

    const presets = heroes.concat(heroines);

    const preset = (id) => presets.find((p) => p.id === id) || null;

    /// Fills in optional fields so looks saved by older versions still render.
    function normalize(look) {
        const l = Object.assign({ outfit: 'bodysuit', build: 'regular', beard: false, attitude: 'cheerful', cape: null, figure: 'masculine' }, look);
        if (l.figure == null) l.figure = 'masculine';
        return l;
    }

    /// Same text descriptions the Mac app sends to the AI.
    function appearance(look) {
        const parts = [`${look.hairStyle} ${look.hair} hair`, `${look.suit} suit with ${look.accent} accents`];
        if (look.cape) parts.push(`${look.cape} cape`);
        if (look.mask !== 'none') parts.push(`${look.maskColor} ${look.mask}`);
        if (look.emblem !== 'none') parts.push(`${look.emblem} chest emblem`);
        if (look.ears !== 'none') parts.push(`${look.ears} ears`);
        if (look.glasses) parts.push('glasses');
        return parts.join(', ');
    }

    // MARK: - Skeleton

    /// Heroic proportions (head ≈ 1/5 of height). Units: feet on y = 0, about 250 tall, facing right (3/4 view).
    const Rig = {
        height: 250,
        shoulder: { x: 46, y: 183 },
        upperArm: 40,
        foreArm: 37,
        hip: { x: 15, y: 114 },
        thigh: 54,
        shin: 50,
        head: { x: 2, y: 224 },
        mouth: { x: 6, y: 212 },

        /// Shoulder and elbow angles that put the right fist at `target` (two-bone IK, elbow pointing out).
        /// Arm convention: 0 = hanging down, + = rotated outward; elbow + = forearm folds inward/up.
        reachRight(target, drop = 0) {
            const s = { x: Rig.shoulder.x, y: Rig.shoulder.y - drop };
            const v = { x: target.x - s.x, y: target.y - s.y };
            const u = Rig.upperArm, f = Rig.foreArm;
            const d = Math.min(u + f - 0.5, Math.max(10, Math.hypot(v.x, v.y)));
            const phi = Math.atan2(v.x, -v.y);
            const alpha = Math.acos(Math.min(1, (u * u + d * d - f * f) / (2 * u * d)));
            const inner = Math.acos(Math.min(1, (u * u + f * f - d * d) / (2 * u * f)));
            return { shoulder: phi + alpha, elbow: PI - inner };
        },
    };

    // MARK: - Pose

    const POSE_DEFAULTS = Object.freeze({
        lift: 0, squash: 1, lean: 0, headTilt: 0,
        armL: 0.12, armR: 0.22, elbowL: 0.2, elbowR: 0.9,
        legL: 0.04, legR: 0.04, kneeL: 0, kneeR: 0,
        sit: 0, eyesOpen: 1, lookX: 0.3, lookY: 0,
        smile: 0.35, mouthOpen: 0, brow: 0,
        capeFlare: 0.2, capeTrail: 0, cupTilt: 0,
        capeWave: 0, // not sprung: continuously advancing phase
    });

    /// Returns a new pose with defaults, optionally overridden.
    function Pose(overrides) { return Object.assign({}, POSE_DEFAULTS, overrides); }
    Pose.defaults = POSE_DEFAULTS;

    /// [field, stiffness, damping ratio]
    Pose.sprung = [
        ['lift', 220, 0.75], ['squash', 320, 0.4], ['lean', 140, 0.6], ['headTilt', 120, 0.55],
        ['armL', 170, 0.62], ['armR', 170, 0.66], ['elbowL', 170, 0.66], ['elbowR', 170, 0.7],
        ['legL', 200, 0.75], ['legR', 200, 0.75], ['kneeL', 240, 0.8], ['kneeR', 240, 0.8],
        ['sit', 60, 0.9], ['eyesOpen', 1400, 1], ['lookX', 50, 0.9], ['lookY', 50, 0.9],
        ['smile', 90, 0.9], ['mouthOpen', 160, 0.8], ['brow', 90, 0.9], ['capeFlare', 60, 0.45],
        ['capeTrail', 50, 0.5], ['cupTilt', 120, 0.7],
    ];

    /// Springs the displayed pose toward a target pose, which is what makes motion feel weighty and alive.
    class PoseAnimator {
        constructor() {
            this.pose = Pose();
            this.velocity = {};
            for (const [k] of Pose.sprung) this.velocity[k] = 0;
        }

        update(target, dt) {
            const steps = Math.max(1, Math.ceil(dt / (1 / 120)));
            const h = dt / steps;
            const pose = this.pose, vel = this.velocity;
            for (let i = 0; i < steps; i++) {
                for (const [kp, k, zeta] of Pose.sprung) {
                    const x = pose[kp], v = vel[kp];
                    const a = k * (target[kp] - x) - 2 * zeta * Math.sqrt(k) * v;
                    vel[kp] = v + a * h;
                    pose[kp] = x + vel[kp] * h;
                }
            }
            pose.capeWave = target.capeWave;
            return pose;
        }

        /// Adds a sudden velocity, e.g. a squash on landing.
        kick(field, amount) { this.velocity[field] += amount; }
    }

    // MARK: - Pose library

    function smooth(x) {
        const c = Math.min(1, Math.max(0, x));
        return c * c * (3 - 2 * c);
    }

    /// Target poses for each behavior. Pure functions of time, shared by the live buddy and previews.
    const PoseLibrary = {
        drinkDuration: 2.4,
        cheerDuration: 1.4,

        blinking(t) {
            const cycle = t % 4.3;
            return cycle < 0.13 || (cycle > 2.1 && cycle < 2.2 && Math.trunc(t / 4.3) % 3 === 0);
        },

        idle(t) {
            const p = Pose();
            const breath = Math.sin(t * 2.0);
            p.squash = 1 + 0.012 * breath;
            p.lean = 0.015 * Math.sin(t * 0.8);
            p.headTilt = 0.04 * Math.sin(t * 0.65);
            p.armL = 0.12 + 0.02 * breath;
            p.armR = 0.2 + 0.02 * breath;
            p.eyesOpen = PoseLibrary.blinking(t) ? 0 : 1;
            p.capeWave = t * 1.6;
            p.capeFlare = 0.15;
            return p;
        },

        walk(phase, t) {
            const p = PoseLibrary.idle(t);
            const s = Math.sin(phase);
            p.kneeL = Math.max(0, s) * 0.9;
            p.kneeR = Math.max(0, -s) * 0.9;
            p.legL = 0.04 + 0.08 * s;
            p.legR = 0.04 - 0.08 * s;
            p.lean = 0.05;
            p.lift = Math.abs(s) * 4;
            p.armL = 0.15 - 0.22 * s;
            p.elbowL = 0.35 + 0.2 * Math.max(0, s);
            p.armR = 0.22 + 0.12 * s;
            p.headTilt = -0.03 * s;
            p.capeTrail = 1;
            p.capeFlare = 0.6;
            p.capeWave = t * 6;
            p.smile = 0.4;
            return p;
        },

        remind(t) {
            const p = PoseLibrary.idle(t);
            const c = t % 1.3;
            p.lift = c < 0.4 ? Math.sin(c / 0.4 * PI) * 30 : 0;
            p.kneeL = c < 0.4 ? 0.5 : 0;
            p.kneeR = c < 0.4 ? 0.5 : 0;
            p.armL = 2.55;
            p.elbowL = 0.35 + 0.45 * Math.sin(t * 10);   // waving
            p.armR = 0.9;
            p.elbowR = 1.3;                               // showing the cup
            p.brow = 0.6;
            p.smile = 0.5;
            p.mouthOpen = 0.4;
            p.capeFlare = 0.7;
            p.capeWave = t * 5;
            return p;
        },

        drink(local, t) {
            const p = PoseLibrary.idle(t);
            const raise = smooth(local / 0.45);
            const lower = smooth((local - 1.8) / 0.4);
            const up = raise * (1 - lower);
            const toMouth = Rig.reachRight({ x: Rig.mouth.x + 6, y: Rig.mouth.y - 14 });
            p.armR = 0.2 + (toMouth.shoulder - 0.2) * up;
            p.elbowR = 0.9 + (toMouth.elbow - 0.9) * up;
            p.cupTilt = up * 0.9;
            p.headTilt = -0.2 * up;
            p.eyesOpen = up > 0.6 ? 0 : 1;
            p.smile = up > 0.6 ? 0.2 : 0.5;
            if (local > 0.5 && local < 1.8) p.squash = 1 + 0.012 * Math.sin(local * 14);   // gulp
            if (local > 1.8) {
                p.mouthOpen = 0.35;
                p.smile = 0.9;
                p.eyesOpen = 0;
            }
            return p;
        },

        cheer(local, t) {
            const p = PoseLibrary.idle(t);
            p.smile = 0.9;
            p.eyesOpen = 0;
            p.mouthOpen = 0.5;
            p.capeFlare = 1;
            p.capeWave = t * 7;
            if (local < 0.25) {                       // anticipation crouch
                p.squash = 0.94;
                p.kneeL = 0.5; p.kneeR = 0.5;
                p.armL = 0.5; p.armR = 0.6;
                p.elbowL = 0.8; p.elbowR = 1.0;
            } else if (local < 0.85) {                // jump, fists up
                const j = (local - 0.25) / 0.6;
                p.lift = Math.sin(j * PI) * 60;
                p.squash = 1.03;
                p.armL = 2.45 + 0.1 * Math.sin(t * 16);
                p.armR = 2.45 + 0.1 * Math.sin(t * 16 + 1);
                p.elbowL = 0.15; p.elbowR = 0.15;
                p.kneeL = 0.7; p.kneeR = 0.3;
            } else {                                  // landed, victory pose
                p.armL = 2.3; p.armR = 2.3;
                p.elbowL = 0.3; p.elbowR = 0.3;
            }
            return p;
        },

        sleep(t) {
            const p = Pose();
            p.sit = 1;
            p.eyesOpen = 0;
            p.smile = 0.15;
            p.headTilt = 0.25 + 0.04 * Math.sin(t * 1.3);
            p.squash = 1 + 0.012 * Math.sin(t * 1.3);
            p.armL = 0.45; p.armR = 0.5;
            p.elbowL = 0.5; p.elbowR = 0.6;
            p.legL = 0.55; p.legR = 0.55;
            p.capeWave = t * 0.8;
            return p;
        },

        dangle(t, swing = 0) {
            const p = Pose();
            p.armL = 2.3 + 0.3 * Math.sin(t * 13);
            p.armR = 2.3 + 0.3 * Math.sin(t * 13 + 2);
            p.elbowL = 0.4 + 0.3 * Math.sin(t * 9);
            p.elbowR = 0.4 + 0.3 * Math.sin(t * 9 + 1);
            p.legL = 0.08 + 0.12 * Math.sin(t * 8) + swing;
            p.legR = 0.08 - 0.12 * Math.sin(t * 8) - swing;
            p.kneeL = 0.3 + 0.3 * Math.sin(t * 8);
            p.kneeR = 0.3 - 0.3 * Math.sin(t * 8);
            p.lean = -swing * 0.6;
            p.eyesOpen = 1.1;
            p.brow = 1;
            p.smile = -0.2;
            p.mouthOpen = 0.6;
            p.capeFlare = 1;
            p.capeWave = t * 9;
            return p;
        },

        falling(t) {
            const p = PoseLibrary.dangle(t, 0);
            p.legL = 0.05; p.legR = 0.05;
            p.kneeL = 0.2; p.kneeR = 0.2;
            return p;
        },

        /// anim: 'walk' | 'idle' | 'drink' | 'cheer' | 'sleep'
        preview(anim, t) {
            switch (anim) {
                case 'walk': return PoseLibrary.walk(t * 7.5, t);
                case 'drink': return PoseLibrary.drink(t % (PoseLibrary.drinkDuration + 0.6), t);
                case 'cheer': return PoseLibrary.cheer(t % (PoseLibrary.cheerDuration + 0.5), t);
                case 'sleep': return PoseLibrary.sleep(t);
                default: return PoseLibrary.idle(t);
            }
        },
    };

    // MARK: - Renderer

    const GLOW = [0x9F, 0xF3, 0xFF];
    const INK = '#1C1820';
    /// While drawing armor, fills use the polished-metal material instead of satin.
    let metal = false;

    // Gradient color stops are cached per color (the gradient objects themselves are geometry-bound).
    const satinStops = new Map();
    const metalStops = new Map();
    function stopsFor(cache, c, factors) {
        const key = hex(c);
        let s = cache.get(key);
        if (!s) {
            s = factors.map(([f, at]) => [at, css(scaled(c, f))]);
            cache.set(key, s);
        }
        return s;
    }
    const SATIN = [[1.22, 0], [1.02, 0.4], [0.7, 1]];
    const METAL = [[1.55, 0], [1.12, 0.2], [0.58, 0.5], [0.92, 0.72], [0.45, 1]];

    function linear(ctx, x0, y0, x1, y1, stops) {
        const g = ctx.createLinearGradient(x0, y0, x1, y1);
        for (const [at, c] of stops) g.addColorStop(at, c);
        return g;
    }

    /// Satin finish: side-lit gradient, a soft top sheen and a crisp outline.
    function fill(ctx, path, color, outline = 1.8) {
        if (metal) return metalFill(ctx, path, color, outline);
        const b = path.bounds, p2 = path.path;
        ctx.save();
        ctx.fillStyle = linear(ctx, b.x, b.midY + b.h * 0.15, b.maxX, b.midY - b.h * 0.15, stopsFor(satinStops, color, SATIN));
        ctx.fill(p2);
        // Rim light along the lit edge.
        ctx.clip(p2);
        ctx.lineWidth = 3;
        ctx.translate(1.2, -0.8);
        ctx.strokeStyle = 'rgba(255,255,255,0.18)';
        ctx.stroke(p2);
        ctx.restore();
        if (outline > 0) {
            ctx.strokeStyle = css(scaled(color, 0.35));
            ctx.lineWidth = outline;
            ctx.stroke(p2);
        }
    }

    /// Polished metal: banded reflections, a sharp specular sheen, and a beveled light edge.
    function metalFill(ctx, path, color, outline) {
        const b = path.bounds, p2 = path.path;
        ctx.save();
        ctx.fillStyle = linear(ctx, b.x, b.maxY, b.maxX, b.y, stopsFor(metalStops, color, METAL));
        ctx.fill(p2);
        ctx.clip(p2);
        ctx.save();
        ctx.translate(b.x + b.w * 0.32, b.y + b.h * 0.74);
        ctx.scale(1, 0.55);
        const r = Math.max(2, Math.min(b.w, b.h) * 0.38);
        const spec = ctx.createRadialGradient(0, 0, 0, 0, 0, r);
        spec.addColorStop(0, 'rgba(255,255,255,0.75)');
        spec.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = spec;
        ctx.beginPath(); ctx.arc(0, 0, r, 0, 2 * PI); ctx.fill();
        ctx.restore();
        ctx.lineWidth = 2;
        ctx.translate(0.9, -0.9);
        ctx.strokeStyle = 'rgba(255,255,255,0.35)';
        ctx.stroke(p2);
        ctx.translate(-1.8, 1.8);
        ctx.strokeStyle = 'rgba(0,0,0,0.25)';
        ctx.stroke(p2);
        ctx.restore();
        if (outline > 0) {
            ctx.strokeStyle = css(scaled(color, 0.3));
            ctx.lineWidth = Math.min(outline, 1.6);
            ctx.stroke(p2);
        }
    }

    function solid(ctx, path, style) {
        ctx.fillStyle = style;
        ctx.fill(path.path);
    }

    function line(ctx, pts, style, width) {
        if (!pts.length) return;
        ctx.strokeStyle = style;
        ctx.lineWidth = width;
        ctx.beginPath();
        ctx.moveTo(pts[0][0], pts[0][1]);
        for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
        ctx.stroke();
    }

    /// Soft glow (eyes, core, repulsors, thrusters).
    function glowSpot(ctx, x, y, radius, alpha = 1) {
        const g = ctx.createRadialGradient(x, y, 0, x, y, radius);
        g.addColorStop(0, `rgba(255,255,255,${alpha})`);
        g.addColorStop(0.35, css(GLOW, 0.8 * alpha));
        g.addColorStop(1, css(GLOW, 0));
        ctx.fillStyle = g;
        ctx.beginPath(); ctx.arc(x, y, radius, 0, 2 * PI); ctx.fill();
    }

    function emblemPath(kind, s) {
        switch (kind) {
            case 'core':
            case 'circle':
                return ell(-s, -s * 0.85, s * 2, s * 1.7);
            case 'star': {
                const pts = [];
                for (let i = 0; i < 10; i++) {
                    const a = PI / 2 + i * PI / 5;
                    const r = i % 2 === 0 ? s * 1.1 : s * 0.48;
                    pts.push([Math.cos(a) * r, Math.sin(a) * r]);
                }
                return roundedPoly(pts, 1);
            }
            case 'bolt':
                return roundedPoly([[-0.15, 1.1], [0.55, 1.1], [0.12, 0.2], [0.55, 0.2], [-0.35, -1.15], [-0.05, -0.1], [-0.5, -0.1]]
                    .map(([x, y]) => [x * s, y * s]), 1);
            case 'drop':
                return new P().M(0, s * 1.1)
                    .C(s, 0, s * 0.75, -s * 0.9, 0, -s * 0.9)
                    .C(-s * 0.75, -s * 0.9, -s, 0, 0, s * 1.1).Z();
            case 'diamond':
                return roundedPoly([[0, s * 1.1], [s * 0.8, 0], [0, -s * 1.1], [-s * 0.8, 0]], 1.5);
            case 'heart':
                return new P().M(0, -s)
                    .C(-s * 0.5, -s * 0.45, -s, -s * 0.1, -s, s * 0.35)
                    .C(-s, s * 0.95, -s * 0.15, s, 0, s * 0.55)
                    .C(s * 0.15, s, s, s * 0.95, s, s * 0.35)
                    .C(s, -s * 0.1, s * 0.5, -s * 0.45, 0, -s).Z();
            case 'spider': // body only; legs are stroked in drawEmblem
                return new P().E(0, -s * 0.45, s * 0.28, s * 0.5).E(0, s * 0.34, s * 0.2, s * 0.22);
            default:
                return new P();
        }
    }

    const SPIDER_LEGS = [
        [[0.1, 0.42], [0.55, 0.8], [0.62, 1.2]], [[0.12, 0.32], [0.72, 0.5], [0.9, 0.95]],
        [[0.12, 0.05], [0.72, -0.12], [0.9, -0.62]], [[0.1, -0.08], [0.55, -0.5], [0.62, -1.15]],
    ];

    /// Draws an emblem centered at (x, y). The spider is a body plus stroked legs, outlined as one silhouette.
    function drawEmblem(ctx, kind, s, x, y, color, outline) {
        if (kind !== 'spider') return fill(ctx, emblemPath(kind, s).translated(x, y), color, outline);
        const w = s * 0.13;
        ctx.beginPath();
        for (const leg of SPIDER_LEGS) {
            for (const side of [1, -1]) {
                ctx.moveTo(x + leg[0][0] * s * side, y + leg[0][1] * s);
                for (let i = 1; i < leg.length; i++) ctx.lineTo(x + leg[i][0] * s * side, y + leg[i][1] * s);
            }
        }
        ctx.strokeStyle = css(scaled(color, metal ? 0.3 : 0.35));
        ctx.lineWidth = w + outline;
        ctx.stroke();
        ctx.strokeStyle = css(color);
        ctx.lineWidth = Math.max(0.1, w - outline);
        ctx.stroke();
        fill(ctx, emblemPath(kind, s).translated(x, y), color, outline);
    }

    /// A muscular limb segment: `w0` at the joint, swelling to `wMid`, tapering to `w1`, with rounded ends.
    function segment(length, w0, w1, wMid) {
        const mid = (wMid ?? (w0 + w1) / 2 * 1.12) / 2;
        return new P()
            .M(-w0 / 2, 0)
            .C(-mid * 1.12, -length * 0.25, -mid, -length * 0.7, -w1 / 2, -length)
            .A(0, -length, w1 / 2, PI, 0, false)
            .C(mid, -length * 0.7, mid * 1.12, -length * 0.25, w0 / 2, 0)
            .A(0, 0, w0 / 2, 0, PI, false)
            .Z();
    }

    /// Body proportions: build scales everything; the feminine figure narrows the shoulders and waist,
    /// widens the hips and slims the limbs.
    function Body(look) {
        const feminine = look.figure === 'feminine';
        const b = {
            bw: look.build === 'big' ? 1.25 : 1,
            feminine,
            shoulder: feminine ? 0.84 : 1,
            waist: feminine ? 0.8 : 1,
            hip: feminine ? 1.14 : 1,
            arm: feminine ? 0.74 : 1,
            leg: feminine ? 0.86 : 1,
        };
        b.shoulderX = Rig.shoulder.x * b.bw * b.shoulder;
        return b;
    }

    const coversHead = (mask) => mask === 'cowl' || mask === 'helmet' || mask === 'armor' || mask === 'fullface';

    function draw(ctx, lookIn, pose) {
        const look = normalize(lookIn);
        const p = Object.assign({}, pose);
        switch (look.attitude) {
            case 'stoic': p.brow -= 0.7; p.smile = p.smile * 0.25 - 0.05; break;
            case 'fierce': p.brow -= 1.1; p.smile = p.smile * 0.4 - 0.15; break;
        }
        ctx.save();
        try {
            ctx.lineJoin = 'round';
            ctx.lineCap = 'round';

            // Ground shadow stays on the floor while the body jumps.
            const shadowScale = Math.max(0.35, 1 - p.lift / 160);
            solid(ctx, ell(-40 * shadowScale + 4, -5, 80 * shadowScale, 10), `rgba(0,0,0,${0.2 * shadowScale})`);

            // Body transform: lift, lean around the feet, a little squash & stretch.
            ctx.translate(0, p.lift);
            ctx.rotate(-p.lean);
            const sq = 1 + (p.squash - 1) * 0.5;
            ctx.scale(1 / Math.sqrt(Math.max(0.5, sq)), sq);

            const outfit = look.outfit;
            const body = Body(look);
            const bw = body.bw;
            const drop = 82 * p.sit;
            const hipY = Rig.hip.y - drop;
            const covers = coversHead(look.mask);
            metal = outfit === 'armor';

            // Back layers.
            if (look.cape) drawCape(ctx, look.cape, p, drop);
            if (!covers || (look.hairStyle === 'ponytail' && (look.mask === 'fullface' || look.mask === 'cowl'))) {
                drawBackHair(ctx, look, p, drop);
            }

            // Legs, then pelvis.
            for (const left of [true, false]) drawLeg(ctx, look, p, left, hipY, body);
            const hw = bw * body.hip;
            fill(ctx, roundedPoly([[-29 * hw, hipY - 12], [29 * hw, hipY - 12], [30 * hw, hipY + 14], [-30 * hw, hipY + 14]], 9), look.pants);

            // Torso: broad chest tapering to the waist (an hourglass for the feminine figure).
            const top = 198 - drop;
            const torsoColor = outfit === 'bare' ? look.skin : look.suit;
            const sw = bw * body.shoulder, ww = bw * body.waist;
            fill(ctx, roundedPoly([
                [-27 * hw, hipY + 6], [27 * hw, hipY + 6],
                [31 * ww, hipY + 30], [46 * sw, top - 22], [54 * sw, top - 8], [30 * sw, top + 2],
                [-30 * sw, top + 2], [-54 * sw, top - 8], [-46 * sw, top - 22], [-31 * ww, hipY + 30],
            ], 10), torsoColor);
            switch (outfit) {
                case 'bodysuit': drawSuitLines(ctx, look, top, hipY, body); break;
                case 'tux': drawTux(ctx, look, top, hipY); break;
                case 'bare': drawMuscles(ctx, look, top, hipY, body); break;
                case 'armor': drawArmorChest(ctx, look, top, hipY, body); break;
            }
            if (look.belt && outfit !== 'armor') {
                fill(ctx, rrect(-26 * hw, hipY + 4, 52 * hw, 9, 3), look.accent, 1.2);
                fill(ctx, rrect(-6, hipY + 2.5, 12, 12, 3), scaled(look.accent, 1.15), 1.2);
            }
            if (look.emblem === 'core' && outfit !== 'armor') {
                drawCore(ctx, look.emblemColor, 0, top - 26, 7);
            } else if (look.emblem !== 'none' && look.emblem !== 'core' && outfit !== 'tux') {
                drawEmblem(ctx, look.emblem, look.emblem === 'spider' ? 15 : 10, 0, top - 28, look.emblemColor, 1.4);
            }

            // Neck.
            const neckColor = covers && look.mask !== 'cowl' ? look.maskColor : look.skin;
            const neckW = body.feminine ? 17 : 22;
            fill(ctx, rrect(1 - neckW / 2, top - 4, neckW, 18, 7), neckColor, 1.2);
            if (outfit === 'tux') fill(ctx, rrect(1 - neckW / 2, top - 2, neckW, 7, 3), '#F4F4F4', 1);

            // Arms (a hand raised to the mouth is drawn over the face).
            const crossing = p.elbowR > 1.9 && p.armR > 1.0;
            drawArm(ctx, look, p, true, drop, body);
            if (!crossing) drawArm(ctx, look, p, false, drop, body);
            if (outfit === 'armor') {
                for (const sign of [-1, 1]) {
                    const pw = 36 * body.arm;
                    fill(ctx, ell(sign * body.shoulderX - pw / 2, Rig.shoulder.y - drop - 10, pw, 26 * body.arm), look.suit, 1.6);
                }
            }

            // Head.
            ctx.save();
            ctx.translate(0, top + 4);
            ctx.rotate(-p.headTilt);
            ctx.translate(0, -(198 + 4));
            drawHead(ctx, look, p);
            ctx.restore();

            if (crossing) drawArm(ctx, look, p, false, drop, body);
            if (p.sit > 0.5) drawCup(ctx, look.cup, 52, 0, 0);
        } finally {
            ctx.restore();
            metal = false;
        }
    }

    // MARK: Limbs

    function drawLeg(ctx, look, p, left, hipY, body) {
        const bw = body.bw * body.leg;
        const sign = left ? -1 : 1;
        const hipAngle = left ? p.legL : p.legR;
        const knee = Math.max(0, left ? p.kneeL : p.kneeR);
        const armor = look.outfit === 'armor';
        const legColor = look.outfit === 'bare' ? look.skin : look.pants;
        // Sitting folds the thigh toward the viewer, so it foreshortens.
        const thighLen = Rig.thigh * (1 - 0.72 * p.sit);
        ctx.save();
        ctx.translate(sign * Rig.hip.x * body.bw * body.hip, hipY);
        ctx.rotate(sign * hipAngle);
        // The feminine thigh is full at the hip and tapers to a slim knee.
        fill(ctx, body.feminine ? segment(thighLen, 31 * bw, 17 * bw, 31 * bw)
                                : segment(thighLen, 28 * bw, 19 * bw, 31 * bw), legColor);
        ctx.translate(0, -thighLen);
        // Knee: the shin swings back and up when bent.
        ctx.rotate(-sign * hipAngle + knee * 0.55);
        const shinLen = Rig.shin * (1 - 0.18 * knee);
        fill(ctx, body.feminine ? segment(shinLen, 17 * bw, 11 * bw, 20 * bw)
                                : segment(shinLen, 19 * bw, 13 * bw, 23 * bw), armor ? look.boots : scaled(legColor, 0.97));
        if (armor) fill(ctx, ell(-8, -6, 16, 12), scaled(look.boots, 1.08), 1.4);
        ctx.translate(0, -shinLen);
        ctx.rotate(-knee * 0.55);
        if (armor && p.lift > 16) {
            // Boot thrusters fire while airborne.
            const flame = Math.min(50, 12 + p.lift * 0.6);
            ctx.save();
            ctx.translate(4, -8);
            ctx.scale(0.4, 1);
            glowSpot(ctx, 0, -flame * 0.35, flame);
            ctx.restore();
        }
        const boot = roundedPoly([[-9 * bw, 14], [9 * bw, 14], [11 * bw, 2], [25 * bw, -1], [27 * bw, -7], [-11 * bw, -7]], 4);
        fill(ctx, boot, look.boots, 1.6);
        ctx.restore();
    }

    function drawArm(ctx, look, p, left, drop, body) {
        const bw = body.bw * body.arm;
        const sign = left ? -1 : 1;
        const shoulder = left ? p.armL : p.armR;
        const elbow = left ? p.elbowL : p.elbowR;
        const sleeve = look.outfit === 'bare' ? look.skin : look.suit;
        const armor = look.outfit === 'armor';
        ctx.save();
        ctx.translate(sign * body.shoulderX, Rig.shoulder.y - drop);
        ctx.rotate(sign * shoulder);
        // Deltoid + upper arm.
        fill(ctx, segment(Rig.upperArm, 25 * bw, 17 * bw, 26 * bw), scaled(sleeve, 0.96));
        if (armor) fill(ctx, rrect(-8 * bw, -20, 16 * bw, 9, 3), look.accent, 1.2);
        // Forearm.
        ctx.translate(0, -Rig.upperArm);
        ctx.rotate(-sign * elbow);
        const forearmColor = look.outfit === 'tux' ? scaled(look.suit, 0.92) : sleeve;
        fill(ctx, segment(Rig.foreArm, 18 * bw, 13 * bw, 21 * bw), forearmColor);
        if (look.outfit === 'tux') fill(ctx, rrect(-6.5, -Rig.foreArm - 2, 13, 6, 2), '#F4F4F4', 1);
        // Fist.
        ctx.translate(0, -Rig.foreArm - 6);
        const worldAngle = shoulder - elbow;
        if (armor && worldAngle > 1.4) glowSpot(ctx, 0, -6, 20, 0.9);   // repulsor
        const handColor = look.outfit === 'tux' || look.outfit === 'bare' ? look.skin : look.gloves;
        fill(ctx, rrect(-9.5 * bw, -11 * bw, 19 * bw, 19 * bw, 7), handColor, 1.4);
        line(ctx, [[-6 * bw, -1], [6 * bw, -1]], css(scaled(handColor, 0.45), 0.5), 1);
        if (!left && p.sit < 0.5) {
            // Keep the cup upright in the hand, then tilt it toward the mouth.
            ctx.rotate(-sign * worldAngle);
            drawCup(ctx, look.cup, 0, -2, p.cupTilt);
        }
        ctx.restore();
    }

    function drawCup(ctx, color, x, y, tilt) {
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(tilt);
        fill(ctx, new P().M(-7.5, 20).L(7.5, 20).L(5.5, -1).L(-5.5, -1).Z(), color, 1.3);
        fill(ctx, ell(-6.5, 16.5, 13, 5), '#A8E1FF', 1);
        ctx.fillStyle = 'rgba(255,255,255,0.5)';
        ctx.fillRect(-4.5, 2, 2, 13);
        ctx.restore();
    }

    function drawCape(ctx, color, p, drop) {
        const top = 196 - drop;
        const bottom = 8 + 20 * p.sit;
        const spread = 46 + 32 * p.capeFlare;
        const trail = -30 * p.capeTrail;
        const w = p.capeWave;
        const path = new P().M(-36, top)
            .C(-50, top - 60, -spread + trail, bottom + 60, -spread + trail + 4 * Math.sin(w), bottom + 10);
        const points = 5;
        for (let i = 1; i <= points; i++) {
            const f = i / points;
            const x = -spread + 2 * spread * f + trail * (1 - f * 0.5) + 4 * Math.sin(w + i);
            path.Q(x - spread / points, bottom - 4, x, bottom + 10 + 3 * Math.sin(w * 1.3 + i));
        }
        path.C(spread + trail * 0.5, bottom + 60, 50, top - 60, 36, top).Z();
        fill(ctx, path, scaled(color, 0.8));
        ctx.strokeStyle = css(scaled(color, 0.5), 0.4);
        ctx.lineWidth = 1.6;
        ctx.beginPath();
        for (const f of [-0.5, 0, 0.5]) {
            ctx.moveTo(f * 30, top - 12);
            ctx.quadraticCurveTo(f * 46 + trail * 0.3, (top + bottom) / 2, f * spread + trail * 0.7 + 3 * Math.sin(w + f * 3), bottom + 14);
        }
        ctx.stroke();
    }

    // MARK: Torso details

    function drawSuitLines(ctx, look, top, hipY, body) {
        // Muscle definition through the suit, plus side panels in the accent color.
        const hw = body.bw * body.waist, sw = body.bw * body.shoulder;
        for (const sign of [-1, 1]) {
            const panel = roundedPoly([[sign * 24 * hw, hipY + 8], [sign * 30 * hw, hipY + 8],
                [sign * 44 * sw, top - 26], [sign * 38 * sw, top - 28]], 2);
            fill(ctx, panel, scaled(look.accent, 0.95), 0);
        }
        ctx.strokeStyle = css(scaled(look.suit, 0.55), 0.5);
        ctx.lineWidth = 1.4;
        ctx.beginPath();
        if (body.feminine) {
            drawBustLines(ctx, top, sw);
        } else {
            for (const sign of [-1, 1]) {
                ctx.moveTo(sign * 2, top - 30);
                ctx.quadraticCurveTo(sign * 20 * sw, top - 38, sign * 34 * sw, top - 26);
            }
        }
        ctx.moveTo(0, top - 32); ctx.lineTo(0, hipY + 16);
        ctx.stroke();
    }

    /// Two soft curves suggesting the chest's shape under the suit (stroked by the caller).
    function drawBustLines(ctx, top, sw) {
        for (const sign of [-1, 1]) {
            ctx.moveTo(sign * 5, top - 31);
            ctx.quadraticCurveTo(sign * 15 * sw, top - 42, sign * 30 * sw, top - 25);
        }
    }

    function drawTux(ctx, look, top, hipY) {
        fill(ctx, roundedPoly([[-12, top], [12, top], [0, top - 50]], 2), '#F4F4F4', 1.2);
        fill(ctx, roundedPoly([[-3, top - 2], [3, top - 2], [4.5, top - 40], [0, top - 46], [-4.5, top - 40]], 1), look.accent, 1);
        for (const sign of [-1, 1]) {
            const lapel = roundedPoly([[sign * 13, top], [sign * 26, top - 4], [sign * 14, top - 26], [sign * 2, top - 52]], 2);
            fill(ctx, lapel, scaled(look.suit, 0.75), 1);
        }
        ctx.fillStyle = css(scaled(look.suit, 0.5));
        for (const y of [top - 62, top - 74]) { ctx.beginPath(); ctx.arc(0, y + 2, 2, 0, 2 * PI); ctx.fill(); }
        // Pocket square.
        fill(ctx, roundedPoly([[-30, top - 32], [-20, top - 32], [-22, top - 27]], 1), '#E8E8E8', 0.8);
    }

    function drawMuscles(ctx, look, top, hipY, body) {
        const skin = look.skin;
        const bw = body.bw * body.waist, sw = body.bw * body.shoulder;
        ctx.strokeStyle = css(scaled(skin, 0.55), 0.55);
        ctx.lineWidth = 1.8;
        ctx.beginPath();
        if (body.feminine) {
            // Toned abs below an athletic top in the accent color.
            ctx.moveTo(0, top - 62); ctx.lineTo(0, hipY + 12);
            for (let y = top - 70; y > hipY + 14; y -= 11) {
                ctx.moveTo(-10 * bw, y); ctx.quadraticCurveTo(0, y - 2.5, 10 * bw, y);
            }
            ctx.stroke();
            const topPath = roundedPoly([[-40 * sw, top - 14], [-26 * sw, top - 2], [-10, top - 12],
                [10, top - 12], [26 * sw, top - 2], [40 * sw, top - 14],
                [36 * sw, top - 42], [-36 * sw, top - 42]], 6);
            fill(ctx, topPath, look.accent, 1.4);
            ctx.strokeStyle = css(scaled(look.accent, 0.55), 0.6);
            ctx.lineWidth = 1.4;
            ctx.beginPath();
            drawBustLines(ctx, top, sw);
            ctx.stroke();
            return;
        }
        for (const sign of [-1, 1]) {
            ctx.moveTo(sign * 2, top - 32);
            ctx.quadraticCurveTo(sign * 22 * sw, top - 44, sign * 40 * sw, top - 24);
            ctx.moveTo(sign * 26 * bw, hipY + 8);
            ctx.quadraticCurveTo(sign * 26 * sw, top - 50, sign * 38 * sw, top - 38);
        }
        ctx.moveTo(0, top - 34); ctx.lineTo(0, hipY + 12);
        for (let y = top - 50; y > hipY + 14; y -= 11) {
            ctx.moveTo(-13 * bw, y); ctx.quadraticCurveTo(0, y - 3, 13 * bw, y);
        }
        ctx.stroke();
    }

    function drawArmorChest(ctx, look, top, hipY, body) {
        const sw = body.bw * body.shoulder;
        for (const sign of [-1, 1]) {
            const pec = body.feminine
                ? roundedPoly([[sign * 3, top - 4], [sign * 38 * sw, top - 8], [sign * 36 * sw, top - 30],
                    [sign * 22 * sw, top - 40], [sign * 6, top - 36]], 9)
                : roundedPoly([[sign * 3, top - 2], [sign * 40 * sw, top - 6], [sign * 38 * sw, top - 30], [sign * 4, top - 38]], 5);
            fill(ctx, pec, scaled(look.suit, 1.04), 1.4);
        }
        [top - 56, top - 68].forEach((y, row) => {
            for (const sign of [-1, 1]) {
                const w = row === 0 ? 13 : 11;
                fill(ctx, rrect(sign > 0 ? 2 : -2 - w, y, w, 9, 2.5), look.accent, 1);
            }
        });
        const beltW = 26 * body.bw * body.hip;
        fill(ctx, rrect(-beltW, hipY + 4, beltW * 2, 8, 3), scaled(look.suit, 0.75), 1);
        const cx = 0, cy = top - 24;
        fill(ctx, ell(cx - 12, cy - 12, 24, 24), '#6E737C', 1.4);
        glowSpot(ctx, cx, cy, 22, 0.5);
        drawCore(ctx, look.emblemColor, cx, cy, 7.5);
        ctx.strokeStyle = css('#3A3E46', 0.8);
        ctx.lineWidth = 1;
        ctx.beginPath();
        for (let i = 0; i < 8; i++) {
            const a = i * PI / 4;
            ctx.moveTo(cx + Math.cos(a) * 8, cy + Math.sin(a) * 8);
            ctx.lineTo(cx + Math.cos(a) * 11, cy + Math.sin(a) * 11);
        }
        ctx.stroke();
    }

    function drawCore(ctx, color, x, y, r) {
        const g = ctx.createRadialGradient(x, y, 0, x, y, r);
        g.addColorStop(0, '#FFFFFF');
        g.addColorStop(0.5, css(color));
        g.addColorStop(1, css(scaled(color, 0.6)));
        ctx.fillStyle = g;
        ctx.beginPath(); ctx.arc(x, y, r, 0, 2 * PI); ctx.fill();
    }

    // MARK: Head

    function drawHead(ctx, look, p) {
        const fx = 2 + p.lookX * 2.5;                      // 3/4 view: features turned toward the look direction
        const c = { x: Rig.head.x, y: Rig.head.y };
        // Skull with a defined jaw.
        const fem = look.figure === 'feminine';
        const head = new P().M(c.x - 18, c.y + 4)
            .C(c.x - 19, c.y + 32, c.x + 20, c.y + 32, c.x + 19, c.y + 6);
        if (fem) {
            // Softer jaw and a narrower, rounded chin.
            head.C(c.x + 19, c.y - 7, c.x + 13, c.y - 17, c.x + 5, c.y - 20)
                .Q(c.x + 1, c.y - 22.5, c.x - 3, c.y - 20)
                .C(c.x - 12, c.y - 17, c.x - 18, c.y - 7, c.x - 18, c.y + 4);
        } else {
            head.C(c.x + 19, c.y - 8, c.x + 16, c.y - 17, c.x + 8, c.y - 21)
                .Q(c.x + 1, c.y - 25, c.x - 6, c.y - 21)
                .C(c.x - 15, c.y - 17, c.x - 18, c.y - 8, c.x - 18, c.y + 4);
        }
        head.Z();

        if (look.mask === 'armor') metal = true;
        drawEars(ctx, look, c, true);
        const headColor = coversHead(look.mask) ? look.maskColor : look.skin;
        if (look.mask === 'none' || look.mask === 'domino' || look.mask === 'shades') {
            // Human ear on the far side.
            fill(ctx, ell(c.x - 22, c.y - 6, 8, 13), scaled(look.skin, 0.92), 1.2);
        }
        fill(ctx, head, headColor, 1.8);

        switch (look.mask) {
            case 'armor':
                drawArmorFace(ctx, look, p, c, fx);
                metal = look.outfit === 'armor';
                drawEars(ctx, look, c, false);
                return;
            case 'fullface':
                drawLenses(ctx, look, p, c, fx);
                drawEars(ctx, look, c, false);
                return;
            case 'cowl':
                ctx.save();
                ctx.clip(head.path);
                fill(ctx, rrect(c.x - 12 + fx, c.y - 26, 28, 22, 9), look.skin, 1.2);
                ctx.restore();
                break;
            case 'helmet': {
                const visor = rrect(c.x - 15 + fx, c.y - 6, 33, 17, 7);
                ctx.fillStyle = linear(ctx, 0, c.y + 11, 0, c.y - 6, [[0, '#D6F3FF'], [0.55, '#5FB4E8'], [1, '#2F6FA8']]);
                ctx.fill(visor.path);
                ctx.strokeStyle = css(scaled(look.maskColor, 0.4));
                ctx.lineWidth = 1.6;
                ctx.stroke(visor.path);
                break;
            }
        }

        if (look.mask === 'domino') fill(ctx, rrect(c.x - 16 + fx, c.y, 34, 10, 5), look.maskColor, 1.2);

        drawEyes(ctx, look, p, c, fx);

        if (look.mask === 'shades') {
            for (const dx of [-8, 9]) fill(ctx, rrect(c.x + fx + dx - 6.5, c.y + 0.5, 13, 8, 3), look.maskColor, 1);
            line(ctx, [[c.x + fx - 1.5, c.y + 5], [c.x + fx + 2.5, c.y + 5]], css(look.maskColor), 1.5);
        }
        if (look.glasses && look.mask !== 'shades') {
            ctx.strokeStyle = '#2A2A2A';
            ctx.lineWidth = 1.4;
            for (const dx of [-8, 9]) { ctx.beginPath(); ctx.ellipse(c.x + fx + dx, c.y + 4.5, 6, 5.5, 0, 0, 2 * PI); ctx.stroke(); }
            line(ctx, [[c.x + fx - 2, c.y + 5], [c.x + fx + 3, c.y + 5]], '#2A2A2A', 1.4);
        }

        if (look.mask !== 'helmet') {
            // Nose.
            line(ctx, [[c.x + fx + 3, c.y - 3], [c.x + fx + 4.5, c.y - 9], [c.x + fx + 1.5, c.y - 10]], css(scaled(look.skin, 0.6), 0.7), 1.3);
            if (look.beard === true && !fem) drawBeard(ctx, look.hair, c, fx, head);
            drawMouth(ctx, p, c.x + fx + 1.5, c.y - 15, scaled(look.skin, 0.5),
                fem ? mixed(look.skin, '#B8405A', 0.55) : null);
        }
        if (!coversHead(look.mask)) drawFrontHair(ctx, look, c);
        drawEars(ctx, look, c, false);
    }

    function drawEyes(ctx, look, p, c, fx) {
        const masked = look.mask === 'domino' || look.mask === 'cowl';
        for (const dx of [-8, 9]) {
            const ex = c.x + fx + dx, ey = c.y + 4;
            if (p.eyesOpen < 0.2) {
                ctx.strokeStyle = INK;
                ctx.lineWidth = 1.6;
                ctx.beginPath();
                ctx.moveTo(ex - 4, ey);
                ctx.quadraticCurveTo(ex, ey + (p.smile > 0.5 ? 3 : -2), ex + 4, ey);
                ctx.stroke();
            } else {
                const open = Math.min(1.15, p.eyesOpen);
                // Almond-shaped eye.
                const eye = new Path2D();
                eye.moveTo(ex - 5, ey);
                eye.quadraticCurveTo(ex, ey + 5 * open, ex + 5, ey + 0.5);
                eye.quadraticCurveTo(ex, ey - 3.5 * open, ex - 5, ey);
                eye.closePath();
                ctx.fillStyle = 'rgb(247,247,247)';
                ctx.fill(eye);
                if (!masked || look.mask === 'domino') {
                    ctx.save();
                    ctx.clip(eye);
                    const ix = ex + 0.8 + p.lookX * 1.4, iy = ey + 0.6 + p.lookY * 1;
                    ctx.fillStyle = '#4A3426';
                    ctx.beginPath(); ctx.arc(ix, iy, 2.8, 0, 2 * PI); ctx.fill();
                    ctx.fillStyle = INK;
                    ctx.beginPath(); ctx.arc(ix, iy, 1.4, 0, 2 * PI); ctx.fill();
                    ctx.fillStyle = 'rgba(255,255,255,0.9)';
                    ctx.beginPath(); ctx.arc(ix - 0.95, iy + 1.05, 0.65, 0, 2 * PI); ctx.fill();
                    ctx.restore();
                }
                ctx.strokeStyle = INK;
                ctx.lineWidth = 1.2;
                ctx.stroke(eye);
                if (look.figure === 'feminine' && look.mask !== 'cowl') {
                    // A heavier upper lid with a small wing of lashes at the outer corner.
                    const outer = dx < 0 ? -1 : 1;
                    ctx.lineWidth = 2;
                    ctx.beginPath();
                    ctx.moveTo(ex - 5, ey + 0.3);
                    ctx.quadraticCurveTo(ex, ey + 5 * open, ex + 5, ey + 0.8);
                    ctx.moveTo(ex + outer * 4.5, ey + 1.2);
                    ctx.lineTo(ex + outer * 7.5, ey + 3.4);
                    ctx.moveTo(ex + outer * 3, ey + 2.8 * open);
                    ctx.lineTo(ex + outer * 5.2, ey + 4.6 * open);
                    ctx.stroke();
                }
            }
            // Brows.
            if (look.mask !== 'helmet' && look.mask !== 'cowl') {
                const inner = dx < 0 ? ex + 4 : ex - 4, outer = dx < 0 ? ex - 5 : ex + 5;
                const fem = look.figure === 'feminine';
                ctx.strokeStyle = css(scaled(look.hair, 0.75));
                ctx.lineWidth = fem ? 1.5 : 2.2;
                ctx.beginPath();
                ctx.moveTo(outer, ey + 6 + 1.2 * p.brow);
                if (fem) ctx.quadraticCurveTo((outer + inner) / 2, ey + 8.5 + 1.8 * p.brow, inner, ey + 6.5 + 2.4 * p.brow - 0.6);
                else ctx.lineTo(inner, ey + 6 + 2.4 * p.brow - 0.6);
                ctx.stroke();
            }
        }
    }

    function drawMouth(ctx, p, mx, my, lip, tint = null) {
        if (tint && p.mouthOpen <= 0.15) {
            // Fuller, tinted lips.
            ctx.fillStyle = css(tint);
            ctx.beginPath();
            ctx.moveTo(mx - 4.5, my + 0.5);
            ctx.quadraticCurveTo(mx, my + 3.2 - 2 * p.smile, mx + 4.5, my + 0.5);
            ctx.quadraticCurveTo(mx, my - 3.6 - 3 * p.smile, mx - 4.5, my + 0.5);
            ctx.closePath();
            ctx.fill();
        }
        if (p.mouthOpen > 0.15) {
            const h = 2.5 + 5 * p.mouthOpen;
            ctx.fillStyle = '#4A1C24';
            ctx.beginPath();
            ctx.moveTo(mx - 5, my + 1);
            ctx.quadraticCurveTo(mx, my + 1 + p.smile * 1.5, mx + 5, my + 1);
            ctx.quadraticCurveTo(mx, my + 1 - h * 1.6, mx - 5, my + 1);
            ctx.closePath();
            ctx.fill();
        } else {
            ctx.strokeStyle = css(tint ? scaled(tint, 0.6) : lip);
            ctx.lineWidth = tint ? 1.1 : 1.5;
            ctx.beginPath();
            ctx.moveTo(mx - 4.5, my + 0.5);
            ctx.quadraticCurveTo(mx, my + 0.5 - 4 * p.smile, mx + 4.5, my + 0.5);
            ctx.stroke();
        }
    }

    function drawBeard(ctx, hair, c, fx, head) {
        ctx.save();
        ctx.clip(head.path);
        const beard = new P().M(c.x - 20, c.y - 2)
            .C(c.x - 14, c.y - 34, c.x + 16, c.y - 34, c.x + 21, c.y - 2)
            .L(c.x + 15, c.y - 2)
            .C(c.x + 10, c.y - 14, c.x - 8, c.y - 14, c.x - 14, c.y - 2)
            .Z();
        fill(ctx, beard, scaled(hair, 1.15), 0);
        ctx.restore();
        fill(ctx, rrect(c.x + fx - 4.5, c.y - 13.5, 12, 3.5, 1.7), scaled(hair, 1.15), 0);
    }

    function drawFrontHair(ctx, look, c) {
        const color = look.hair;
        switch (look.hairStyle) {
            case 'bald':
                solid(ctx, ell(c.x - 9, c.y + 17, 10, 5), 'rgba(255,255,255,0.2)');
                return;
            case 'spiky':
                [-14, -6, 2, 10, 17].forEach((base, i) => {
                    fill(ctx, roundedPoly([[c.x + base - 6, c.y + 20], [c.x + base * 1.2 - 3, c.y + 36 + (i % 2) * 4],
                        [c.x + base + 6, c.y + 20]], 1.5), color, 1.2);
                });
                break;
            case 'bun':
                fill(ctx, ell(c.x - 9, c.y + 22, 16, 14), color, 1.2);
                break;
        }
        // Cap of hair over the skull with a side part.
        const cap = new P().M(c.x - 19, c.y + 2)
            .C(c.x - 22, c.y + 34, c.x + 22, c.y + 34, c.x + 20, c.y + 10)
            .Q(c.x + 12, c.y + 14, c.x + 2, c.y + 16)
            .Q(c.x - 8, c.y + 16, c.x - 14, c.y + 8)
            .L(c.x - 15, c.y - 6)
            .Z();
        fill(ctx, cap, color, 1.4);
        line(ctx, [[c.x - 4, c.y + 27], [c.x + 4, c.y + 17]], css(scaled(color, 0.6), 0.6), 1);
        if (look.figure === 'feminine' && (look.hairStyle === 'long' || look.hairStyle === 'curly')) {
            // Locks falling past the cheeks.
            const back = new P().M(c.x - 19, c.y + 6)
                .C(c.x - 25, c.y - 6, c.x - 24, c.y - 20, c.x - 18, c.y - 26)
                .Q(c.x - 13, c.y - 10, c.x - 13, c.y + 4)
                .Z();
            fill(ctx, back, color, 1.3);
            const front = new P().M(c.x + 20, c.y + 10)
                .C(c.x + 26, c.y - 4, c.x + 26, c.y - 18, c.x + 21, c.y - 24)
                .Q(c.x + 15, c.y - 8, c.x + 16, c.y + 6)
                .Z();
            fill(ctx, front, color, 1.3);
        }
        if (look.hairStyle === 'curly') {
            for (const [x, y] of [[-14, 22], [-6, 28], [4, 28], [13, 22]]) {
                fill(ctx, ell(c.x + x - 6, c.y + y - 4, 12, 11), color, 1);
            }
        }
    }

    function drawBackHair(ctx, look, p, drop) {
        const c = { x: Rig.head.x, y: Rig.head.y - drop };
        const color = scaled(look.hair, 0.85);
        switch (look.hairStyle) {
            case 'long':
                fill(ctx, rrect(c.x - 22, c.y - 36, 42, 64, 16), color, 1.4);
                break;
            case 'ponytail': {
                const sway = 3 * Math.sin(p.capeWave * 0.8);
                const tail = new P().M(c.x - 14, c.y + 18)
                    .C(c.x - 34, c.y + 22, c.x - 38 + sway, c.y - 6, c.x - 30 + sway, c.y - 30)
                    .C(c.x - 24 + sway, c.y - 22, c.x - 20, c.y - 4, c.x - 16, c.y + 4)
                    .Z();
                fill(ctx, tail, color, 1.4);
                break;
            }
            case 'curly':
                fill(ctx, ell(c.x - 25, c.y - 14, 50, 50), color, 1.4);
                break;
        }
    }

    function drawEars(ctx, look, c, behind) {
        const color = look.mask === 'none' || look.mask === 'shades' ? look.hair : look.maskColor;
        switch (look.ears) {
            case 'pointy':
            case 'cat':
                if (!behind) return;
                for (const sign of [-1, 1]) {
                    const base = c.x + sign * 10;
                    fill(ctx, roundedPoly([[base - 6, c.y + 18], [base + sign * 4, c.y + 40], [base + 6, c.y + 18]], 1.5), color, 1.4);
                    if (look.ears === 'cat') {
                        fill(ctx, roundedPoly([[base - 2.5, c.y + 21], [base + sign * 2.5, c.y + 33], [base + 2.5, c.y + 21]], 1), '#F4A6C0', 0);
                    }
                }
                break;
            case 'antenna':
                if (behind) return;
                line(ctx, [[c.x + 4, c.y + 24], [c.x + 9, c.y + 40]], css(scaled(look.accent, 0.6)), 2);
                fill(ctx, ell(c.x + 5, c.y + 37, 8, 8), look.accent, 1);
                break;
        }
    }

    /// Sculpted gold faceplate, ear discs and glowing eye slits.
    function drawArmorFace(ctx, look, p, c, fx) {
        const x = c.x + fx * 0.8;
        line(ctx, [[c.x - 1, c.y + 28], [c.x, c.y + 18]], css(scaled(look.maskColor, 0.3), 0.7), 1.2);
        fill(ctx, ell(c.x - 22, c.y - 6, 9, 12), scaled(look.maskColor, 0.85), 1.2);
        const plate = roundedPoly([
            [x - 7, c.y + 20], [x + 8, c.y + 20], [x + 12, c.y + 12], [x + 16, c.y + 2],
            [x + 13, c.y - 12], [x + 6, c.y - 20], [x - 5, c.y - 20], [x - 12, c.y - 12],
            [x - 15, c.y + 2], [x - 11, c.y + 12],
        ], 2.5);
        fill(ctx, plate, look.accent, 1.4);
        const groove = css(scaled(look.accent, 0.4), 0.75);
        for (const sign of [-1, 1]) {
            line(ctx, [[x + sign * 12, c.y - 1], [x + sign * 8, c.y - 9], [x + sign * 4, c.y - 19]], groove, 1);
            line(ctx, [[x + sign * 7, c.y + 19], [x + sign * 10, c.y + 10]], groove, 1);
        }
        line(ctx, [[x - 6, c.y - 13], [x - 2, c.y - 14], [x + 3, c.y - 14], [x + 7, c.y - 13]], groove, 1.3);
        const lit = p.eyesOpen > 0.2;
        for (const sign of [-1, 1]) {
            const ex = x + sign * 7 + 0.5;
            const slit = roundedPoly([[ex - sign * 5, c.y + 4.5], [ex + sign * 5.5, c.y + 5.5],
                [ex + sign * 4.5, c.y + 2], [ex - sign * 4.5, c.y + 2]], 0.6);
            solid(ctx, slit, '#1E2328');
            if (lit) {
                glowSpot(ctx, ex, c.y + 3.5, 10, 0.7);
                solid(ctx, slit, 'rgb(224,255,255)');
            }
        }
    }

    /// Full-face mask with large white lenses that narrow when blinking.
    function drawLenses(ctx, look, p, c, fx) {
        line(ctx, [[c.x + fx * 0.6, c.y + 28], [c.x + fx * 0.6, c.y - 22]], css(scaled(look.maskColor, 0.45), 0.5), 1);
        const open = Math.max(0.15, Math.min(1.1, p.eyesOpen));
        for (const sign of [-1, 1]) {
            const ex = c.x + fx + sign * 8.5;
            const h = 11 * open;
            const lens = new Path2D();
            lens.moveTo(ex - sign * 3, c.y + 1);
            lens.bezierCurveTo(ex + sign * 2, c.y - 1, ex + sign * 9, c.y + 1, ex + sign * 8, c.y + 2 + h * 0.7);
            lens.bezierCurveTo(ex + sign * 2, c.y + 4 + h, ex - sign * 6, c.y + 3 + h * 0.5, ex - sign * 3, c.y + 1);
            lens.closePath();
            ctx.fillStyle = 'rgb(247,247,247)';
            ctx.fill(lens);
            ctx.strokeStyle = '#15151A';
            ctx.lineWidth = 2.2;
            ctx.stroke(lens);
        }
    }

    // MARK: Snapshots (previews, thumbnails)

    /// Renders onto a new px × px canvas, framed like the Mac app's HeroRenderer.image.
    function snapshot(look, pose, px) {
        const canvas = document.createElement('canvas');
        canvas.width = px;
        canvas.height = px;
        const ctx = canvas.getContext('2d');
        const s = px / (Rig.height + 80);
        ctx.translate(px / 2, px - 10 * s);
        ctx.scale(s, -s);
        draw(ctx, look, pose);
        return canvas;
    }

    globalThis.Hero = {
        presets, heroes, heroines, preset, normalize, appearance,
        Rig, Pose, PoseAnimator, PoseLibrary,
        Renderer: { height: Rig.height, aspect: 0.62, draw, snapshot },
        EMBLEMS: Emblem,
        Hair, Mask, Ears, Emblem, Outfit, Build, Attitude, Figure,
        Color: { rgb, scaled, css, hex, mixed },
    };
})();
