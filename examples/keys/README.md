# Development signing key — NOT FOR PRODUCTION

`dev.seed` is a **development** Ed25519 seed (32 bytes, `00 01 .. 1f`) used to
sign example images so the bootloader's signature-verify path can be exercised
end to end. The matching public key is baked into the boot manager
(`examples/h755_boot/main.v`, `examples/boot_sim/main.v`) as `dev_pubkey`:

    03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8

A real deployment generates its own keypair, keeps the **seed off every ECU and
build machine** (an HSM / signing service owns it — REQ-BOOT-011), and bakes only
the public key into the immutable boot manager. Never ship this seed.

Sign an image:  `v run tools/mkimage app.bin app.img <ver> --pad-vectors --sign examples/keys/dev.seed`
