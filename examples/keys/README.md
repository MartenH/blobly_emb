# Development keys — NOT FOR PRODUCTION

Two **separate** Ed25519 keys, one per role — named for what consumes them.
Different keys mean different custody and different blast radius if one leaks.

| file | role | private half used by | public half baked into boot as | leak impact |
|---|---|---|---|---|
| `mkimage.seed` | **release / image signing** | `tools/mkimage --sign` (build/release, offline) | `image_key` | **forged firmware** (catastrophic) |
| `tester.seed` | **tester / session (0x29)** | `cmd/flash`, the GUI Flash panel (in the field) | `session_key` | start sessions only (annoyance) |

Public keys baked into the boot manager (`examples/h755_boot/main.v`,
`examples/boot_sim/main.v`):

    image_key   = 03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8
    session_key = 29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7

Production: generate your own, keep **both private seeds off every ECU**. The
release seed lives only in a signing service / HSM; the tester seed lives with
the technician (ideally a smartcard / per-technician PKI, not a shared file).
Never ship either of these.

Usage:
- sign an image:  `v run tools/mkimage app.bin app.img <ver> --pad-vectors --sign examples/keys/mkimage.seed`
- the flasher's 0x29 seed:  `$BLOBLY_FLASH_SEED` (64 hex) or `examples/keys/tester.seed`
