"""Dawarich Discord-kártyák (PNG): custom restore, overlay restore, visit cleanup.

A homelab relay-kártyák vizuális nyelve (Inter, sötét háttér, állapot-pill, lépés-csempék,
alsó színsáv) + a Menetrend-módszer verzió-gerince és főszáma. Csak stdlib + Pillow;
ha a rajzolás vagy a feltöltés bukik, a hívó sima szöveges embedet küld (send_card).
"""
from __future__ import annotations

import functools
import glob
import io
import json
import urllib.request
import uuid

from PIL import Image, ImageDraw, ImageFont

BG, TILE, FG, SEC, MUT = (30, 31, 34), (43, 45, 49), (242, 243, 245), (181, 186, 193), (148, 155, 164)
GREEN, RED, AMBER, BLUE = (59, 165, 93), (237, 66, 69), (250, 166, 26), (88, 101, 242)
CHIP = (54, 57, 63)
W, PAD = 800, 32
STATUS = {"ok": GREEN, "warn": AMBER, "fail": RED}
EMBED_COLOR = {"ok": 0x3BA55D, "warn": 0xFAA61A, "fail": 0xED4245}
FONT_DIRS = ("/usr/share/fonts/**/Inter-{w}.*", "/opt/dawarich/app/vendor/poster_renderer/fonts/inter-{n}.ttf")


@functools.lru_cache(maxsize=64)
def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    num = {"Regular": "400", "Medium": "400", "SemiBold": "700", "Bold": "700"}.get(weight, "400")
    for pattern in FONT_DIRS:
        for path in sorted(glob.glob(pattern.format(w=weight, n=num), recursive=True)):
            return ImageFont.truetype(path, size)
    return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)


def mix(c, a, base=BG):
    return tuple(int(x * a + b * (1 - a)) for x, b in zip(c, base))


def fit(d, text, f, maxw):
    text = str(text or "")
    if d.textlength(text, font=f) <= maxw:
        return text
    while text and d.textlength(text + "…", font=f) > maxw:
        text = text[:-1]
    return text.rstrip() + "…"


def fmt_dur(sec) -> str:
    sec = int(round(float(sec)))
    if sec < 60:
        return f"{sec} mp"
    m, s = divmod(sec, 60)
    return f"{m} p {s} mp" if m < 60 else f"{m // 60} ó {m % 60} p"


def thousands(n) -> str:
    return f"{int(n):,}".replace(",", " ")


