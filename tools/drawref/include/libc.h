typedef struct Fmt Fmt;
typedef signed char schar;
typedef struct QLock { int x; } QLock;
typedef struct RWLock { int x; } RWLock;
typedef struct Lock { int x; } Lock;
#define USED(...) ((void)0)
#define SET(x)
#define nelem(x) (sizeof(x)/sizeof((x)[0]))
enum { Runeself = 0x80, UTFmax = 4, ERRMAX = 128 };
extern void *malloc(usize_t_);
extern void *mallocz(usize_t_, int);
extern void free(void*);
extern void *memset(void*, int, usize_t_);
extern void *memmove(void*, const void*, usize_t_);
extern void *memcpy(void*, const void*, usize_t_);
extern int memcmp(const void*, const void*, usize_t_);
extern usize_t_ strlen(const char*);
extern char *strcpy(char*, const char*);
extern char *strchr(const char*, int);
extern char *strdup(const char*);
extern int print(char*, ...);
extern int fprint(int, char*, ...);
extern int sprint(char*, char*, ...);
extern int snprint(char*, int, char*, ...);
extern void werrstr(char*, ...);
extern void qsort(void*, usize_t_, usize_t_, void*);
extern int abs(int);
extern int chartorune(Rune*, char*);
extern void abort(void);
extern void sysfatal(char*, ...);
extern uintptr getcallerpc(void*);
extern int _tas(int*);
extern int fmtinstall(int, void*);
extern int strcmp(const char*, const char*);
#define assert(x) do{ if(!(x)){ print("assert failed: %s\n", #x); abort(); } }while(0)
extern void setmalloctag(void*, uintptr);
#define malloc(n) mallocz((n), 1)
extern int atoi(const char*);
