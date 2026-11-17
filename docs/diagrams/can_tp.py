"""ISO-TP's sequence and receive-state diagrams (docs/can-tp.md)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drawio import Diagram

out = sys.argv[1]

# ---- 1. a multi-frame transfer: 27 bytes, the receiver granting BS = 2 ----
d = Diagram('can-tp-sequence', 'A multi-frame transfer', 820, 535)
SX, RX = 250, 590
d.box(SX - 110, 20, 220, 44, 'Sender\nsend(), then poll() each pass', 'blue', bold=False)
d.box(RX - 110, 20, 220, 44, 'Receiver\non_frame(), then take()', 'blue', bold=False)
d.line([(SX, 64), (SX, 380)], '#999999', arrow=False, dashed=True)
d.line([(RX, 64), (RX, 380)], '#999999', arrow=False, dashed=True)

msgs = [  # (y at the sender's end, from sender?, label, colour)
    (100, True, 'FF   FF_DL = 27, bytes 1–6', '#333333'),
    (150, False, 'FC CTS   BS = 2, STmin', '#6c8ebf'),
    (200, True, 'CF   SN = 1, bytes 7–13', '#333333'),
    (250, True, 'CF   SN = 2, bytes 14–20', '#333333'),
    (300, False, 'FC CTS   the next block', '#6c8ebf'),
    (350, True, 'CF   SN = 3, bytes 21–27 (the last)', '#333333'),
]
for y, fwd, label, col in msgs:
    pts = [(SX, y), (RX, y + 8)] if fwd else [(RX, y), (SX, y + 8)]
    d.line(pts, col)
    d.text(SX + 20, y - 17, RX - SX - 40, 14, label, fs=11, color='#000000', align='center')

# the sender's timers, left of its lifeline
d.bar(SX - 12, 100, 8, 58)
d.text(SX - 132, 122, 116, 14, 'N_Bs ≤ 1000 ms', align='right', color='#a05f00', bold=True)
d.bar(SX - 12, 200, 8, 50, 'blue')
d.text(SX - 132, 218, 116, 14, '≥ STmin', align='right', color='#6c8ebf', bold=True)
d.bar(SX - 12, 250, 8, 58)
d.text(SX - 132, 272, 116, 14, 'N_Bs', align='right', color='#a05f00', bold=True)
# the receiver's, right of its lifeline
for y0, y1, lab in [(150, 208, 'N_Cr ≤ 1000 ms'), (208, 258, 'N_Cr'), (300, 358, 'N_Cr')]:
    d.bar(RX + 4, y0, 8, y1 - y0)
    d.text(RX + 18, (y0 + y1) / 2 - 7, 120, 14, lab, color='#a05f00', bold=True)
d.text(RX + 18, 272, 190, 14, 'not running: the block is complete', fs=10)
d.box(RX - 110, 380, 220, 36, 'complete: take() hands over 27 bytes', 'green', fs=11)

d.text(40, 440, 740, 100,
       'Both timers start when the frame is handed to the CAN controller: the link sees no transmit confirmation.\n'
       'N_Cr stops once a block is complete and starts again when the next CTS is handed over.\n'
       'FC WAIT restarts N_Bs, at most 16 in a row (WFTmax); FC OVFLW or an undefined flow status ends the transfer at once.\n'
       'While consecutive frames are leaving, N_Bs also bounds a transmit FIFO that stays full; each CF refreshes it.\n'
       'A first frame announcing more than 520 bytes is answered with FC OVFLW.',
       fs=11, color='#333333', valign='top')
d.write(f'{out}/can-tp-sequence.drawio.svg')

# ---- 2. the two state machines of a Link ----
s = Diagram('can-tp-states', 'Transmit and receive', 960, 495)
# transmit panel
s.box(20, 20, 480, 455, 'Transmit', 'grey', bold=True, valign='top')
s.box(180, 70, 120, 40, 'idle', 'plain')
s.box(180, 200, 120, 40, 'waiting for FC', 'plain')
s.box(180, 330, 120, 40, 'sending CFs', 'plain')
s.box(330, 195, 115, 50, 'abandoned\n(tx_aborts + 1)', 'red', fs=11)
# send() 1–7 bytes: a single frame, back to idle
s.line([(180, 82), (150, 82), (150, 98), (180, 98)])
s.text(30, 76, 114, 28, 'send(), 1–7 bytes:\none SF', align='right')
s.line([(225, 110), (225, 200)])
s.text(80, 141, 138, 28, 'send(), 8–520 bytes:\nFF; N_Bs starts', align='right')
s.line([(180, 212), (150, 212), (150, 228), (180, 228)])
s.text(30, 206, 114, 28, 'FC WAIT: N_Bs restarts,\nat most 16 in a row', align='right')
s.line([(225, 240), (225, 330)], '#6c8ebf')
s.text(80, 271, 138, 28, 'FC CTS:\nthe peer\'s BS, STmin', align='right')
s.line([(255, 330), (255, 240)])
s.text(262, 286, 110, 28, 'BS CFs sent:\nN_Bs starts')
s.line([(300, 220), (330, 220)], '#b85450')
s.line([(300, 345), (387, 345), (387, 245)], '#b85450')
s.line([(387, 195), (387, 98), (300, 98)], '#b85450')
s.line([(300, 360), (470, 360), (470, 82), (300, 82)], '#82b366')
s.text(310, 364, 150, 14, 'last CF handed over', color='#2d6a2d', bold=True)
s.text(36, 400, 456, 90,
       'Abandoned: N_Bs expired, a 17th WAIT in a row, FC OVFLW or flow status 3–15.\n'
       'A frame the CAN driver refuses: the owner calls abort_tx(), back to idle,\n'
       'not counted. A send() while not idle is refused: nothing is queued.\n'
       'The frame a transition names goes out on the owner\'s next poll().',
       fs=10, color='#333333', valign='top')

# receive panel
s.box(520, 20, 420, 455, 'Receive', 'grey', bold=True, valign='top')
s.box(660, 70, 120, 40, 'idle', 'plain')
s.box(660, 200, 120, 40, 'receiving', 'plain')
s.box(650, 330, 140, 40, 'message ready\nfor take()', 'green', fs=11)
s.line([(705, 110), (705, 200)])
s.text(546, 141, 152, 28, 'FF past an SF, ≤ 520 B:\nCTS; N_Cr starts', align='right')
s.line([(660, 212), (630, 212), (630, 228), (660, 228)])
s.text(526, 192, 98, 56, 'CF in sequence:\nN_Cr restarts;\nCTS after BS CFs\n(when BS > 0)', align='right')
s.line([(705, 240), (705, 330)], '#82b366')
s.text(600, 278, 98, 14, 'last CF', align='right', color='#2d6a2d', bold=True)
s.line([(735, 200), (735, 110)], '#b85450')
s.text(742, 141, 112, 28, 'wrong SN, N_Cr or\nN_Ar expired: discarded', color='#b85450', bold=True)
s.line([(780, 90), (870, 90), (870, 350), (790, 350)], '#82b366')
s.text(876, 206, 60, 28, 'SF,\n1–62 bytes', color='#2d6a2d', bold=True)
s.text(536, 400, 396, 103,
       'A valid SF or FF during a reception discards it; it starts over.\n'
       'An FF over 520 bytes (or the escape FF): FC OVFLW, nothing received.\n'
       'Ignored: an SF of length 0 or past its frame, an FF that fits an SF,\n'
       'a CF outside a reception or of the wrong length, a frame of a length\n'
       'no CAN-FD frame has, and any frame too short for its PCI.',
       fs=10, color='#333333', valign='top')
s.write(f'{out}/can-tp-states.drawio.svg')
