#!/bin/bash

# Function to compare two files and output only added (+) and removed (-) lines
compare_files() {
    local remote_url=$1
    local local_path=$2

    # Download remote file to temporary location
    tmp_remote_file=$(mktemp)
    if ! curl -sSL "$remote_url" -o "$tmp_remote_file"; then
        echo "Error: Failed to download remote file from $remote_url."
        exit 1
    fi

    # Compare files and display only added (+) and removed (-) lines
    if ! command -v diff &> /dev/null; then
        echo "Error: diff command not found."
        exit 1
    fi

    diff_result=$(diff -u "$local_path" "$tmp_remote_file" | grep -E '^[+-]')

    if [ -n "$diff_result" ]; then
        printf "\n"
        printf "Differences in %s:\n%s\n" "$local_path" "$diff_result"
    fi

    # Clean up temporary files
    rm -f "$tmp_remote_file"
}

# Compare configurations for Ubuntu Server 26.04
#
# Angie/Nginx files live in server-configs-nginx; PHP-FPM and all other
# service files live in ubuntu-setup-script.

SETUP_REPO="${SETUP_REPO:-https://raw.githubusercontent.com/droplinxuser/ubuntu-setup-script/main}"
CONFIG_REPO="${CONFIG_REPO:-https://raw.githubusercontent.com/droplinxuser/server-configs-nginx/main}"

# Define remote URLs and local paths
declare -A config_files=(
    ["dns_servers"]="${SETUP_REPO}/configs/system/dns_servers.conf /etc/systemd/resolved.conf.d/dns_servers.conf"
    ["cpufrequtils"]="${SETUP_REPO}/configs/system/cpufrequtils /etc/default/cpufrequtils"
    ["sysctl"]="${SETUP_REPO}/configs/system/sysctl.conf /etc/sysctl.conf"
    ["limits"]="${SETUP_REPO}/configs/system/limits.conf /etc/security/limits.d/99-setup.conf"
    ["mariadb_service_limits"]="${SETUP_REPO}/configs/mariadb/limit_nofile.conf /etc/systemd/system/mariadb.service.d/limits.conf"
    ["mariadb_server"]="${SETUP_REPO}/configs/mariadb/mariadb_server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf"
    ["angie_conf"]="${CONFIG_REPO}/angie.conf /etc/angie/angie.conf"
    ["angie_conf_deployer"]="${CONFIG_REPO}/scripts/nginx_conf.sh /etc/angie/scripts/nginx_conf.sh"
    ["angie_service_limits"]="${CONFIG_REPO}/scripts/limit_nofile.conf /etc/systemd/system/angie.service.d/limits.conf"
    ["angie_default"]="${CONFIG_REPO}/scripts/etc_default_nginx /etc/default/angie"
    ["angie_additional"]="${CONFIG_REPO}/http.d/ppa_eilander_conf /etc/angie/http.d/ppa_eilander.conf"
    ["brotli_conf"]="${CONFIG_REPO}/http.d/brotli_conf /etc/angie/http.d/brotli.conf"
    ["http_trim_filter_conf"]="${CONFIG_REPO}/http.d/http_trim_filter_conf /etc/angie/http.d/http_trim_filter.conf"
    ["wordpress_cache"]="${CONFIG_REPO}/h5bp/wordpress_cache.conf /etc/angie/h5bp/wordpress_cache.conf"
    ["php_fpm_limits"]="${SETUP_REPO}/configs/php/php-fpm-limits.conf /etc/systemd/system/php8.5-fpm.service.d/limits.conf"
)

# PHP Versions
php_versions=(1 2 3 4 5)

# Compare configurations
for file_name in "${!config_files[@]}"; do
    read -r -a urls_and_paths <<< "${config_files[$file_name]}"
    remote_url="${urls_and_paths[0]}"
    local_path="${urls_and_paths[1]}"
    compare_files "$remote_url" "$local_path"
done

# Compare PHP configurations for different versions
for version in "${php_versions[@]}"; do
    compare_files "${SETUP_REPO}/configs/php/www_8${version}.conf" "/etc/php/8.${version}/fpm/pool.d/www.conf"
    compare_files "${SETUP_REPO}/configs/php/custom_dan.ini" "/etc/php/8.${version}/fpm/conf.d/custom_dan.ini"
done
