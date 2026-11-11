#define USED(...) ((void)0)
#define nelem(x) (sizeof(x)/sizeof((x)[0]))
extern void *memset(void*, int, usize_t_);
extern void *memmove(void*, const void*, usize_t_);
extern int print(char*, ...);
extern void werrstr(char*, ...);
extern void abort(void);
#define assert(x) do{ if(!(x)){ print("assert failed: %s\n", #x); abort(); } }while(0)
