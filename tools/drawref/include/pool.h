typedef struct Pool Pool;
struct Pool { char *name; void (*move)(void*, void*); };
extern Pool *imagmem;
extern void *poolalloc(Pool*, usize_t_);
extern void poolfree(Pool*, void*);
