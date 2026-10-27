"""Dawarich Discord-kártyák (PNG): custom restore, OSRM overlay restore, visit cleanup.

Sötét Dawarich-téma (dawarich-dark tokenek). A két restore menetjegy: verzió → verzió,
közte az idő, alatta három mező, a tépésvonal alatt a teendő. A cleanup heti-riport:
főszám, változás tegnaphoz, 14 napos oszlopsor, a mai kiemelve. Csak stdlib + Pillow;
ha a rajzolás vagy a feltöltés bukik, a hívó sima szöveges embedet küld (send_card).
"""
from __future__ import annotations

import functools
import glob
import io
import json
import urllib.request
import uuid

from PIL import Image, ImageChops, ImageDraw, ImageFont

# dawarich-dark: base-100 #1C1C1C, base-content #EAEAEA, success #2DD4BF, warning #FBBF24,
# error #F87171, primary #60A5FA; a halvány szöveg a base-content 70%-a (#A8A8A8, 7.9:1).
INK, MUT, LINE = (234, 234, 234), (168, 168, 168), (64, 64, 64)
BASE, BASE2, BAR = (28, 28, 28), (44, 44, 44), (72, 72, 72)
PRIMARY = (96, 165, 250)
TONE = {  # állapot -> (szín, halvány háttér)
    "ok": ((45, 212, 191), (21, 58, 54)),
    "warn": ((251, 191, 36), (58, 48, 22)),
    "fail": ((248, 113, 113), (64, 30, 30)),
}
EMBED_COLOR = {"ok": 0x2DD4BF, "warn": 0xFBBF24, "fail": 0xF87171}
W, PAD = 800, 40
FONT_GLOBS = ("/usr/share/fonts/**/Inter-{w}.*", "/opt/dawarich/app/vendor/poster_renderer/fonts/inter-{n}.ttf")


@functools.lru_cache(maxsize=64)
def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    num = {"Regular": "400", "Medium": "400", "SemiBold": "700", "Bold": "700"}.get(weight, "400")
    for pattern in FONT_GLOBS:
        for path in sorted(glob.glob(pattern.format(w=weight, n=num), recursive=True)):
            return ImageFont.truetype(path, size)
    return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)


def fit(d, text, f, maxw) -> str:
    text = str(text or "")
    if d.textlength(text, font=f) <= maxw:
        return text
    while text and d.textlength(text + "…", font=f) > maxw:
        text = text[:-1]
    return text.rstrip() + "…"


def wrap(d, text, f, maxw, max_lines=3) -> list[str]:
    lines, cur = [], ""
    for word in str(text or "").split():
        t = (cur + " " + word).strip()
        if d.textlength(t, font=f) > maxw and cur:
            lines.append(cur)
            cur = word
        else:
            cur = t
    if cur:
        lines.append(cur)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = fit(d, lines[-1] + " …", f, maxw)
    return lines


def fmt_dur(sec) -> str:
    sec = int(round(float(sec)))
    if sec < 60:
        return f"{sec} mp"
    m, s = divmod(sec, 60)
    return f"{m} p {s} mp" if m < 60 else f"{m // 60} ó {m % 60} p"


def thousands(n) -> str:
    return f"{int(n):,}".replace(",", " ")


def _short(path: str) -> str:
    return str(path).rsplit("/", 1)[-1]


