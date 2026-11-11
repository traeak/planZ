#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
typedef struct Pool { char *name; void (*move)(void*, void*); } Pool;
static Pool pool0 = { "Image" };
Pool *imagmem = &pool0;
void *poolalloc(Pool *p, unsigned long n){ (void)p; return calloc(1, n); }
void poolfree(Pool *p, void *v){ (void)p; free(v); }
void *mallocz(unsigned long n, int clr){ void *v = malloc(n); if(v && clr) memset(v, 0, n); return v; }
int print(char *fmt, ...){ fprintf(stderr, "print: %s\n", fmt); return 0; }
void werrstr(char *fmt, ...){ (void)fmt; }
void sysfatal(char *fmt, ...){ fprintf(stderr, "sysfatal: %s\n", fmt); exit(1); }
unsigned long getcallerpc(void *v){ (void)v; return 0; }
int _tas(int *p){ int o = *p; *p = 1; return o; }
int fmtinstall(int c, void *f){ (void)c; (void)f; return 0; }
int Rfmt(void *f){ (void)f; return 0; }
int Pfmt(void *f){ (void)f; return 0; }
int _ifmt(void *f){ (void)f; return 0; }
void setmalloctag(void *v, unsigned long pc){ (void)v; (void)pc; }
int chartorune(unsigned int *r, char *s){ *r = (unsigned char)*s; return 1; }
int cloadmemimage(void *i, ...){ (void)i; abort(); return -1; }
int iprint(char *fmt, ...){ (void)fmt; return 0; }
int drawdebug;
