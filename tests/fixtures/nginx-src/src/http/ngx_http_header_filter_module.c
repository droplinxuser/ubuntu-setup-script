/*
 * Test fixture for tests/unit/t-nginx-build.sh: the two places the http11
 * header filter tests r->headers_out.server, cut down to what brand_patch
 * counts (tools/nginx-build.sh).  Not a compilable source file.
 */

static ngx_int_t
fixture_http11_header_length(ngx_http_request_t *r, ngx_http_core_loc_conf_t *clcf)
{
    size_t  len = 0;

    if (r->headers_out.server == NULL) {
        if (clcf->server_tokens == NGX_HTTP_SERVER_TOKENS_ON) {
            len += sizeof(fixture_server_full_string) - 1;
        } else {
            len += sizeof(fixture_server_string) - 1;
        }
    }

    return len;
}

static u_char *
fixture_http11_header_write(ngx_http_request_t *r, ngx_http_core_loc_conf_t *clcf, u_char *p)
{
    if (r->headers_out.server == NULL) {
        if (clcf->server_tokens == NGX_HTTP_SERVER_TOKENS_ON) {
            p = ngx_cpymem(p, fixture_server_full_string,
                           sizeof(fixture_server_full_string) - 1);
        }
    }

    return p;
}