class Card:
    """Felülről lefelé építkező vászon; a végén a magasságra vágva."""

    def __init__(self, kicker: str, status: str, pill: str):
        self.img = Image.new("RGB", (W, 1400), BG)
        self.d = ImageDraw.Draw(self.img)
        self.status = status
        self.y = PAD
        d = self.d
        d.text((PAD, self.y + 8), kicker.upper(), font=font("SemiBold", 18), fill=MUT)
        color = STATUS[status]
        f = font("SemiBold", 22)
        w = d.textlength(pill, font=f) + 36
        d.rounded_rectangle([W - PAD - w, self.y, W - PAD, self.y + 38], 19, fill=mix(color, .22), outline=color, width=2)
        d.text((W - PAD - w + 18, self.y + 6), pill, font=f, fill=color)
        self.y += 38 + 22

    # --- blocks ------------------------------------------------------------
    def version_spine(self, old: str | None, new: str, right: str = ""):
        """1.18.0 ●━━━━● 1.18.1 – a vonal a változás, a pötty a verzió (Menetrend-módszer V)."""
        d, y = self.d, self.y
        color = STATUS[self.status]
        fb, fm = font("Bold", 40), font("Regular", 24)
        x = PAD
        if old and old != new:
            d.text((x, y + 12), old, font=fm, fill=MUT)
            x += d.textlength(old, font=fm) + 16
            cy = y + 27
            d.ellipse([x, cy - 8, x + 16, cy + 8], outline=MUT, width=3, fill=BG)
            x0 = x + 16
            x1 = x0 + 120
            d.rounded_rectangle([x0, cy - 3, x1, cy + 3], 3, fill=color)
            d.ellipse([x1, cy - 10, x1 + 20, cy + 10], fill=color)
            x = x1 + 20 + 16
        d.text((x, y), new, font=fb, fill=FG)
        if right:
            fr = font("Regular", 22)
            d.text((W - PAD - d.textlength(right, font=fr), y + 14), right, font=fr, fill=SEC)
        self.y += 56 + 20

    def steps(self, items: list[tuple[str, str, str]], cols: int = 3):
        """(név, alcím, ok|fail|skip) csempék, soronként `cols` darab."""
        d = self.d
        gap = 12
        tw = (W - 2 * PAD - gap * (cols - 1)) / cols
        th = 70
        for i, (name, sub, st) in enumerate(items):
            r, c = divmod(i, cols)
            x = PAD + c * (tw + gap)
            y = self.y + r * (th + gap)
            d.rounded_rectangle([x, y, x + tw, y + th], 10, fill=TILE)
            col = {"ok": GREEN, "fail": RED, "warn": AMBER}.get(st, MUT)
            cx, cy = x + 30, y + th / 2
            d.ellipse([cx - 14, cy - 14, cx + 14, cy + 14], fill=col if st != "skip" else CHIP)
            if st == "ok":
                d.line([(cx - 7, cy), (cx - 2, cy + 6), (cx + 8, cy - 6)], fill=BG, width=4, joint="curve")
            elif st == "fail":
                d.line([(cx - 6, cy - 6), (cx + 6, cy + 6)], fill=BG, width=4)
                d.line([(cx - 6, cy + 6), (cx + 6, cy - 6)], fill=BG, width=4)
            elif st == "warn":
                d.rounded_rectangle([cx - 2, cy - 8, cx + 2, cy + 3], 2, fill=BG)
                d.ellipse([cx - 2, cy + 6, cx + 2, cy + 10], fill=BG)
            maxw = tw - 62
            d.text((x + 54, y + 12), fit(d, name, font("SemiBold", 22), maxw), font=font("SemiBold", 22), fill=FG)
            d.text((x + 54, y + 40), fit(d, sub, font("Regular", 18), maxw), font=font("Regular", 18), fill=SEC)
        rows = (len(items) + cols - 1) // cols
        self.y += rows * (th + gap) - gap + 24

    def chips(self, label: str, names: list[str], tone=CHIP, ink=FG):
        d = self.d
        d.text((PAD, self.y), label, font=font("Regular", 18), fill=MUT)
        self.y += 30
        f = font("Medium", 20)
        x, y = PAD, self.y
        for n in names:
            w = d.textlength(n, font=f) + 24
            if x + w > W - PAD and x > PAD:
                x, y = PAD, y + 42
            d.rounded_rectangle([x, y, x + w, y + 34], 8, fill=tone)
            d.text((x + 12, y + 5), n, font=f, fill=ink)
            x += w + 8
        self.y = y + 34 + 24

    def band(self, head: str, text: str, color=AMBER):
        """Teendő-sáv: ez az egyetlen, amit Batornak tennie kell."""
        d = self.d
        fh, ft = font("SemiBold", 22), font("Regular", 20)
        maxw = W - 2 * PAD - 44
        words, lines, cur = text.split(), [], ""
        for w_ in words:
            t = (cur + " " + w_).strip()
            if d.textlength(t, font=ft) > maxw and cur:
                lines.append(cur)
                cur = w_
            else:
                cur = t
        if cur:
            lines.append(cur)
        h = 22 + 30 + 28 * len(lines) + 14
        d.rounded_rectangle([PAD, self.y, W - PAD, self.y + h], 10, fill=mix(color, .14))
        d.rounded_rectangle([PAD, self.y, PAD + 6, self.y + h], 3, fill=color)
        d.text((PAD + 26, self.y + 16), head, font=fh, fill=color)
        for i, ln in enumerate(lines):
            d.text((PAD + 26, self.y + 50 + 28 * i), ln, font=ft, fill=FG)
        self.y += h + 24

    def png(self) -> bytes:
        h = self.y - 24 + PAD
        img = self.img.crop((0, 0, W, h + 8))
        ImageDraw.Draw(img).rectangle([0, h, W, h + 8], fill=STATUS[self.status])
        buf = io.BytesIO()
        img.save(buf, "PNG", optimize=True)
        return buf.getvalue()


