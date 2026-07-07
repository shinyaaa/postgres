#!/usr/bin/env python3
"""Render the pg_undo README demo GIF: a simulated psql session that
replays real captured output with a typing animation."""

from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
FSIZE = 15
LINE_H = 22
PAD_X = 14
PAD_Y = 10
TITLE_H = 30
COLS = 84
ROWS = 19
W = PAD_X * 2 + int(COLS * 9.03)
H = TITLE_H + PAD_Y * 2 + ROWS * LINE_H

C_BG = (13, 17, 23)
C_TITLE = (22, 27, 34)
C_TEXT = (201, 209, 217)
C_PROMPT = (126, 231, 135)
C_CMD = (230, 237, 243)
C_OUT = (139, 148, 158)
C_TBL = (173, 186, 199)
C_COMMENT = (255, 166, 87)
C_NOTICE = (121, 192, 255)
C_RED = (255, 123, 114)
C_OK = (126, 231, 135)

PROMPT = "demo=# "

font = ImageFont.truetype(FONT, FSIZE)
font_b = ImageFont.truetype(FONT_B, FSIZE)

# (kind, payload)
#  kind "cmd": (command, [(line, color), ...], pause_ms)
#  kind "comment": (text, pause_ms, color)
T1_OUT = [
    (" id | name  | plan ", C_TBL),
    ("----+-------+------", C_OUT),
    ("  1 | alice | pro", C_TBL),
    ("  2 | bob   | free", C_TBL),
    ("  3 | carol | pro", C_TBL),
    ("  4 | dave  | free", C_TBL),
    ("(4 rows)", C_OUT),
    ("", C_OUT),
]

SCRIPT = [
    ("cmd", "SELECT * FROM users ORDER BY id;", T1_OUT, 1300),
    ("cmd", "DELETE FROM users;", [("DELETE 4", C_OUT), ("", C_OUT)], 700),
    ("comment", "-- ...that was missing a WHERE clause.", 1600, C_RED),
    ("comment", "-- pg_undo captured every row. Look:", 900, C_COMMENT),
    ("cmd", "SELECT * FROM undo.preview(last => '5 minutes', \"table\" => 'users');",
     [
         (" seq | op |                        undo_sql", C_TBL),
         ("-----+----+------------------------------------------------------------", C_OUT),
         ("   1 | D  | INSERT INTO users (id, name, plan) SELECT id, name, plan f…", C_TBL),
         ("   2 | D  | INSERT INTO users (id, name, plan) SELECT id, name, plan f…", C_TBL),
         ("   3 | D  | INSERT INTO users (id, name, plan) SELECT id, name, plan f…", C_TBL),
         ("   4 | D  | INSERT INTO users (id, name, plan) SELECT id, name, plan f…", C_TBL),
         ("(4 rows)", C_OUT),
         ("", C_OUT),
     ], 1500),
    ("cmd", "SELECT * FROM undo.apply(last => '5 minutes', \"table\" => 'users');",
     [
         (" applied | skipped | conflicts ", C_TBL),
         ("---------+---------+-----------", C_OUT),
         ("       4 |       0 |         0", C_OK),
         ("(1 row)", C_OUT),
         ("", C_OUT),
     ], 1200),
    ("cmd", "SELECT * FROM users ORDER BY id;", T1_OUT, 1800),
    ("comment", "-- even DROP TABLE has an undo:", 1100, C_COMMENT),
    ("cmd", "DROP TABLE users;",
     [
         ("NOTICE:  pg_undo: moved table \"public.users\" to the recycle bin", C_NOTICE),
         ("DROP TABLE", C_OUT),
         ("", C_OUT),
     ], 1300),
    ("cmd", "SELECT undo.restore_dropped('users');",
     [
         ("NOTICE:  pg_undo: restored public.users", C_NOTICE),
         (" restore_dropped ", C_TBL),
         ("-----------------", C_OUT),
         (" users", C_TBL),
         ("(1 row)", C_OUT),
         ("", C_OUT),
     ], 1200),
    ("cmd", "SELECT count(*) FROM users;",
     [
         (" count ", C_TBL),
         ("-------", C_OUT),
         ("     4", C_OK),
         ("(1 row)", C_OUT),
         ("", C_OUT),
     ], 1400),
    ("comment", "-- pg_undo: Ctrl+Z for PostgreSQL", 3500, C_OK),
]

frames = []
durations = []
lines = []  # committed lines: (text, color) or ("__prompt__" + cmdpart)


def render(current=None, cursor=False):
    """current: (typed_text, color) still on the prompt line."""
    img = Image.new("RGB", (W, H), C_BG)
    d = ImageDraw.Draw(img)
    # title bar
    d.rectangle([0, 0, W, TITLE_H], fill=C_TITLE)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([12 + i * 20, 9, 24 + i * 20, 21], fill=c)
    title = "psql — pg_undo demo"
    tw = d.textlength(title, font=font)
    d.text(((W - tw) / 2, 7), title, font=font, fill=C_OUT)

    visible = lines[-(ROWS - (1 if current is not None else 0)):]
    y = TITLE_H + PAD_Y
    for text, color in visible:
        if text.startswith("\x01"):  # prompt line: prompt + command
            d.text((PAD_X, y), PROMPT, font=font_b, fill=C_PROMPT)
            px = PAD_X + d.textlength(PROMPT, font=font_b)
            d.text((px, y), text[1:], font=font, fill=C_CMD)
        else:
            d.text((PAD_X, y), text, font=font, fill=color)
        y += LINE_H
    if current is not None:
        typed, _ = current
        d.text((PAD_X, y), PROMPT, font=font_b, fill=C_PROMPT)
        px = PAD_X + d.textlength(PROMPT, font=font_b)
        d.text((px, y), typed, font=font, fill=C_CMD)
        if cursor:
            cx = px + d.textlength(typed, font=font)
            d.rectangle([cx + 1, y + 2, cx + 9, y + LINE_H - 4], fill=C_TEXT)
    return img.quantize(colors=64)


def emit(img, ms):
    frames.append(img)
    durations.append(ms)


# opening prompt with blinking cursor
for i in range(3):
    emit(render(current=("", None), cursor=(i % 2 == 0)), 400)

for step in SCRIPT:
    if step[0] == "comment":
        _, text, pause, color = step
        typed = ""
        for i in range(0, len(text), 3):
            typed = text[: i + 3]
            emit(render(current=(typed, None), cursor=True), 40)
        lines.append(("\x01" if False else typed, color))
        # commit comment as plain colored line
        lines[-1] = (typed, color)
        emit(render(current=("", None), cursor=True), pause)
        continue

    _, cmd, out, pause = step
    typed = ""
    for i in range(0, len(cmd), 3):
        typed = cmd[: i + 3]
        emit(render(current=(typed, None), cursor=True), 40)
    emit(render(current=(typed, None), cursor=False), 350)
    lines.append(("\x01" + cmd, None))
    for oline in out:
        lines.append(oline)
    emit(render(current=("", None), cursor=True), pause)

# hold final frame
emit(render(current=("", None), cursor=False), 2500)

frames[0].save(
    "demo.gif",
    save_all=True,
    append_images=frames[1:],
    duration=durations,
    loop=0,
    optimize=True,
    disposal=2,
)
print(f"frames={len(frames)} size={W}x{H}")
