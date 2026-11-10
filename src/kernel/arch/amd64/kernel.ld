/*
 * Kernel link layout for amd64.
 * etext, edata and end are the symbols the Plan 9 loader provides.
 * The start address must match KTZERO in mem.zig.
 */
ENTRY(_start)

PHDRS
{
	text PT_LOAD FLAGS(5);		/* r-x */
	rodata PT_LOAD FLAGS(4);	/* r-- */
	data PT_LOAD FLAGS(6);		/* rw- */
}

SECTIONS
{
	. = 0xffffffff80110000;

	.text : ALIGN(4K) {
		*(.text .text.*)
	} :text
	PROVIDE(etext = .);

	.rodata : ALIGN(4K) {
		*(.rodata .rodata.*)
	} :rodata

	.data : ALIGN(4K) {
		*(.data .data.*)
	} :data
	PROVIDE(edata = .);

	.bss : ALIGN(4K) {
		*(.bss .bss.*)
		*(COMMON)
	} :data
	PROVIDE(end = .);

	/DISCARD/ : {
		*(.eh_frame*)
		*(.comment)
		*(.note*)
	}
}