def _short(path: str) -> str:
    return path.rsplit("/", 1)[-1]


# --- 1. custom restore -------------------------------------------------------
def custom_restore_card(r: dict) -> tuple[str, bytes]:
    """r: kind (ok|failed|blocked|crashed), version, prev_version, custom, merged, removed,
    merged_notes [(file, clean)], steps [(name, sub, st)], conflicts [str], error, rebase_base, duration_s."""
    kind = r.get("kind", "ok")
    status = "ok" if kind == "ok" else "fail"
    if kind == "ok" and r.get("rebase_base"):
        status = "warn"
    pill = {"ok": "Visszaállítva", "failed": "Hiba", "blocked": "Leállítva", "crashed": "Összeomlott"}[kind]
    c = Card("Dawarich · custom restore", status, pill)
    dur = fmt_dur(r["duration_s"]) if r.get("duration_s") else ""
    c.version_spine(r.get("prev_version"), r.get("version", "?"), dur)
    if r.get("steps"):
        c.steps(r["steps"])
    if r.get("merged_notes"):
        clean = [_short(f) for f, ok in r["merged_notes"] if ok]
        bad = [_short(f) for f, ok in r["merged_notes"] if not ok]
        if clean:
            c.chips(f"Upstream változott, tisztán merge-elve ({len(clean)})", clean)
        if bad:
            c.chips(f"Ütközés ({len(bad)})", bad, tone=mix(RED, .25), ink=FG)
    if kind == "blocked":
        c.band("Semmi nem íródott",
               "Az app upstream állapotban fut, transit nélkül. " + ("; ".join(r.get("conflicts") or [])[:400] or "Lásd a naplót."), RED)
    elif kind in ("failed", "crashed"):
        c.band("Hiba", (r.get("error") or "ismeretlen")[:400], RED)
    elif r.get("rebase_base"):
        c.band("Teendő: rebase",
               f"A merge-bázis még {r['rebase_base']}. A CT 139-en: restore_custom.py rebase, majd commit + push.")
    return status, c.png()


# --- 2. overlay restore ------------------------------------------------------
OVERLAY_GROUPS = (
    ("OSRM snap", ("osrm_snap_job.rb", "track.rb", "recalculate_job.rb")),
    ("Szegmentálás", ("segmentation.rb", "boundary_detector.rb", "orphan_point_attacher.rb")),
    ("Family réteg", ("locations.rb", "family_layer", "sprockets-manifest.json")),
)


def overlay_restore_card(r: dict) -> tuple[str, bytes]:
    """r: version, prev_version, replaced [path], restarted [unit], errors [str], pinned_version, pinned_files."""
    errors = r.get("errors") or []
    pinned = r.get("pinned_version")
    stale = bool(pinned and pinned != r.get("version") and r.get("replaced"))
    status = "fail" if errors else ("warn" if stale else "ok")
    c = Card("Dawarich · OSRM overlay restore", status, "Hiba" if errors else "Visszaállítva")
    c.version_spine(r.get("prev_version"), r.get("version", "?"))
    replaced = list(r.get("replaced") or [])
    tiles, used = [], set()
    for name, keys in OVERLAY_GROUPS:
        hit = [p for p in replaced if any(k in p for k in keys)]
        used.update(hit)
        if hit:
            tiles.append((name, f"{len(hit)} fájl", "ok"))
    rest = [p for p in replaced if p not in used]
    if rest:
        tiles.append(("Egyéb", f"{len(rest)} fájl", "ok"))
    if r.get("restarted"):
        tiles.append(("Újraindítás", " · ".join(u.replace("dawarich-", "") for u in r["restarted"]), "ok"))
    elif replaced:
        tiles.append(("Újraindítás", "nem kellett", "skip"))
    for e in errors[:3]:
        tiles.append(("Hiba", e, "fail"))
    if tiles:
        c.steps(tiles, cols=2 if len(tiles) <= 4 else 3)
    if stale:
        files = ", ".join(r.get("pinned_files") or [])
        c.band(f"Az overlay {pinned}-hoz készült",
               f"{files} – vesd össze az upstream/{r['version']}/ mentéssel, változott-e az eredeti.")
    return status, c.png()


