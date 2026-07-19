/* Temporary ARM64 link veneers.  These establish the symbols required by the
   runtime while the full TLS signal-stack transition is being ported. */
	.text
	.p2align 2
	.global sigdelayed
	.global _sigbe
	.global _sigdelayed_end
sigdelayed:
_sigbe:
	ret
_sigdelayed_end:

	/* Keep the ABI exports out of the early loader text. */
	.section .text.zsigsetjmp,"xr"
	.p2align 2
	.global sigsetjmp
	sigsetjmp:
	str x1, [x0, #176]
	b setjmp

	.global siglongjmp
	siglongjmp:
	b longjmp