class Ticket:
    """Sötét kártya átlátszó alapon; `tear()` húzza a tépésvonalat a két kivágással."""

    def __init__(self, kicker: str, chip: str, status: str):
        self.img = Image.new("RGBA", (W, 1200), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.img)
        self.status = status
        self.tear_y: int | None = None
        d = self.d
        d.rounded_rectangle([0, 0, W - 1, 1199], 28, fill=BASE + (255,))
        d.text((PAD, 34), fit(d, kicker, font("Medium", 22), W - 2 * PAD - 220), font=font("Medium", 22), fill=MUT)
        self.chip(chip, status)
        self.y = 92

    def chip(self, text: str, status: str):
        d, f = self.d, font("SemiBold", 22)
        fg, bg = TONE[status]
        w = d.textlength(text, font=f) + 32
        d.rounded_rectangle([W - PAD - w, 28, W - PAD, 68], 20, fill=bg)
        d.text((W - PAD - w + 16, 35), text, font=f, fill=fg)

    def route(self, a: str | None, b: str, under_a: str, under_b: str, mid: str):
        """a ○━━ mid ━━● b – a vonal színe az állapot (Menetrend-módszer V)."""
        d, y = self.d, self.y
        color = TONE[self.status][0]
        fb, fs, fm = font("Bold", 56), font("Regular", 22), font("SemiBold", 22)
        a = a or "–"
        d.text((PAD, y), a, font=fb, fill=INK if a != "–" else MUT)
        d.text((PAD, y + 68), under_a, font=fs, fill=MUT)
        wb = d.textlength(b, font=fb)
        d.text((W - PAD - wb, y), b, font=fb, fill=INK)
        d.text((W - PAD - d.textlength(under_b, font=fs), y + 68), under_b, font=fs, fill=MUT)
        x0, x1, cy = PAD + d.textlength(a, font=fb) + 34, W - PAD - wb - 34, y + 34
        d.line([(x0 + 10, cy), (x1 - 10, cy)], fill=color, width=5)
        d.ellipse([x0 - 8, cy - 8, x0 + 8, cy + 8], outline=color, width=4, fill=BASE)
        d.ellipse([x1 - 9, cy - 9, x1 + 9, cy + 9], fill=color)
        if mid:
            mid = fit(d, mid, fm, max(40, x1 - x0 - 60))
            tw = d.textlength(mid, font=fm)
            mx = (x0 + x1) / 2
            d.rounded_rectangle([mx - tw / 2 - 14, cy - 18, mx + tw / 2 + 14, cy + 18], 18, fill=BASE2)
            d.text((mx - tw / 2, cy - 13), mid, font=fm, fill=INK)
        self.y += 110

    def fields(self, items: list[tuple[str, str, str | None]]):
        """(címke, érték, állapot|None) – legfeljebb 3 oszlop."""
        d = self.d
        items = items[:3]
        cw = (W - 2 * PAD) / max(1, len(items))
        for i, (k, v, st) in enumerate(items):
            x = PAD + i * cw
            d.text((x, self.y), k, font=font("Regular", 20), fill=MUT)
            col = TONE[st][0] if st else INK
            d.text((x, self.y + 28), fit(d, v, font("SemiBold", 28), cw - 16), font=font("SemiBold", 28), fill=col)
        self.y += 90

    def stub(self, head: str, text: str, status: str):
        """A tépésvonal alatti teendő/hiba – ez az egyetlen, amivel Batornak dolga van."""
        d = self.d
        self.y += 8
        self.tear_y = self.y
        self.y += 36
        fg, bg = TONE[status]
        lines = wrap(d, text, font("Regular", 22), W - 2 * PAD - 48)
        h = 48 + 30 * len(lines) + 16
        d.rounded_rectangle([PAD, self.y, W - PAD, self.y + h], 16, fill=bg)
        d.text((PAD + 24, self.y + 14), head, font=font("SemiBold", 22), fill=fg)
        for i, ln in enumerate(lines):
            d.text((PAD + 24, self.y + 48 + 30 * i), ln, font=font("Regular", 22), fill=INK)
        self.y += h + 4

    def png(self) -> bytes:
        h = self.y + 32
        img = self.img.crop((0, 0, W, h))
        d = ImageDraw.Draw(img)
        # alsó lekerekítés a vágás után
        mask = Image.new("L", (W, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, h - 1], 28, fill=255)
        img.putalpha(ImageChops.darker(img.getchannel("A"), mask))
        if self.tear_y is not None:
            for cx in (0, W):
                d.ellipse([cx - 18, self.tear_y - 18, cx + 18, self.tear_y + 18], fill=(0, 0, 0, 0))
            for x in range(PAD - 4, W - PAD, 20):
                d.line([(x, self.tear_y), (x + 10, self.tear_y)], fill=LINE, width=3)
        buf = io.BytesIO()
        img.save(buf, "PNG", optimize=True)
        return buf.getvalue()


