/*
 * Link a Plan 9 amd64 executable (a.out) for planZ's user programs.
 *
 * The file is the memory image of the text segment from UTZERO on:
 * a 40-byte header, the text, and then the initialised data, which
 * the kernel maps at the next 2MiB boundary.  The header is written
 * here, big-endian as a.out wants, so that `objcopy -O binary` of the
 * result is the executable.  See /sys/include/a.out.h and sysexec.
 */
ENTRY(_start)

UTZERO = 0x200000;
HDRSZ = 40;
S_MAGIC = 0x8000 | ((4 * 26) * 26 + 7);

SECTIONS
{
	. = UTZERO;

	.text : {
		/* Exec: magic, text, data, bss, syms, entry, spsz, pcsz */
		BYTE(((S_MAGIC) >> 24) & 0xff) BYTE(((S_MAGIC) >> 16) & 0xff) BYTE(((S_MAGIC) >> 8) & 0xff) BYTE(((S_MAGIC) >> 0) & 0xff)
		BYTE(((etext - UTZERO - HDRSZ) >> 24) & 0xff) BYTE(((etext - UTZERO - HDRSZ) >> 16) & 0xff) BYTE(((etext - UTZERO - HDRSZ) >> 8) & 0xff) BYTE(((etext - UTZERO - HDRSZ) >> 0) & 0xff)
		BYTE(((edata - sdata) >> 24) & 0xff) BYTE(((edata - sdata) >> 16) & 0xff) BYTE(((edata - sdata) >> 8) & 0xff) BYTE(((edata - sdata) >> 0) & 0xff)
		BYTE(((end - edata) >> 24) & 0xff) BYTE(((end - edata) >> 16) & 0xff) BYTE(((end - edata) >> 8) & 0xff) BYTE(((end - edata) >> 0) & 0xff)
		LONG(0)
		BYTE(((_start) >> 24) & 0xff) BYTE(((_start) >> 16) & 0xff) BYTE(((_start) >> 8) & 0xff) BYTE(((_start) >> 0) & 0xff)
		LONG(0)
		LONG(0)
		/* the 64-bit entry point that HDR_MAGIC adds */
		BYTE(((_start) >> 56) & 0xff) BYTE(((_start) >> 48) & 0xff) BYTE(((_start) >> 40) & 0xff) BYTE(((_start) >> 32) & 0xff) BYTE(((_start) >> 24) & 0xff) BYTE(((_start) >> 16) & 0xff) BYTE(((_start) >> 8) & 0xff) BYTE(((_start) >> 0) & 0xff)

		/* _start must be first: initcode is entered at UTZERO+0x28 */
		KEEP(*(.text.start))
		*(.text .text.*)
		*(.rodata .rodata.*)
	}
	etext = .;

	. = ALIGN(0x200000);
	sdata = .;
	.data : AT(etext) {
		*(.data .data.*)
	}
	edata = .;

	.bss : {
		*(.bss .bss.*)
		*(COMMON)
	}
	end = .;

	/DISCARD/ : {
		*(.eh_frame*)
		*(.comment)
		*(.note*)
	}
}
