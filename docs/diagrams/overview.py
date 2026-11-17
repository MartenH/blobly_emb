"""How a node is made and where it runs: ecu.toml and the DBC, the generators, the node's code,
its targets, and Blobly Net testing it (README.md)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drawio import Diagram

d = Diagram('overview', 'From ecu.toml to a running ECU', 980, 480)
# inputs
d.box(20, 40, 150, 50, 'ecu.toml\none node\'s configuration', 'yellow', fs=11)
d.box(20, 110, 150, 50, 'bus DBC\nframes and signals', 'yellow', fs=11)
d.box(20, 180, 150, 50, 'system.toml\na system of nodes (optional)', 'yellow', fs=11)
d.box(20, 260, 150, 50, 'app/\nyour Function Blocks', 'orange', fs=11)
# generators
d.box(210, 40, 160, 190, 'make gen\n\ndbc2cfg\necucheck\ncfg2v\nloom2v\nsigmap', 'grey', fs=11)
for y in (65, 135, 205):
    d.line([(170, y), (210, y)])
d.text(210, 236, 160, 40, 'schema-checked; unsafe\nconfigurations refused', fs=10)
# the node
d.box(410, 20, 330, 300, 'one node: static code, no heap', 'grey', bold=True, valign='top', fs=12)
d.box(430, 50, 290, 44, 'Function Blocks on the Loom\nper-thread schedulers, typed ports', 'orange', fs=11)
d.box(430, 104, 290, 44, 'COM: codec, TX modes, RX deadlines,\nE2E, SecOC', 'blue', fs=11)
d.box(430, 158, 290, 44, 'diagnostics: ISO-TP, UDS, fault memory,\nparameters, routines, IO control', 'blue', fs=11)
d.box(430, 212, 290, 44, 'NvM journal, network management,\nDoIP and SOME/IP, bootloader', 'blue', fs=11)
d.text(430, 264, 290, 44, 'generated: the codec, ports, wiring and images;\nthe stack itself is library code it configures', fs=10, color='#333333')
d.line([(370, 135), (410, 135)])
d.line([(170, 285), (390, 285), (390, 72), (430, 72)])
# targets
d.box(410, 370, 155, 70, 'Linux process\non vcan (simulation)', 'green', fs=11)
d.box(585, 370, 155, 70, 'STM32H7\nThreadX AMP or bare metal', 'green', fs=11)
d.line([(487, 320), (487, 370)])
d.line([(662, 320), (662, 370)])
# the tester: DoIP only where the target has it (a ThreadX node with Ethernet)
d.box(800, 370, 160, 70, 'Blobly Net\ntests both', 'plain', bold=True, fs=11)
d.line([(800, 405), (740, 405)], both=True)
d.text(742, 380, 58, 22, 'CAN, CAN-FD,\nDoIP', fs=9, align='center')
d.line([(880, 440), (880, 458), (487, 458), (487, 440)], both=True)
d.text(600, 459, 160, 14, 'CAN, CAN-FD', fs=9, align='center')
d.write(os.path.join(sys.argv[1], 'overview.drawio.svg'))
