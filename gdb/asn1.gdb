dashboard -enabled off

break ossl_c2i_ASN1_INTEGER
commands
  silent
  printf "ASN1_INTEGER (bytes: %d)\n", len
  hex_dump (*pp)-10 len+10
  continue
end

rbreak ossl_c2i_ASN1_INTEGER.*ret 
commands
  silent
  printf "ASN1_INTEGER (bytes: %d)\n", len
  hex_dump (*pp)-10 len+10
  printf "ret: %p\n", $rax  
  continue
end
