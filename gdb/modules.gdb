python
def print_callchain(depth=5):
    import gdb
    f = gdb.newest_frame()
    chain = []
    for i in range(depth):
        if f:
            sal = f.find_sal()
            fname = sal.symtab.filename.split('/')[-1] if sal.symtab else "?"
            func = f.name() or "?"
            chain.append(f"{fname}:{func}()")
            f = f.older()
    print(" <- ".join(chain))
end

break ssl_module_init
commands
  silent
  python print_callchain(5)
  printf "md: %p \n", md
  continue
end

break ssl_module_free
commands
  silent
  python print_callchain(5)
  printf "md: %p \n", md
  continue
end

break ssl/ssl_mcnf.c:67
commands
  silent
  python print_callchain(5)
  printf "libctx: %p \n ", libctx
  continue
end

