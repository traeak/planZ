/* What main.c and pool.c need from the host, kept apart from them
 * because they are compiled with Plan 9's type sizes (include/u.h). */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/mman.h>

int print(char *fmt, ...){
	/* the few verbs main.c uses; Plan 9's %lud and %llux are not C's */
	va_list a; va_start(a, fmt); vprintf(fmt, a); va_end(a); return 0;
}
void werrstr(char *fmt, ...){ (void)fmt; }
void *mapregion(unsigned long base, unsigned long size){
	void *v = mmap((void*)base, size, PROT_READ|PROT_WRITE,
		MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE, -1, 0);
	if(v != (void*)base){ fprintf(stderr, "poolref: cannot map %#lx\n", base); exit(1); }
	return v;
}
void unmapregion(void *v, unsigned long size){ munmap(v, size); }
unsigned long envnum(char *name, unsigned long def){
	char *s = getenv(name);
	return s ? strtoul(s, 0, 0) : def;
}
void flushout(void){ fflush(stdout); }