# --- 3. visit cleanup ----------------------------------------------------------
def cleanup_card(r: dict) -> tuple[str, bytes]:
    """r: left_suggested, history [(date 'MM.DD', n)], scan_days, changes {label: n}, warn, fail, error."""
    fail = int(r.get("fail") or 0) or bool(r.get("error"))
    warn = int(r.get("warn") or 0)
    status = "fail" if fail else ("warn" if warn else "ok")
    c = Card("Dawarich · látogatások", status, "Hiba" if fail else ("Figyelmeztetés" if warn else "Rendben"))
    d, y = c.d, c.y
    n = r.get("left_suggested")
    big = "–" if n is None else thousands(n)
    fh = font("Bold", 84)
    d.text((PAD - 4, y - 10), big, font=fh, fill=FG)
    hx = PAD + d.textlength(big, font=fh) + 18
    d.text((hx, y + 8), "látogatás vár", font=font("SemiBold", 24), fill=FG)
    d.text((hx, y + 40), "jóváhagyásra", font=font("SemiBold", 24), fill=FG)
    hist = r.get("history") or []
    if len(hist) >= 2:
        delta = hist[-1][1] - hist[-2][1]
        if delta:
            col = GREEN if delta < 0 else AMBER
            t = f"{'−' if delta < 0 else '+'}{abs(delta)} tegnap óta"
            d.text((PAD, y + 92), t, font=font("SemiBold", 20), fill=col)
            d.text((PAD + d.textlength(t, font=font("SemiBold", 20)) + 10, y + 92),
                   f"· utolsó {r.get('scan_days', 45)} nap", font=font("Regular", 20), fill=MUT)
    # görbe: a várakozó javaslatok napi száma (M elv: alakot mutat egyenletes adatnál is)
    gx0, gx1, gy0, gy1 = 400, W - PAD, y + 6, y + 108
    if len(hist) >= 2:
        vals = [v for _, v in hist]
        lo, hi = 0, max(vals) * 1.1 or 1
        pts = [(gx0 + (gx1 - gx0) * i / (len(vals) - 1), gy1 - (gy1 - gy0) * (v - lo) / (hi - lo)) for i, v in enumerate(vals)]
        layer = Image.new("RGBA", c.img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(pts + [(gx1, gy1), (gx0, gy1)], fill=BLUE + (46,))
        c.img.paste(Image.alpha_composite(c.img.convert("RGBA"), layer).convert("RGB"))
        d = c.d = ImageDraw.Draw(c.img)
        d.line([(gx0, gy1), (gx1, gy1)], fill=CHIP, width=2)
        d.line(pts, fill=BLUE, width=4, joint="curve")
        lx, ly = pts[-1]
        d.ellipse([lx - 7, ly - 7, lx + 7, ly + 7], fill=FG, outline=BLUE, width=3)
        fa = font("Regular", 16)
        d.text((gx0, gy1 + 6), hist[0][0], font=fa, fill=MUT)
        d.text((gx1 - d.textlength(hist[-1][0], font=fa), gy1 + 6), hist[-1][0], font=fa, fill=MUT)
    c.y = y + 150
    changes = [f"{v} {k}" for k, v in (r.get("changes") or {}).items() if v]
    if warn:
        changes.append(f"{warn} figyelmeztetés")
    if changes:
        c.chips("Ma", changes)
    if fail:
        c.band("Hiba", str(r.get("error") or f"{r.get('fail')} sikertelen művelet")[:400], RED)
    return status, c.png()


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
