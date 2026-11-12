#!/bin/bash
# Compare the canonical configuration files from both repositories with the
# live /etc tree and print only the added (+) and removed (-) lines.
#
# Angie/Nginx files live in server-configs-nginx; PHP-FPM and all other
# service files live in ubuntu-setup-script.
set -u

SETUP_REPO="${SETUP_REPO:-https://raw.githubusercontent.com/droplinxuser/ubuntu-setup-script/main}"
CONFIG_REPO="${CONFIG_REPO:-https://raw.githubusercontent.com/droplinxuser/server-configs-nginx/main}"

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required." >&2; exit 1; }
command -v diff >/dev/null 2>&1 || { echo "Error: diff is required." >&2; exit 1; }

# compare_files <remote-url> <local-path>
# A missing local file or a failed download is reported and skipped, so one
# absent optional config does not abort the whole comparison.
compare_files() {
    local remote_url=$1 local_path=$2 tmp_remote_file diff_result
    if [[ ! -f $local_path ]]; then
        printf 'Skipped %s: not present on this host\n' "$local_path"
        return 0
    fi
    # Downloaded files stay under /tmp for inspection; the OS expires them.
    tmp_remote_file=$(mktemp /tmp/diff-configs.XXXXXX) || return 1
    if ! curl -fsSL --proto '=https' --tlsv1.2 "$remote_url" -o "$tmp_remote_file"; then
        printf 'Skipped %s: could not download %s\n' "$local_path" "$remote_url" >&2
        return 0
    fi
    diff_result=$(diff -u "$local_path" "$tmp_remote_file" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ')
    if [[ -n $diff_result ]]; then
        printf '\nDifferences in %s (- live, + canonical):\n%s\n' "$local_path" "$diff_result"
    fi
    return 0
}

# Remote URL and live path for every non-PHP file, compared in this order.
config_files=(
    "${SETUP_REPO}/configs/system/dns_servers.conf /etc/systemd/resolved.conf.d/dns_servers.conf"
    "${SETUP_REPO}/configs/system/sysctl.conf /etc/sysctl.conf"
    "${SETUP_REPO}/configs/system/limits.conf /etc/security/limits.d/99-setup.conf"
    "${SETUP_REPO}/configs/mariadb/limit_nofile.conf /etc/systemd/system/mariadb.service.d/limits.conf"
    "${SETUP_REPO}/configs/mariadb/mariadb_server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf"
    "${CONFIG_REPO}/angie.conf /etc/angie/angie.conf"
    "${CONFIG_REPO}/scripts/limit_nofile.conf /etc/systemd/system/angie.service.d/limits.conf"
    "${CONFIG_REPO}/scripts/etc_default_nginx /etc/default/angie"
    "${CONFIG_REPO}/http.d/ppa_eilander_conf /etc/angie/http.d/ppa_eilander.conf"
    "${CONFIG_REPO}/http.d/brotli_conf /etc/angie/http.d/brotli.conf"
    "${CONFIG_REPO}/http.d/http_trim_filter_conf /etc/angie/http.d/http_trim_filter.conf"
    "${CONFIG_REPO}/h5bp/wordpress_cache.conf /etc/angie/h5bp/wordpress_cache.conf"
)

for entry in "${config_files[@]}"; do
    read -r remote_url local_path <<< "$entry"
    compare_files "$remote_url" "$local_path"
done

# PHP: compare every installed FPM version; fall back to the template set
# shipped in configs/php when no version is installed yet.
php_versions=()
for d in /etc/php/*/fpm; do
    [[ -d $d ]] || continue
    v=${d%/fpm}; v=${v##*/}
    [[ $v =~ ^[0-9]+\.[0-9]+$ ]] && php_versions+=("$v")
done
[[ ${#php_versions[@]} -gt 0 ]] || php_versions=(8.1 8.2 8.3 8.4 8.5)

for version in "${php_versions[@]}"; do
    compare_files "${SETUP_REPO}/configs/php/www_${version//./}.conf" "/etc/php/${version}/fpm/pool.d/www.conf"
    compare_files "${SETUP_REPO}/configs/php/custom_dan.ini" "/etc/php/${version}/fpm/conf.d/custom_dan.ini"
    compare_files "${SETUP_REPO}/configs/php/php-fpm-limits.conf" "/etc/systemd/system/php${version}-fpm.service.d/limits.conf"
done
