"""The diagnostic server's overview and session diagrams (docs/diagnostics.md)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drawio import Diagram

out = sys.argv[1]

# ---- overview ----
d = Diagram('diagnostics-overview', 'The diagnostic server and what it serves', 980, 450)
d.box(20, 90, 140, 40, 'CAN tester', 'plain')
d.box(20, 250, 140, 40, 'DoIP tester', 'plain')
d.box(200, 90, 130, 40, 'ISO-TP\n[isotp], can-tp.md', 'plain', fs=11)
d.box(200, 250, 130, 40, 'DoIP\n[doip], a target', 'plain', fs=11)
d.line([(160, 110), (200, 110)], both=True)
d.line([(160, 270), (200, 270)], both=True)
d.box(370, 30, 310, 405, 'comm thread (on the host: the bus bridge)', 'grey', bold=True, valign='top', fs=11)
d.box(395, 60, 260, 46, 'receive checks (§3.2): rx status,\nsignal-status faults', 'plain', fs=11)
d.box(395, 140, 200, 70, 'diagnostic server\ncomm/uds, comm/diag\nsessions, 0x27, service table', 'blue', fs=11)
d.box(395, 275, 120, 60, 'parameters\ncomm/param (§3.4)', 'plain', fs=11)
d.box(535, 275, 120, 60, 'fault memory\ncomm/fault (§3.3)', 'plain', fs=11)
d.box(395, 375, 260, 40, 'NvM journal (a target)', 'yellow', fs=11)
d.line([(330, 110), (360, 110), (360, 165), (395, 165)], both=True)
d.line([(330, 270), (360, 270), (360, 190), (395, 190)], both=True)
d.line([(455, 210), (455, 275)], both=True)
d.text(460, 228, 70, 28, '0x2E\n0x22')
d.line([(565, 210), (565, 275)], both=True)
d.text(570, 228, 58, 28, '0x19 0x14\n0x85')
d.line([(630, 106), (630, 275)])
d.line([(455, 335), (455, 375)], both=True)
d.line([(595, 335), (595, 375)], both=True)
# FB side
d.box(760, 30, 200, 405, 'FB threads (or a satellite core)', 'grey', bold=True, valign='top', fs=11)
d.box(780, 140, 160, 44, 'FB handler\nwrites a test result', 'plain', fs=11)
d.box(780, 285, 160, 44, 'debounce (generated)\nright after the handler', 'plain', fs=11)
d.box(780, 375, 160, 40, 'FB: reads a parameter\n(an In field)', 'plain', fs=11)
d.line([(860, 184), (860, 285)])
d.line([(780, 297), (655, 297)])
d.text(686, 268, 72, 26, 'report cell:\nstate, counters', fs=9)
d.line([(655, 320), (780, 320)])
d.text(686, 323, 72, 38, 'control cell:\nclear\ngenerations', fs=9)
d.line([(395, 320), (383, 320), (383, 427), (740, 427), (740, 395), (780, 395)])
d.write(f'{out}/diagnostics-overview.drawio.svg')

# ---- sessions ----
s = Diagram('diagnostics-sessions', 'Sessions and security', 900, 430)
s.box(60, 170, 140, 44, 'default (01)\nat power-up', 'blue')
s.box(380, 80, 160, 44, 'extended (03)', 'plain')
s.box(380, 250, 160, 44, 'safety (04)', 'plain')
s.box(680, 72, 200, 60, 'programming (02)\nin the bootloader', 'grey', dashed=True)
s.line([(130, 170), (130, 92), (380, 92)])
s.text(200, 76, 160, 14, '0x10 03', color='#000000')
s.line([(380, 112), (160, 112), (160, 170)])
s.text(170, 116, 205, 14, '0x10 01, S3 expired, a reset')
s.line([(130, 214), (130, 282), (380, 282)])
s.text(200, 286, 160, 14, '0x10 04', color='#000000')
s.line([(380, 262), (160, 262), (160, 214)])
s.text(170, 244, 205, 14, '0x10 01, S3 expired, a reset')
s.line([(440, 124), (440, 250)])
s.text(446, 180, 50, 14, '0x10 04', color='#000000')
s.line([(500, 250), (500, 124)])
s.text(506, 180, 50, 14, '0x10 03', color='#000000')
s.line([(420, 80), (420, 55), (500, 55), (500, 80)])
s.text(360, 22, 200, 28, '0x27 seed, then key:\nlevel L unlocked', align='center', color='#2d6a2d', bold=True)
s.line([(540, 100), (680, 100)], '#a05f00')
s.text(545, 66, 132, 28, '0x10 02 on a [boot] node:\n0x50 02, then a reset', color='#a05f00', bold=True)
s.text(40, 330, 840, 90,
       'Every session entry relocks security, re-entering the same session included.\n'
       'Returning to default re-enables communication (0x28) and turns DTC setting (0x85) back on; extended <-> safety keeps them.\n'
       'S3 (5 s by default) runs only while no exchange is in flight; 0x3E keeps the session. 0x27, 0x28 and 0x85 run only outside default.\n'
       'Without [boot], 0x10 02 answers 0x12. With it, the handoff is accepted from extended unless its "0x10 02" row says otherwise.\n'
       'A non-default session holds NM awake.',
       fs=11, color='#333333', valign='top')
s.write(f'{out}/diagnostics-sessions.drawio.svg')
