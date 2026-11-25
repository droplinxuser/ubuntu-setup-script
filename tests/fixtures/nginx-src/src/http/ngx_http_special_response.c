/*
 * Test fixture for tests/unit/t-nginx-build.sh: the three error page tails
 * of the special response module, cut down to what brand_patch counts
 * (tools/nginx-build.sh).  Not a compilable source file.
 */

static u_char fixture_error_full_tail[] =
"<hr><center>" NGINX_VER "</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;


static u_char fixture_error_build_tail[] =
"<hr><center>" NGINX_VER_BUILD "</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;


static u_char fixture_error_tail[] =
"<hr><center>nginx</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;


static char fixture_error_404_page[] =
"<html>" CRLF
"<head><title>404 Not Found</title></head>" CRLF
"<body>" CRLF
"<center><h1>404 Not Found</h1></center>" CRLF
;