# --- 1. custom restore -------------------------------------------------------
def custom_restore_card(r: dict) -> tuple[str, bytes]:
    """r: kind (ok|failed|blocked|crashed), version, prev_version, t_start, t_end, duration_s,
    files, merged_notes [(file, clean)], steps [(name, sub, ok|fail)], conflicts [str], error, rebase_base."""
    kind = r.get("kind", "ok")
    status = "ok" if kind == "ok" else "fail"
    chip = {"ok": "Kész", "failed": "Hiba", "blocked": "Leállítva", "crashed": "Összeomlott"}[kind]
    t = Ticket("Dawarich frissítés · custom restore", chip, status)
    mid = fmt_dur(r["duration_s"]) if r.get("duration_s") else ("ütközés" if kind == "blocked" else "")
    t.route(r.get("prev_version"), r.get("version", "?"), r.get("t_start", ""), r.get("t_end", ""), mid)

    notes = r.get("merged_notes") or []
    bad = [f for f, ok in notes if not ok]
    steps = r.get("steps") or []
    failed = next((n for n, _, st in steps if st == "fail"), None)
    smoke = next((sub for n, sub, st in steps if n == "Smoke" and st == "ok"), "")
    if failed:
        check = (failed, "fail")  # a piros szín mondja, hogy ez bukott
    elif smoke:
        n = len([p for p in smoke.split("·") if p.strip()])
        check = (f"{n} / {n} rendben", None)
    else:
        check = ("nem futott" if kind != "ok" else "–", None)
    t.fields([
        ("Fájl", thousands(r["files"]) if r.get("files") is not None else "0", None),
        ("Upstream merge", f"{len(bad)} ütközik" if bad else (f"{len(notes)} tiszta" if notes else "nincs"),
         "fail" if bad else None),
        ("Ellenőrzés", *check),
    ])
    if kind == "blocked":
        t.stub("Semmi nem íródott – az app transit nélkül fut",
               "; ".join(r.get("conflicts") or []) or "Lásd a naplót.", "fail")
    elif kind in ("failed", "crashed"):
        t.stub("Hiba", r.get("error") or "ismeretlen", "fail")
    elif r.get("rebase_base"):
        t.stub("Teendő", f"rebase {r.get('version')}-re: restore_custom.py rebase, majd commit + push", "warn")
    return status, t.png()


# --- 2. overlay restore ------------------------------------------------------
OVERLAY_GROUPS = (
    ("Snap", ("osrm_snap_job.rb", "track.rb", "recalculate_job.rb")),
    ("Szegmentálás", ("segmentation.rb", "boundary_detector.rb", "orphan_point_attacher.rb")),
    ("Family réteg", ("locations.rb", "family_layer", "sprockets-manifest.json")),
)


def overlay_restore_card(r: dict) -> tuple[str, bytes]:
    """r: version, prev_version, t_start, t_end, replaced [path], restarted [unit], errors [str],
    pinned_version, pinned_files."""
    errors = r.get("errors") or []
    replaced = list(r.get("replaced") or [])
    pinned = r.get("pinned_version")
    stale = bool(pinned and pinned != r.get("version") and replaced)
    status = "fail" if errors else "ok"
    t = Ticket("Dawarich frissítés · OSRM overlay", "Hiba" if errors else "Kész", status)
    mid = f"{len(replaced)} fájl" if replaced else ("újraindítás" if r.get("restarted") else "")
    t.route(r.get("prev_version"), r.get("version", "?"), r.get("t_start", ""), r.get("t_end", ""), mid)

    groups, used = [], set()
    for name, keys in OVERLAY_GROUPS:
        hit = [p for p in replaced if any(k in p for k in keys)]
        used.update(hit)
        if hit:
            groups.append((name, f"{len(hit)} fájl", None))
    if [p for p in replaced if p not in used]:
        groups.append(("Egyéb", f"{len([p for p in replaced if p not in used])} fájl", None))
    restarted = ", ".join(u.replace("dawarich-", "") for u in r.get("restarted") or [])
    tail = ("Újraindítva", restarted or ("nem sikerült" if errors else "nem kellett"),
            "fail" if errors and not restarted else None)
    fields = groups[:2] + [tail] if groups else [("Fájl", "nem kellett", None), tail]
    t.fields(fields)
    if errors:
        t.stub("Hiba", "; ".join(errors), "fail")
    elif stale:
        names = r.get("pinned_files") or []
        t.stub("Ellenőrizd", f"{len(names)} overlay {pinned}-hoz készült – nézd át az upstream/{r['version']}/ mentést", "warn")
    return status, t.png()


