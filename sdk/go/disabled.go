// SPDX-License-Identifier: MIT

//go:build determinismo_off

package determinismo

// disabled: built with the tag determinismo_off, every call is a no-op (randomness from the OS).
const disabled = true
