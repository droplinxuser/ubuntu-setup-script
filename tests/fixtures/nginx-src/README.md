# nginx source fixtures

Cut-down stand-ins for the four nginx source files that `brand_patch`
(tools/nginx-build.sh) patches: each header filter has the two
`r->headers_out.server == NULL` tests, and the special response file has the
three `"<hr><center>` tail lines.  tests/unit/t-nginx-build.sh copies this
tree to a scratch directory and changes counts there to exercise the
refusal and the fallback version choice.  These files are not compiled.
