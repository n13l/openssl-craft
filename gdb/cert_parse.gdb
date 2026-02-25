dashboard -enabled off

break x509_pubkey_ex_d2i_ex
commands
  silent
  python print_callchain(55)
  continue
end

break crypto/x509/x_pubkey.c:238
commands
  silent
  python print_callchain(55)
  printf "ret value: %d\n", ret
  continue
end

break crypto/x509/x_pubkey.c:221
commands
  silent
  python print_callchain(55)
  printf "slen: %d\n", slen
  continue
end

