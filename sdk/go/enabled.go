// SPDX-License-Identifier: MIT

//go:build !determinismo_off

package determinismo

// disabled is true in builds with the tag determinismo_off: every call a no-op.
const disabled = false
