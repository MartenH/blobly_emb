// vrt is what V's builtin needs from a bare-metal target. Its hooks are in
// vrt_d_freestanding.v, compiled only for a `-freestanding` image; an image's main.v
// imports this module (`import osal.vrt as _`) for them and calls nothing in it.
module vrt