# --- 3. visit cleanup ----------------------------------------------------------
def cleanup_card(r: dict) -> tuple[str, bytes]:
    """r: left_suggested, history [('MM.DD', n)] (a mai az utolsó), scan_days, changes {címke: n},
    warn, fail, error."""
    fail = bool(int(r.get("fail") or 0) or r.get("error"))
    warn = int(r.get("warn") or 0)
    status = "fail" if fail else ("warn" if warn else "ok")
    changes = [f"{v} {k}" for k, v in (r.get("changes") or {}).items() if v]
    chip = "Hiba" if fail else (f"{warn} figyelmeztetés" if warn else (" · ".join(changes[:2]) or "Rendben"))
    t = Ticket("Dawarich · látogatások", chip, status)
    d, y = t.d, t.y
    n = r.get("left_suggested")
    big = "–" if n is None else thousands(n)
    fb = font("Bold", 96)
    d.text((PAD - 4, y - 10), big, font=fb, fill=INK)
    x = PAD + d.textlength(big, font=fb) + 16
    d.text((x, y + 12), "látogatás vár", font=font("SemiBold", 30), fill=INK)
    d.text((x, y + 50), "jóváhagyásra", font=font("SemiBold", 30), fill=INK)
    hist = list(r.get("history") or [])
    sub, sub_col = f"utolsó {r.get('scan_days', 45)} nap", MUT
    if len(hist) >= 2 and n is not None:
        delta = hist[-1][1] - hist[-2][1]
        if delta:
            sub = f"{abs(delta)}-vel {'kevesebb' if delta < 0 else 'több'}, mint előző nap"
            sub_col = TONE["ok" if delta < 0 else "warn"][0]
    d.text((PAD, y + 114), sub, font=font("Regular", 22), fill=sub_col)
    t.y = y + 170
    h14 = hist[-14:]
    if len(h14) >= 2:  # oszlopsor: magasság = várakozó javaslat, a mai kiemelve (M elv)
        top, bot = t.y, t.y + 110
        mx = max(v for _, v in h14) or 1
        gap = 8
        bw = min(46, (W - 2 * PAD - gap * (len(h14) - 1)) / len(h14))
        left = W - PAD - len(h14) * bw - gap * (len(h14) - 1)  # kevés napnál jobbra zárva, a „ma” fölött
        for i, (_, v) in enumerate(h14):
            x0 = left + i * (bw + gap)
            hh = max(6, (bot - top) * v / mx)
            col = (TONE["fail"][0] if fail else PRIMARY) if i == len(h14) - 1 else BAR
            d.rounded_rectangle([x0, bot - hh, x0 + bw, bot], 6, fill=col)
        fa = font("Regular", 18)
        d.text((left, bot + 12), h14[0][0], font=fa, fill=MUT)
        d.text((W - PAD - d.textlength("ma", font=fa), bot + 12), "ma", font=fa, fill=MUT)
        t.y = bot + 44
    if fail:
        t.stub("Hiba", r.get("error") or f"{r.get('fail')} sikertelen művelet", "fail")
    elif len(changes) > 2:
        t.stub("Ma", " · ".join(changes), "ok")
    return status, t.png()


# --- küldés --------------------------------------------------------------------
def send_card(webhook: str, title: str, status: str, png: bytes | None, fallback_text: str,
              url: str | None = None, user_agent: str = "dawarich-cards") -> dict:
    """Kép + cím-link; ha nincs kép, a régi szöveges embed. Kivételt a hívó kezel.
    `?wait=true` webhooknál a Discord-üzenet JSON-ját adja vissza (különben {})."""
    embed: dict = {"title": title[:256], "color": EMBED_COLOR[status]}
    if url:
        embed["url"] = url
    if png:
        embed["image"] = {"url": "attachment://card.png"}
        boundary = uuid.uuid4().hex
        payload = json.dumps({"embeds": [embed]}).encode()
        body = (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n"
            f"Content-Type: application/json\r\n\r\n".encode() + payload +
            f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"card.png\"\r\n"
            f"Content-Type: image/png\r\n\r\n".encode() + png + f"\r\n--{boundary}--\r\n".encode()
        )
        ctype = f"multipart/form-data; boundary={boundary}"
    else:
        embed["description"] = fallback_text[:3900]
        body, ctype = json.dumps({"embeds": [embed]}).encode(), "application/json"
    req = urllib.request.Request(webhook, data=body, method="POST",
                                 headers={"Content-Type": ctype, "User-Agent": user_agent})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    try:
        return json.loads(raw) if raw else {}
    except ValueError:
        return {}
