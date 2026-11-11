# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# ANGIE
# ---------------------------------------------------------------------------
# =============================================================================
# HARDWARE-AWARE LIVE TUNING
# -----------------------------------------------------------------------------
# These helpers are used both by the installers and by `--optimize`.  They
# only rewrite live configuration; they never install packages.
# =============================================================================
TUNE_CHANGES=()
TUNE_MISSES=()
TUNE_DIRTY=0
# Only repoint Angie's FastCGI upstream when the optimized PHP pool already
# owns a Unix socket.  --optimize preserves an existing TCP listener so a live
# site is never pointed at a socket that does not exist.
OPT_PHP_OK=0
OPT_PHP_SOCKET=""
tune_reset_changes() { TUNE_CHANGES=(); TUNE_MISSES=(); TUNE_DIRTY=0; }
tune_note() { TUNE_CHANGES+=("$*"); TUNE_DIRTY=1; }
# Informational line that must not count as a configuration change (and must
# not trigger a service restart on an otherwise unchanged run).
tune_summary() { TUNE_CHANGES+=("$*"); }
# A directive that was expected in an existing file but could not be found.
# Recorded instead of silently doing nothing, so config drift is visible in
# the report without forcing a restart.
tune_miss() { TUNE_MISSES+=("$*"); }

tune_clamp() {
  local value=$1 min=$2 max=$3
  (( value < min )) && value=$min
  (( value > max )) && value=$max
  printf '%s' "$value"
}

# Tuner-facing name for mb_to_config(); one implementation keeps the installer
# and --optimize reporting identical.
tune_size_value() { mb_to_config "$1"; }

# Cache budget in MB: 25% of RAM, capped at 5% of free disk, then rounded
# down to 256 MB.  The rounding keeps small free-space changes between runs
# (backups, logs) from resizing every cache zone and forcing a restart.
tune_cache_total_mb() {
  local ram_mb=$1 disk_free_mb=$2 ram_pct=${3:-25} disk_pct=${4:-5} total
  total=$(( ram_mb * ram_pct / 100 ))
  (( total > 65536 )) && total=65536
  (( total > disk_free_mb * disk_pct / 100 )) && total=$(( disk_free_mb * disk_pct / 100 ))
  (( total < 256 )) && total=256
  total=$(( total / 256 * 256 ))
  (( total < 256 )) && total=256
  printf '%s' "$total"
}

# Angie cache budget for the current service set.  A dedicated Angie proxy
# gets 50% of RAM (10% of free disk); Angie+PHP gets 30%; a host with a data
# or search tier gets 25% (5% of free disk).  Callers pass the live RAM and
# free disk so --dry-run and the real tuner report the same number.
angie_cache_budget_mb() {
  local ram_mb=$1 disk_free_mb=$2 pct=25 disk_pct=5 svc
  local has_php=0 has_maria=0 has_cache=0 has_es=0
  if (( ${#OPT_DETECTED[@]} > 0 )); then
    for svc in "${OPT_DETECTED[@]}"; do
      case $svc in
        php:*) has_php=1 ;;
        mariadb) has_maria=1 ;;
        valkey|redis) has_cache=1 ;;
        elastic) has_es=1 ;;
      esac
    done
    if (( !has_php && !has_maria && !has_cache && !has_es )); then
      pct=50
      disk_pct=10
    elif (( has_php && !has_maria && !has_cache && !has_es )); then
      pct=30
    fi
  fi
  tune_cache_total_mb "$ram_mb" "$disk_free_mb" "$pct" "$disk_pct"
}

# Pick the first existing file from a list.  Older server-configs-nginx
# releases installed http.d files with underscore names (fastcgi_cache_conf);
# current releases use dots (fastcgi_cache.conf).  --optimize must tune a live
# server regardless of which layout it was installed with.
tune_first_file() {
  local dir=$1 name
  shift
  for name in "$@"; do
    [[ -f "${dir}/${name}" ]] && { printf '%s' "${dir}/${name}"; return 0; }
  done
  return 1
}

# Files under http.d that Angie actually includes.  Hosts upgraded from older
# layouts often keep inert *_conf leftovers next to the active *.conf files;
# tuning those leftovers changes nothing and hides the real cache/limit files.
TUNE_ACTIVE_HTTP=()
angie_active_http_files() {
  local target=$1 conf="${1}/angie.conf" pattern path
  [[ -f $conf ]] || return 0
  while IFS= read -r pattern; do
    pattern=${pattern#*include}
    pattern=${pattern%%;*}
    pattern=$(printf '%s' "$pattern" | tr -d '"' | awk '{print $1}')
    [[ -n $pattern ]] || continue
    [[ $pattern == /* ]] || pattern="${target}/${pattern}"
    while IFS= read -r path; do
      [[ -n $path && -f $path ]] || continue
      case "$path" in
        "${target}/http.d/"*) printf '%s\n' "$path" ;;
      esac
    done < <(compgen -G "$pattern" 2>/dev/null | sort || true)
  done < <(grep -hE '^[[:space:]]*include[[:space:]]+' "$conf" 2>/dev/null || true)
}

# The repository ships both .conf and legacy *_conf http.d filenames.  New
# managed files must use the same suffix as the files angie.conf includes,
# otherwise they are inert (and a duplicate cache zone is never loaded).
angie_http_suffix() {
  local target=$1 file
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    case "$file" in
      *_conf) printf '_conf'; return 0 ;;
    esac
  done < <(angie_active_http_files "$target")
  printf '.conf'
}

tune_active_file() {
  local pattern=$1 file
  for file in "${TUNE_ACTIVE_HTTP[@]}"; do    [[ -f $file ]] || continue
    grep -qE "$pattern" "$file" && { printf '%s' "$file"; return 0; }
  done
  return 1
}

# Cache or limiter files under http.d that angie.conf never includes.  Older
# deployments kept the *_conf names after the repository renamed them to
# *.conf; those files look active but silently change nothing, which is why
# --optimize reports "no active fastcgi_cache_path" on such a host.
angie_inert_cache_files() {
  local target=$1 file active is_active
  local -a active_files=()
  mapfile -t active_files < <(angie_active_http_files "$target")
  for file in "$target"/http.d/*; do
    [[ -f $file ]] || continue
    grep -qE '^[[:space:]]*(fastcgi_cache_path|proxy_cache_path|limit_req_zone)[[:space:]]' "$file" || continue
    is_active=0
    for active in "${active_files[@]}"; do
      [[ $file == "$active" ]] && { is_active=1; break; }
    done
    (( is_active )) || printf '%s\n' "$file"
  done
  return 0
}

# Directories backing the cache paths Angie actually includes.  Used after a
# service restart to drop objects written while a backend was unavailable.
angie_cache_dirs() {
  local target=${1:-/etc/angie} file
  local -a files=()
  mapfile -t files < <(angie_active_http_files "$target")
  files+=("${target}/angie.conf")
  for file in "${files[@]}"; do
    [[ -f $file ]] || continue
    awk '
      {
        for (i = 1; i < NF; i++) {
          if ($i ~ /^(fastcgi|proxy|scgi|uwsgi)_cache_path$/) {
            print $(i + 1)
            break
          }
        }
      }
    ' "$file"
  done | tr -d ';' | grep -E '^/' | sort -u
  return 0
}

# Disk-cache max_size is planned from RAM, but a live cache can already hold
# more than that plan (and may be configured larger by the operator).  Writing
# a smaller value makes Angie's cache manager evict hot objects immediately,
# and chasing usage every run would ratchet the value upward forever.  Rule:
# never shrink below the existing max_size or the live usage (+5% headroom).
# Sets ANGIE_CACHE_MB (size to write) and ANGIE_CACHE_NOTE (report line, if
# the planned value was raised).  A global result is used instead of command
# substitution so the note reaches the caller's TUNE_CHANGES array.
# angie_cache_keep_mb FILE PLANNED_MB [ZONE]: with ZONE, only the
# *_cache_path directive whose keys_zone is ZONE is considered (a proxy file
# carries two paths); the directive may wrap onto several lines.
angie_cache_keep_mb() {
  local file=$1 planned=$2 zone=${3:-} dir usage existing=0 candidate val directive
  ANGIE_CACHE_MB=$planned
  ANGIE_CACHE_NOTE=""
  [[ -f $file ]] || return 0
  # Join each *_cache_path directive onto one line, then pick the first (or
  # the one naming ZONE).
  directive=$(awk -v zone="$zone" '
    collecting { buf = buf " " $0 }
    !collecting && $1 ~ /^(fastcgi|proxy|scgi|uwsgi)_cache_path$/ { buf = $0; collecting = 1 }
    collecting && buf ~ /;[[:space:]]*$/ {
      collecting = 0
      if (zone == "" || index(buf, "keys_zone=" zone ":") > 0) { print buf; exit }
      buf = ""
    }
  ' "$file")
  [[ -n $directive ]] || return 0
  dir=$(printf '%s\n' "$directive" | awk '{print $2}' | tr -d ';')
  # Existing max_size in MB (k/m/g suffix); 0 when the directive has none.
  val=$(printf '%s\n' "$directive" | grep -m1 -oE 'max_size=[0-9]+[kKmMgG]' 2>/dev/null || true)
  val=${val#max_size=}
  if [[ $val =~ ^([0-9]+)([kKmMgG])$ ]]; then
    case ${BASH_REMATCH[2]} in
      k|K) existing=$(( BASH_REMATCH[1] / 1024 )) ;;
      m|M) existing=${BASH_REMATCH[1]} ;;
      g|G) existing=$(( BASH_REMATCH[1] * 1024 )) ;;
    esac
  fi
  candidate=$planned
  usage=$(du -sm -- "$dir" 2>/dev/null | awk '{print $1}' || true)
  [[ $usage =~ ^[0-9]+$ ]] || usage=0
  if (( usage > planned )); then
    if (( existing > 0 && existing >= usage )); then
      # The configured cache already covers its live objects: keep it rather
      # than writing a value that would evict them.
      candidate=$existing
    else
      candidate=$(( usage * 105 / 100 ))
    fi
  fi
  (( candidate > planned )) || return 0
  candidate=$(( (candidate + 255) / 256 * 256 ))
  ANGIE_CACHE_MB=$candidate
  ANGIE_CACHE_NOTE="kept cache max_size=${candidate}M for ${dir:-cache} (live ${usage}MB; RAM plan was ${planned}M)"
  return 0
}

# A backend that restarts during --optimize can send a truncated/empty 200
# while connections are cut over, and the guest cache stores 200 responses
# for minutes: every visitor then receives a blank page.  Older releases
# deleted objects written during the run.  setup.sh now only reports them: a
# cache file is still a file, and deleting the wrong entry is not recoverable.
count_optimize_cache_entries() {
  local epoch=${1:-0} target=${2:-/etc/angie} dir count total=0
  [[ $epoch =~ ^[0-9]+$ ]] && (( epoch > 0 )) || { printf '0'; return 0; }
  while IFS= read -r dir; do
    [[ -n $dir && $dir == /* && $dir != / && -d $dir ]] || continue
    count=$(find "$dir" -type f -newermt "@$epoch" 2>/dev/null | wc -l)
    total=$(( total + count ))
  done < <(angie_cache_dirs "$target")
  printf '%s' "$total"
}

tune_replace() {
  local file=$1 pattern=$2 replacement=$3 desc=$4 tmp
  if [[ ! -f $file ]]; then
    tune_miss "file not found for ${desc}: ${file}"
    return 0
  fi
  if ! grep -qE "$pattern" "$file"; then
    tune_miss "no match for ${desc}"
    return 0
  fi
  tmp=$(tmp_file) || return 1
  # Use a delimiter that does not collide with regex alternation (`|`) or
  # common path characters in these directives.
  sed -E "s#${pattern}#${replacement}#" "$file" > "$tmp" || return 1
  commit_if_changed "$file" "$tmp" && tune_note "$desc"
  return 0
}

tune_insert_after() {
  local file=$1 anchor=$2 line=$3 desc=$4
  if [[ ! -f $file ]]; then
    tune_miss "file not found for ${desc}: ${file}"
    return 0
  fi
  if ! grep -qE "$anchor" "$file"; then
    tune_miss "no insertion anchor for ${desc}"
    return 0
  fi
  local tmp
  tmp=$(tmp_file)
  awk -v anchor="$anchor" -v line="$line" '
    $0 ~ anchor && !done { print; print line; done=1; next }
    { print }
  ' "$file" > "$tmp"
  if commit_if_changed "$file" "$tmp"; then
    tune_note "$desc"
  fi
}

# Append a directive only when the file has no active copy.  Used by the
# guest-cache repair so an older include that is missing one line (for
# example fastcgi_no_cache) is completed without duplicating the rest.
tune_ensure_line() {
  local file=$1 pattern=$2 line=$3 desc=$4
  [[ -f $file ]] || { tune_miss "file not found for ${desc}: ${file}"; return 0; }
  grep -qE "$pattern" "$file" && return 0
  printf '%s\n' "$line" >> "$file"
  tune_note "$desc"
  return 0
}

# Like tune_ensure_line, but the directive is inserted before the last
# closing brace so it lands inside the include's location block (the h5bp
# php_*.conf includes are one `location ~ \.php` each).  Appending after the
# brace put cache directives in the server context, where they also applied
# to the admin/login locations that deliberately include plain php.conf.
tune_ensure_in_location() {
  local file=$1 pattern=$2 line=$3 desc=$4 tmp last
  [[ -f $file ]] || { tune_miss "file not found for ${desc}: ${file}"; return 0; }
  grep -qE "$pattern" "$file" && return 0
  last=$(grep -nE '^[[:space:]]*\}[[:space:]]*$' "$file" | tail -n1 | cut -d: -f1 || true)
  if [[ -z $last ]]; then
    tune_ensure_line "$file" "$pattern" "$line" "$desc"
    return 0
  fi
  tmp=$(tmp_file) || return 1
  awk -v n="$last" -v line="$line" 'NR == n { print line } { print }' "$file" > "$tmp"
  cat -- "$tmp" > "$file"
  tune_note "$desc"
  return 0
}

# A cached 500 (or a stale 500 served by fastcgi_cache_use_stale) hides a
# recovered application and makes the error look permanent.  Older installs
# carry the original policy; --optimize upgrades them in place so an existing
# server gets the fix without a full reinstall.
tune_cache_error_policy() {
  local file=$1 label=$2 before after tmp
  [[ -f $file ]] || return 0
  before=$(file_md5 "$file")
  sed_in_place -E '/^[[:space:]]*fastcgi_cache_use_stale/ s/[[:space:]]+http_500([[:space:]]|;)/\1/g' "$file"
  if ! grep -qE '^[[:space:]]*fastcgi_cache_valid[[:space:]]+500([[:space:]]+[0-9]+)+[[:space:]]+0s;' "$file"; then
    tmp=$(tmp_file)
    if grep -qE '^[[:space:]]*fastcgi_cache_valid[[:space:]]+any[[:space:]]' "$file"; then
      awk '
        /^[[:space:]]*fastcgi_cache_valid[[:space:]]+any[[:space:]]/ && !done {
          print
          print "fastcgi_cache_valid 500 502 503 504 0s;"
          done = 1
          next
        }
        { print }
      ' "$file" > "$tmp"
    else
      cat "$file" > "$tmp"
      printf '\nfastcgi_cache_valid 500 502 503 504 0s;\n' >> "$tmp"
    fi
    cat "$tmp" > "$file"
  fi
  after=$(file_md5 "$file")
  [[ $before != "$after" ]] \
    && tune_note "${label}: never cache error responses; stale 500 disabled"
  return 0
}

# The shared FastCGI snippet historically captured PATH_INFO with
# ^(.+?\.php)(/.*)$; that requires a trailing "/..." and can leave
# $fastcgi_script_name empty for a bare /index.php.  try_files then sees the
# document root, passes it to PHP-FPM, and security.limit_extensions returns
# "Access denied" for every pretty URL.  Make PATH_INFO optional; the
# try_files test and SCRIPT_FILENAME stay unchanged so PATH_INFO apps keep
# working.
tune_fastcgi_snippet() {
  local file=$1 tmp
  [[ -f $file ]] || { tune_miss "FastCGI snippet missing: ${file}"; return 0; }
  grep -qE '^[[:space:]]*fastcgi_split_path_info[[:space:]]+' "$file" || {
    tune_miss "FastCGI snippet has no fastcgi_split_path_info: ${file}"
    return 0
  }
  tmp=$(tmp_file) || return 1
  awk '
    function lead(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    /^[[:space:]]*fastcgi_split_path_info[[:space:]]+/ {
      print lead($0) "fastcgi_split_path_info ^(.+?\\.php)(/.*)?$;"
      next
    }
    { print }
  ' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "snippets/fastcgi-php.conf: PATH_INFO capture is optional"
  return 0
}

# PHP-FPM uses PATH_TRANSLATED instead of SCRIPT_FILENAME when
# cgi.fix_pathinfo=0. The shared WordPress/Polr includes used to set it to
# $document_root$fastcgi_path_info, which is the document root for a normal
# /index.php request. Point it at the script so enabling fix_pathinfo later
# cannot turn the document root into an attempted PHP script.
tune_fastcgi_path_translated() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  grep -qE '^[[:space:]]*fastcgi_param[[:space:]]+PATH_TRANSLATED[[:space:]]+\$document_root\$fastcgi_path_info[[:space:]]*;' "$file" || return 0
  tmp=$(tmp_file) || return 1
  awk '
    function lead(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    /^[[:space:]]*fastcgi_param[[:space:]]+PATH_TRANSLATED[[:space:]]+\$document_root\$fastcgi_path_info[[:space:]]*;/ {
      print lead($0) "fastcgi_param PATH_TRANSLATED $document_root$fastcgi_script_name;"
      next
    }
    { print }
  ' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "${file##*/}: PATH_TRANSLATED uses the PHP script"
  return 0
}

# Apply the PATH_TRANSLATED repair to every deployed PHP location include:
# php.conf plus all php_*.conf (php_xf.conf, php_xf_proxy.conf, php_wp.conf,
# php_polr.conf, and any future variant).
tune_fastcgi_path_translated_all() {
  local target=$1 file
  tune_fastcgi_path_translated "${target}/h5bp/php.conf"
  for file in "${target}"/h5bp/php_*.conf; do
    [[ -f $file ]] || continue
    tune_fastcgi_path_translated "$file"
  done
  return 0
}

# A per-request `PHP_ADMIN_VALUE open_basedir=...` is cached by the FPM worker
# that handled the request and is never reset, so one vhost that sets it
# silently restricts every other vhost served by the shared pool.  The next
# WordPress request on that worker then sees file_exists(wp-config.php) == false
# and redirects to /wp-admin/setup-config.php (denied -> 403), and PHP cannot
# open the primary script at all ("Unable to open primary script ...
# Operation not permitted" -> 404).  Tenant isolation belongs in a dedicated
# pool, never in a fastcgi_param, so comment out every deployed copy.
tune_strip_php_admin_open_basedir() {
  local file=$1 label=${2:-${1##*/}} before
  [[ -f $file ]] || return 0
  before=$(file_md5 "$file")
  sed_in_place -E 's|^([[:space:]]*)(fastcgi_param[[:space:]]+PHP_ADMIN_VALUE[[:space:]]+"?open_basedir=.*)$|\1# \2|' "$file"
  if [[ $(file_md5 "$file") != "$before" ]]; then
    tune_note "${label}: per-request open_basedir disabled (it leaks across the shared PHP-FPM pool)"
  fi
  return 0
}

# Apply the repair to every deployed PHP location include and to any vhost
# that inlined the param itself.
tune_strip_php_admin_open_basedir_all() {
  local target=$1 file
  for file in "${target}"/h5bp/php*.conf "${target}"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    tune_strip_php_admin_open_basedir "$file"
  done
  return 0
}

# A bare `location / { try_files ... }` with no index directive resolves "/"
# to the directory instead of index.php on older vhosts.  Add a server-level
# index to the shared WordPress and Polr includes when they lack one.
tune_ensure_index() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  if grep -qE '^[[:space:]]*index[[:space:]]' "$file"; then
    return 0
  fi
  tmp=$(tmp_file) || return 1
  {
    printf 'index index.php index.html;\n'
    cat "$file"
  } > "$tmp"
  cat "$tmp" > "$file"
  tune_note "${file##*/}: index index.php index.html"
  return 0
}

# ---------------------------------------------------------------------------
# Angie
# ---------------------------------------------------------------------------
# XenForo's own page cache varies on style_id and language_id (see
# src/XF/PageCache.php).  The deployed Angie vhost only keyed on the style
# variation, so a guest who picked a non-default style or language could
# receive another guest's cached HTML.  Add both cookies to the key and enable
# a background refresh so an expiring entry does not make one visitor wait on
# PHP while cache_lock serializes the stampede.
tune_xf_cache_vary() {
  local file=$1
  [[ -f $file ]] || return 0
  local before tmp
  before=$(file_md5 "$file")
  if grep -qE '^[[:space:]]*fastcgi_cache_key[[:space:]]' "$file"; then
    tmp=$(tmp_file)
    awk '
      /^[[:space:]]*fastcgi_cache_key[[:space:]]/ {
        if (index($0, "$cookie_xf_language_id") == 0) {
          sub(/";[[:space:]]*$/, "$cookie_xf_style_id$cookie_xf_language_id\";")
        }
        if (index($0, "$setup_cache_enc") == 0) {
          sub(/";[[:space:]]*$/, "$setup_cache_enc\";")
        }
      }
      { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
  fi
  if grep -qE '^[[:space:]]*fastcgi_cache_lock[[:space:]]+on;' "$file" \
     && ! grep -qE '^[[:space:]]*fastcgi_cache_background_update' "$file"; then
    tune_insert_after "$file" '^[[:space:]]*fastcgi_cache_lock[[:space:]]+on;' \
      'fastcgi_cache_background_update on;' \
      "$(basename "$file"): background cache update"
  fi
  if [[ $(file_md5 "$file") != "$before" ]]; then
    tune_note "$(basename "$file"): cache key varies on style/language/encoding"
  fi
  return 0
}

# XenForo serves its own JS/CSS/images from /js, /styles and /data.  The
# generated vhost only limits the methods, so browsers revalidate every asset.
# Add one immutable, 30-day regex location (regex beats the existing prefix
# blocks).  Idempotent and re-applied after the repository sync on every run.
tune_xf_static_assets() {
  local file=${1:-/etc/angie/h5bp/xf2.conf}
  [[ -f $file ]] || { tune_miss "XenForo include missing: ${file}"; return 0; }
  grep -q 'setup.sh: static asset cache' "$file" && return 0
  local tmp
  tmp=$(tmp_file) || return 1
  awk '
    /^[[:space:]]*### End Xenforo/ && !done {
      print "    # setup.sh: static asset cache (XenForo /js, /styles, /data)"
      print "    location ~* ^/(?:js|styles|data)/(?:.*\\.(?:js|css|png|jpe?g|gif|svg|webp|avif|woff2?|ttf|eot|ico))$ {"
      print "        expires 30d;"
      print "        add_header Cache-Control \"public, immutable\";"
      print "        access_log off;"
      print "        try_files $uri =404;"
      print "    }"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "$(basename "$file"): static assets cached 30d (immutable)"
  return 0
}

# Per-IP rate limiting exempts loopback only.  A load generator, uptime
# monitor or reverse proxy on another host is throttled to 100 GET/s and
# answered with 429, which silently invalidates a remote benchmark (every
# earlier external run that used wrk, which does not report status codes,
# measured the rate limiter).  SETUP_LIMIT_REQ_EXEMPT="10.0.0.5,192.0.2.0/24"
# adds managed entries to the geo whitelist; an empty value removes them.
tune_limit_req_exemptions() {
  local file=$1 label=$2 tmp entry
  local -a entries=()
  grep -qE '^[[:space:]]*geo[[:space:]]+\$limit_req_whitelist[[:space:]]*[{]' "$file" || return 0
  local raw=${LIMIT_REQ_EXEMPT:-}
  raw=${raw//,/ }
  for entry in $raw; do
    [[ $entry =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ || $entry =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ ]] || {
      tune_miss "${label}: ignoring invalid SETUP_LIMIT_REQ_EXEMPT entry '${entry}'"
      continue
    }
    entries+=("$entry")
  done
  tmp=$(tmp_file) || return 1
  awk -v n="${#entries[@]}" -v list="${entries[*]}" '
    BEGIN { split(list, arr, " ") }
    /# setup.sh exempt$/ { next }
    { print }
    /^[[:space:]]*geo[[:space:]]+\$limit_req_whitelist[[:space:]]*[{]/ && !done {
      for (i = 1; i <= n; i++) printf "    %s 1; # setup.sh exempt\n", arr[i]
      done = 1
    }
  ' "$file" > "$tmp" || return 1
  if commit_if_changed "$file" "$tmp"; then
    if (( ${#entries[@]} > 0 )); then
      tune_note "${label}: rate-limit exemptions: ${entries[*]}"
    else
      tune_note "${label}: removed managed rate-limit exemptions"
    fi
  fi
  return 0
}

# Record one KEY="VALUE" line in /etc/default/setup-tuning (the host file
# every run sources at startup), replacing an existing line for the key.
# Shared by every environment-supplied option that must survive a plain
# --optimize: rate-limit exemptions, asset precompression, the OPcache JIT
# mode and the Node.js major.
persist_tuning_var() {
  local key=$1 value=$2 f=/etc/default/setup-tuning line
  [[ ${EUID} -eq 0 ]] || return 0
  line="${key}=\"${value}\""
  if [[ -f $f ]] && grep -qE "^${key}=" "$f"; then
    sed_in_place -E "s|^${key}=.*|$(sed_replacement_escape "$line")|" "$f"
  else
    printf '%s\n' "$line" >> "$f"
  fi
  chmod 644 "$f" 2>/dev/null || true
}

# Keep an environment-supplied exemption list in /etc/default/setup-tuning so
# the next plain --optimize does not silently remove it again.
persist_limit_req_exemptions() {
  (( LIMIT_REQ_EXEMPT_PERSIST )) || return 0
  [[ ${EUID} -eq 0 ]] || return 0
  persist_tuning_var LIMIT_REQ_EXEMPT "$LIMIT_REQ_EXEMPT"
  tune_note "limit_req: exemptions persisted in /etc/default/setup-tuning"
}

# Keep SETUP_PRECOMPRESS_ASSETS in /etc/default/setup-tuning like the
# exemption list, so a plain --optimize keeps the operator's choice.
persist_precompress_assets() {
  (( PRECOMPRESS_ASSETS_PERSIST )) || return 0
  [[ ${EUID} -eq 0 ]] || return 0
  persist_tuning_var PRECOMPRESS_ASSETS "$PRECOMPRESS_ASSETS"
  tune_note "precompress: PRECOMPRESS_ASSETS=${PRECOMPRESS_ASSETS} persisted in /etc/default/setup-tuning"
}

# Keep SETUP_XF_JOB_CRON in /etc/default/setup-tuning the same way.  Called
# from write_cron, which runs more than once per install, so the flag is
# cleared after the first write to keep the report to one line.
persist_xf_job_cron() {
  (( XF_JOB_CRON_PERSIST )) || return 0
  [[ ${EUID} -eq 0 ]] || return 0
  persist_tuning_var XF_JOB_CRON "$XF_JOB_CRON"
  XF_JOB_CRON_PERSIST=0
  tune_note "cron: XF_JOB_CRON=${XF_JOB_CRON} persisted in /etc/default/setup-tuning"
}

# Document root of an Angie vhost file ("" when none).  Shared by the
# WordPress/XenForo vhost scanners, the worker cap and asset precompression.
angie_vhost_root() {
  local root
  root=$(grep -m1 -E '^[[:space:]]*root[[:space:]]+' "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*root[[:space:]]+//; s/;.*//; s/^[[:space:]]+//; s/[[:space:]]+$//')
  root=${root%\"}; root=${root#\"}
  printf '%s' "${root%/}"
}

# True when an application's database host is this machine (loopback, a
# socket path, or the default empty value), i.e. its PHP workers spend the
# request on the CPU instead of waiting on a network round trip.
app_db_host_is_local() {
  local host=${1:-}
  host=${host#p:}
  case "$host" in
    ""|localhost|127.0.0.1|::1|/*|unix:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Precompress the static assets under one document root so brotli_static and
# gzip_static serve .br/.gz siblings instead of compressing on every request
# (serving one 177 KB XenForo script compressed per request cost 50-89% of a
# 16-core host at 1.8k req/s).  Incremental: a sibling is (re)built only when
# missing or older than its source, orphaned siblings are removed, a sibling
# that is not smaller is dropped, and mtime/ownership follow the source so a
# rerun is a no-op.  Images, woff2 and the application data directories are
# skipped.  Prints the number of siblings written.
precompress_static_assets() {
  local root=$1 f out tmp ext n=0 have_brotli=0
  [[ -d $root ]] || { printf 0; return 0; }
  command -v brotli >/dev/null 2>&1 && have_brotli=1
  while IFS= read -r -d '' f; do
    for ext in gz br; do
      [[ $ext == br && $have_brotli -eq 0 ]] && continue
      out="${f}.${ext}"
      [[ ! -e $out || $f -nt $out ]] || continue
      tmp="${out}.tmp.$$"
      if { [[ $ext == gz ]] && gzip -9 -n -c < "$f" > "$tmp"; } \
         || { [[ $ext == br ]] && brotli -q 11 -c < "$f" > "$tmp"; }; then
        if (( $(stat -c %s "$tmp") < $(stat -c %s "$f") )); then
          touch -r "$f" "$tmp"
          chown --reference="$f" "$tmp" 2>/dev/null || true
          chmod 644 "$tmp"
          mv -f "$tmp" "$out"
          n=$(( n + 1 ))
        else
          rm -f "$tmp" "$out"
        fi
      else
        rm -f "$tmp"
      fi
    done
  done < <(find "$root" -type f -regextype posix-extended \
             -regex '.*\.(js|mjs|css|svg|json|xml|txt|map|ico|webmanifest|ttf|otf|eot|woff)$' -size +1k \
             ! -path '*/internal_data/*' ! -path '*/data/*' ! -path '*/src/*' ! -path '*/install/*' \
             ! -path '*/wp-content/uploads/*' ! -path '*/wp-content/cache/*' ! -path '*/.git/*' \
             -print0 2>/dev/null)
  # Siblings whose source is gone (an upgrade removed or renamed the file).
  while IFS= read -r -d '' f; do
    [[ -e ${f%.*} ]] || rm -f "$f"
  done < <(find "$root" -type f -regextype posix-extended \
             -regex '.*\.(js|mjs|css|svg|json|xml|txt|map|ico|webmanifest|ttf|otf|eot|woff)\.(gz|br)$' \
             ! -path '*/internal_data/*' ! -path '*/data/*' ! -path '*/wp-content/uploads/*' \
             -print0 2>/dev/null)
  printf '%s' "$n"
}

# Install the cron helper that keeps the siblings fresh.  It carries a copy of
# precompress_static_assets (declare -f), so the cron job has no dependency on
# this script's location, and is regenerated by every install/--optimize.
write_precompress_helper() {
  local helper=$CRON_PRECOMPRESS tmp
  tmp=$(tmp_file) || return 1
  {
    printf '#!/bin/bash\n'
    printf '# Managed by setup.sh %s: keep .br/.gz siblings of static assets fresh for\n' "$SCRIPT_VERSION"
    printf '# brotli_static/gzip_static.  Regenerated by every --optimize; do not edit.\n'
    printf 'set -u\nexport LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf 'ROOTS=(%s)\n' "$(printf '%q ' "$@")"
    declare -f precompress_static_assets
    printf 'total=0\nfor root in "${ROOTS[@]}"; do\n  n=$(precompress_static_assets "$root")\n  total=$(( total + ${n:-0} ))\ndone\nprintf "precompressed %%s files\\n" "$total"\n'
  } > "$tmp"
  if commit_if_changed "$helper" "$tmp"; then
    tune_note "precompress: helper ${helper} written for ${*}"
  fi
  chmod 755 "$helper"
}

# Asset precompression for every detected XenForo/WordPress vhost: writes the
# cron helper and runs it once (install and --optimize), or retires the
# helper when the feature is off.  write_cron adds the 5-minute entry so an
# application upgrade is re-compressed (and stale siblings dropped) quickly.
configure_asset_precompression() {
  local target=${1:-/etc/angie} helper=$CRON_PRECOMPRESS file root moved out
  local -a roots=() nicer=(nice -n 19)
  persist_precompress_assets
  if (( ! PRECOMPRESS_ASSETS )); then
    if [[ -f $helper ]] && grep -q 'Managed by setup.sh' "$helper" 2>/dev/null; then
      moved=$(preserve_to_tmp "$helper" 2>/dev/null || true)
      [[ -n $moved ]] && tune_note "precompress: helper moved to ${moved} (PRECOMPRESS_ASSETS=0)"
      write_cron >/dev/null 2>&1 || true
    fi
    return 0
  fi
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    root=$(angie_vhost_root "$file")
    [[ -n $root && -d $root ]] && roots+=("$root")
  done < <({ angie_xenforo_vhosts "$target"; angie_wordpress_vhosts "$target"; } 2>/dev/null | sort -u)
  if (( ${#roots[@]} == 0 )); then
    tune_miss "precompress: no XenForo/WordPress vhost with files found; nothing to precompress yet"
    return 0
  fi
  # The brotli CLI (a 15 KB package) builds the .br siblings; without it the
  # pass produces gzip siblings only.  Installed here, before the first pass,
  # not in the compression step that runs later in the same Angie pass.
  if ! command -v brotli >/dev/null 2>&1; then
    apt_install brotli || warn "Could not install the brotli CLI; precompressed assets will be gzip only"
  fi
  write_precompress_helper "${roots[@]}" || return 1
  # The managed crontab was written before the helper existed on a first run.
  write_cron >/dev/null 2>&1 || warn "Could not refresh the managed crontab for the precompress helper"
  command -v ionice >/dev/null 2>&1 && nicer+=(ionice -c 3)
  out=$("${nicer[@]}" "$helper" 2>/dev/null || true)
  tune_note "precompress: ${out:-ran} under ${roots[*]} (brotli_static/gzip_static; refreshed every 5 min by cron)"
  return 0
}

# Remove the FastCGI upstream keepalive cache from angie.conf.  Every idle
# connection in that cache occupies one PHP-FPM worker (FPM waits on the open
# socket for the next request), and the cache is per Angie worker, so the
# total can reach keepalive x worker_processes and pin the whole FPM pool.
# A request that then lands on an Angie worker without a cached connection
# waits for keepalive_timeout (60 s upstream default) before a worker frees.
# Measured on the live XenForo origin: 4-7 of 64 non-cacheable /login
# requests stalled 60-112 s with keepalive 16; with the cache removed, 3 x
# 128 requests stayed at p99 33-38 ms / max 93 ms and p50 was unchanged.
angie_disable_php_keepalive() {
  local file=${1:-} tmp
  [[ -n $file && -f $file ]] || return 0
  tmp=$(tmp_file) || return 1
  awk '
    /^[[:space:]]*upstream[[:space:]]+local_php[[:space:]]*\{/ { in_php = 1 }
    in_php && /^[[:space:]]*keepalive([[:space:]]|_timeout[[:space:]])/ { next }
    in_php && /^[[:space:]]*#[[:space:]]*Reuse enough idle FastCGI/ { next }
    in_php && /^[[:space:]]*\}/ { in_php = 0 }
    { print }
  ' "$file" > "$tmp" || return 1
  commit_if_changed "$file" "$tmp" \
    && tune_note "angie.conf: removed the PHP upstream keepalive cache (idle connections pin FPM workers)"
  return 0
}

# `fastcgi_keep_conn on` only has an effect when an upstream keepalive cache
# exists (Angie's documentation requires the keepalive directive).  Set it to
# off in every PHP include so a future keepalive value cannot silently pin
# the pool again, and so an old config tree gets the same behaviour as the
# current repository default.
angie_disable_php_keep_conn() {
  local target=${1:-/etc/angie} file
  for file in "$target"/h5bp/php*.conf; do
    [[ -f $file ]] || continue
    tune_replace "$file" '^([[:space:]]*fastcgi_keep_conn[[:space:]]+)on;' '\1off;' \
      "${file#"$target"/}: fastcgi_keep_conn=off"
  done
  return 0
}

tune_angie_configs() {
  local target=${1:-/etc/angie}
  local nginx_conf="${target}/angie.conf"
  [[ -f $nginx_conf ]] || return 1

  # Repair the shared PHP include and the two server-level includes that old
  # deployments left without an index.  Also normalise PATH_TRANSLATED in
  # every PHP location include so cgi.fix_pathinfo=0 cannot make PHP-FPM
  # execute the document root.
  tune_fastcgi_snippet "${target}/snippets/fastcgi-php.conf"
  tune_ensure_index "${target}/h5bp/wordpress.conf"
  tune_ensure_index "${target}/h5bp/php_polr.conf"
  tune_fastcgi_path_translated_all "$target"
  tune_strip_php_admin_open_basedir_all "$target"

  local nproc mem_mb disk_free_mb disk_class
  local worker_rlimit worker_connections open_files
  local fastcgi_buffers fastcgi_busy body_buffer ssl_cache_mb
  local cache_total_mb fcgi_mb chev_mb xf_mb proxy_mb cdn_mb
  local fcgi_zone chev_zone xf_zone proxy_zone cdn_zone
  local fcgi_size chev_size xf_size proxy_size cdn_size
  local limit_post limit_get

  nproc=$(effective_cpus)
  (( nproc > 0 )) || nproc=1
  mem_mb=$(mem_total_mb)
  (( mem_mb > 0 )) || mem_mb=1024

  disk_class=$(storage_class)
  disk_free_mb=$(angie_disk_free_mb)

  angie_worker_limits "$nproc"
  worker_rlimit=$ANGIE_WORKER_RLIMIT
  worker_connections=$ANGIE_WORKER_CONNECTIONS
  # The open-file cache holds static assets, templates and cache objects;
  # size it with RAM (and the file count that implies), not the core count.
  # Cached descriptors are real fds of the worker, so the cache can never
  # exceed what worker_rlimit_nofile leaves after the connections themselves
  # (a 4-core/32 GB host used to get 200000 entries against a 65536 limit).
  open_files=$(angie_open_file_cache_max "$mem_mb" "$worker_rlimit" "$worker_connections")

  if (( mem_mb < 2048 )); then
    fastcgi_buffers='32 16k'; fastcgi_busy='256k'; body_buffer='64k'
  elif (( mem_mb < 8192 )); then
    fastcgi_buffers='64 32k'; fastcgi_busy='1m'; body_buffer='128k'
  else
    fastcgi_buffers='128 32k'; fastcgi_busy='2m'; body_buffer='256k'
  fi

  ssl_cache_mb=$(tune_clamp $(( mem_mb / 512 )) 10 256)

  # Scale the disk-cache budget with the services actually present.  A
  # dedicated Angie proxy has no PHP/DB/search tier to share RAM with, and an
  # Angie+PHP host has no database/search tier.  The helper is shared with
  # --dry-run so the plan and the applied value match.
  cache_total_mb=$(angie_cache_budget_mb "$mem_mb" "$disk_free_mb")

  # Resolve the cache files Angie actually includes before sizing them, so a
  # host that only runs one cache type can use the whole cache budget instead
  # of leaving most of it assigned to caches that do not exist.
  local f_fcgi f_chev f_xf f_proxy f_limit
  TUNE_ACTIVE_HTTP=()
  mapfile -t TUNE_ACTIVE_HTTP < <(angie_active_http_files "$target")
  if (( ${#TUNE_ACTIVE_HTTP[@]} > 0 )); then
    f_fcgi=$(tune_active_file 'keys_zone=fastcgicache:') || f_fcgi=""
    f_chev=$(tune_active_file 'keys_zone=fastcgicache_chev:') || f_chev=""
    f_xf=$(tune_active_file 'keys_zone=xfproxycache:') || f_xf=""
    f_proxy=$(tune_active_file 'keys_zone=(proxy_cache|proxy_cdn|cdn_proxy):') || f_proxy=""
    f_limit=$(tune_active_file 'limit_req_zone') || f_limit=""
  else
    f_fcgi=$(tune_first_file "$target/http.d" fastcgi_cache.conf fastcgi_cache_conf) || f_fcgi=""
    f_chev=$(tune_first_file "$target/http.d" fastcgi_cache_chev.conf fastcgi_cache_chev_conf) || f_chev=""
    f_xf=$(tune_first_file "$target/http.d" xf_proxy_cache.conf xf_proxy_cache_conf) || f_xf=""
    f_proxy=$(tune_first_file "$target/http.d" proxy_cache.conf proxy_cache_conf) || f_proxy=""
    f_limit=$(tune_first_file "$target/http.d" limit_req.conf limit_req_conf) || f_limit=""
  fi

  local have_fcgi=0 have_chev=0 have_xf=0 have_proxy=0 have_cdn=0 active_weight=0
  [[ -n $f_fcgi ]] && have_fcgi=1
  [[ -n $f_chev ]] && have_chev=1
  [[ -n $f_xf ]] && have_xf=1
  if [[ -n $f_proxy ]]; then
    grep -qE 'keys_zone=proxy_cache:' "$f_proxy" && have_proxy=1
    grep -qE 'keys_zone=(proxy_cdn|cdn_proxy):' "$f_proxy" && have_cdn=1
  fi
  (( have_fcgi )) && active_weight=$(( active_weight + 50 ))
  (( have_chev )) && active_weight=$(( active_weight + 25 ))
  (( have_xf )) && active_weight=$(( active_weight + 15 ))
  (( have_proxy )) && active_weight=$(( active_weight + 5 ))
  (( have_cdn )) && active_weight=$(( active_weight + 5 ))

  fcgi_mb=0; chev_mb=0; xf_mb=0; proxy_mb=0; cdn_mb=0
  if (( active_weight > 0 )); then
    (( have_fcgi )) && fcgi_mb=$(( cache_total_mb * 50 / active_weight ))
    (( have_chev )) && chev_mb=$(( cache_total_mb * 25 / active_weight ))
    (( have_xf )) && xf_mb=$(( cache_total_mb * 15 / active_weight ))
    (( have_proxy )) && proxy_mb=$(( cache_total_mb * 5 / active_weight ))
    (( have_cdn )) && cdn_mb=$(( cache_total_mb * 5 / active_weight ))
    # A proxy file containing only one of the standard paths must not rewrite
    # the other path to max_size=0.
    (( have_proxy && !have_cdn )) && cdn_mb=$proxy_mb
    (( have_cdn && !have_proxy )) && proxy_mb=$cdn_mb
  fi
  (( have_fcgi && fcgi_mb < 64 )) && fcgi_mb=64
  (( have_chev && chev_mb < 32 )) && chev_mb=32
  (( have_xf && xf_mb < 32 )) && xf_mb=32
  (( have_proxy && proxy_mb < 16 )) && proxy_mb=16
  (( have_cdn && cdn_mb < 16 )) && cdn_mb=16

  # Do not force the cache manager to evict a cache that is already larger
  # than the RAM-derived plan (live usage wins on an existing server).
  if [[ -n $f_fcgi ]]; then
    angie_cache_keep_mb "$f_fcgi" "$fcgi_mb"
    fcgi_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_fcgi#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi
  if [[ -n $f_chev ]]; then
    angie_cache_keep_mb "$f_chev" "$chev_mb"
    chev_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_chev#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi
  if [[ -n $f_xf ]]; then
    angie_cache_keep_mb "$f_xf" "$xf_mb"
    xf_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_xf#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi
  # The proxy/CDN caches ship at 16g and may hold a populated cache on an
  # adopted host; the same live-usage rule applies to them.
  if (( have_proxy )); then
    angie_cache_keep_mb "$f_proxy" "$proxy_mb" proxy_cache
    proxy_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_proxy#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi
  if (( have_cdn )); then
    angie_cache_keep_mb "$f_proxy" "$cdn_mb" proxy_cdn
    cdn_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_proxy#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi

  fcgi_zone=$(tune_clamp $(( cache_total_mb / 4 )) 16 512)
  chev_zone=$(tune_clamp $(( cache_total_mb / 8 )) 8 512)
  xf_zone=$(tune_clamp $(( cache_total_mb / 8 )) 8 256)
  proxy_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)
  cdn_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)

  fcgi_size=$(tune_size_value "$fcgi_mb")
  chev_size=$(tune_size_value "$chev_mb")
  xf_size=$(tune_size_value "$xf_mb")
  proxy_size=$(tune_size_value "$proxy_mb")
  cdn_size=$(tune_size_value "$cdn_mb")

  tune_replace "$nginx_conf" '^([[:space:]]*worker_processes[[:space:]]+)[^;]+;' "\\1${ANGIE_WORKER_PROCESSES};" "angie.conf: worker_processes=${ANGIE_WORKER_PROCESSES}"
  # With a cgroup CPU quota below the host's core count, `auto` affinity
  # would pin the N workers to CPUs 0..N-1 while every other service floats;
  # let the scheduler place them instead.
  local host_cpus
  host_cpus=$(nproc 2>/dev/null || echo "$nproc")
  if [[ $host_cpus =~ ^[0-9]+$ ]] && (( nproc < host_cpus )); then
    tune_replace "$nginx_conf" '^([[:space:]]*)worker_cpu_affinity[[:space:]]+auto;' \
      '\1# worker_cpu_affinity auto; # setup.sh: cgroup CPU quota, no pinning' \
      "angie.conf: worker_cpu_affinity disabled (quota ${nproc} of ${host_cpus} CPUs)"
  fi
  # Storage-class dependent file I/O: on flash the page cache serves hot
  # files cheaply, so only very large files bypass it (directio 16m); a
  # rotational disk keeps the 4m threshold so big downloads do not evict the
  # cache.  aio threads + sendfile stay on for every class.
  local directio_mb=4
  case $disk_class in nvme|ssd) directio_mb=16 ;; esac
  tune_replace "$nginx_conf" '^([[:space:]]*directio[[:space:]]+)[0-9]+[mMkK];' "\\1${directio_mb}m;" "angie.conf: directio=${directio_mb}m (${disk_class})"
  local gzip_level
  gzip_level=$(angie_gzip_level)
  tune_replace "$target/h5bp/web_performance/compression.conf" '^([[:space:]]*gzip_comp_level[[:space:]]+)[0-9]+;' "\\1${gzip_level};" "h5bp/web_performance/compression.conf: gzip_comp_level=${gzip_level}"
  tune_replace "$nginx_conf" '^([[:space:]]*worker_rlimit_nofile[[:space:]]+)[0-9]+;' "\\1${worker_rlimit};" "angie.conf: worker_rlimit_nofile=${worker_rlimit}"
  tune_replace "$nginx_conf" '^([[:space:]]*worker_connections[[:space:]]+)[0-9]+;' "\\1${worker_connections};" "angie.conf: worker_connections=${worker_connections}"
  tune_replace "$nginx_conf" '^([[:space:]]*client_body_buffer_size[[:space:]]+).*;' "\\1${body_buffer};" "angie.conf: client_body_buffer_size=${body_buffer}"
  angie_disable_php_keepalive "$nginx_conf"
  angie_disable_php_keep_conn "$target"

  if ! grep -qE '^[[:space:]]*worker_rlimit_nofile[[:space:]]' "$nginx_conf"; then
    tune_insert_after "$nginx_conf" '^[[:space:]]*worker_processes[[:space:]]' \
      "worker_rlimit_nofile ${worker_rlimit};" "angie.conf: inserted worker_rlimit_nofile=${worker_rlimit}"
  fi
  if ! grep -qE '^[[:space:]]*worker_connections[[:space:]]' "$nginx_conf"; then
    tune_insert_after "$nginx_conf" '^[[:space:]]*events[[:space:]]*[{]' \
      "  worker_connections ${worker_connections};" "angie.conf: inserted worker_connections=${worker_connections}"
  fi
  if ! grep -qE '^[[:space:]]*client_body_buffer_size[[:space:]]' "$nginx_conf"; then
    # Anchor on the real block opener: a bare `http[[:space:]]*` also matches
    # directives such as `http2 on;` and would insert inside a server block.
    tune_insert_after "$nginx_conf" '^[[:space:]]*http[[:space:]]*[{]' \
      "  client_body_buffer_size ${body_buffer};" "angie.conf: inserted client_body_buffer_size=${body_buffer}"
  fi

  # Point any remaining TCP FastCGI handlers at the pool's Unix socket, but
  # only when optimize_php_services found an existing socket listener.  A pool
  # kept on TCP (the usual live-server case) must keep Angie on TCP as well.
  if [[ -n ${OPT_PHP_SOCKET:-} ]]; then
    local file php_socket=${OPT_PHP_SOCKET}
    while IFS= read -r file; do
      [[ -n $file ]] || continue
      local before after
      before=$(file_md5 "$file")
      sed_in_place -E "s#^([[:space:]]*fastcgi_pass[[:space:]]+)(127\.0\.0\.1|localhost):9000;#\\1unix:${php_socket};#g" "$file"
      after=$(file_md5 "$file")
      [[ $before != "$after" ]] && tune_note "${file#"${target}"/}: fastcgi_pass -> unix:${php_socket}"
    done < <(grep -rlE '^[[:space:]]*fastcgi_pass[[:space:]]+(127\.0\.0\.1|localhost):9000;' "$target" 2>/dev/null || true)

    if grep -qE '^([[:space:]]*server[[:space:]]+)(127\.0\.0\.1|localhost):9000;' "$nginx_conf"; then
      tune_replace "$nginx_conf" \
        '^([[:space:]]*server[[:space:]]+)(127\.0\.0\.1|localhost):9000;' \
        "\\1unix:${php_socket};" "angie.conf: local_php upstream -> Unix socket"
    fi
  fi

  if [[ -n $f_fcgi ]]; then
    tune_replace "$f_fcgi" \
      '^(.*keys_zone=fastcgicache:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${fcgi_zone}m max_size=${fcgi_size}\\3" \
      "${f_fcgi#"${target}"/}: ${fcgi_zone}m zone / ${fcgi_size} max"
  else
    tune_miss "http.d: no active fastcgi_cache_path"
  fi
  if [[ -n $f_chev ]]; then
    tune_replace "$f_chev" \
      '^(.*keys_zone=fastcgicache_chev:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${chev_zone}m max_size=${chev_size}\\3" \
      "${f_chev#"${target}"/}: ${chev_zone}m zone / ${chev_size} max"
  else
    tune_miss "http.d: no active fastcgicache_chev cache_path"
  fi
  if [[ -n $f_xf ]]; then
    tune_replace "$f_xf" \
      '^(.*keys_zone=xfproxycache:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${xf_zone}m max_size=${xf_size}\\3" \
      "${f_xf#"${target}"/}: ${xf_zone}m zone / ${xf_size} max"
  else
    tune_miss "http.d: no active xfproxycache cache_path"
  fi
  if [[ -n $f_proxy ]]; then
    tune_replace "$f_proxy" \
      'keys_zone=proxy_cache:[0-9]+m' "keys_zone=proxy_cache:${proxy_zone}m" \
      "${f_proxy#"${target}"/}: proxy zone=${proxy_zone}m"
    tune_replace "$f_proxy" \
      'keys_zone=proxy_cdn:[0-9]+m' "keys_zone=proxy_cdn:${cdn_zone}m" \
      "${f_proxy#"${target}"/}: cdn zone=${cdn_zone}m"

    local before tmp
    before=$(file_md5 "$f_proxy")
    tmp=$(tmp_file)
    # proxy_cache_path directives commonly wrap onto a second line, so track
    # the active cache path and rewrite the first max_size seen afterwards
    # instead of only looking at the line that starts the directive.
    awk -v a="$proxy_size" -v b="$cdn_size" '
      {
        if ($0 ~ /proxy_cache_path/ && $0 ~ /keys_zone=proxy_cache:/) cache = a
        else if ($0 ~ /proxy_cache_path/ && $0 ~ /keys_zone=proxy_cdn:/) cache = b
        if (cache != "" && $0 ~ /max_size=[0-9]+[mgMG]/) {
          sub(/max_size=[0-9]+[mgMG]/, "max_size=" cache)
          cache = ""
        }
        print
        if ($0 ~ /;[[:space:]]*$/) cache = ""
      }
    ' "$f_proxy" > "$tmp"
    cat "$tmp" > "$f_proxy"
    [[ $(file_md5 "$f_proxy") != "$before" ]] \
      && tune_note "${f_proxy#"${target}"/}: proxy=${proxy_size} cdn=${cdn_size}"
  else
    tune_miss "http.d: no active proxy_cache_path"
  fi

  limit_post=$(tune_clamp $(( mem_mb / 4096 )) 8 32)
  limit_get=$(tune_clamp $(( mem_mb / 2048 )) 16 64)
  if [[ -n $f_limit ]]; then
    tune_replace "$f_limit" \
      'zone=limit_req_post_head:[0-9]+m' "zone=limit_req_post_head:${limit_post}m" \
      "${f_limit#"${target}"/}: POST zone=${limit_post}m"
    tune_replace "$f_limit" \
      'zone=limit_req_get_perip:[0-9]+m' "zone=limit_req_get_perip:${limit_get}m" \
      "${f_limit#"${target}"/}: GET zone=${limit_get}m"
    # A flood of rejected requests must not turn into a flood of log writes:
    # at 20k req/s the per-rejection warning wrote 266 MB of error log in two
    # minutes (measured), which is a self-inflicted disk bottleneck.  Log
    # rejections at info level (below the configured warn error_log level);
    # the 429 count stays visible in the Angie status and access metrics.
    tune_replace "$f_limit" \
      '^([[:space:]]*limit_req_log_level[[:space:]]+)[a-z]+;' '\1info;' \
      "${f_limit#"${target}"/}: limit_req_log_level=info"
    tune_ensure_line "$f_limit" '^[[:space:]]*limit_req_log_level[[:space:]]' \
      'limit_req_log_level info;' "${f_limit#"${target}"/}: added limit_req_log_level=info"
    tune_limit_req_exemptions "$f_limit" "${f_limit#"${target}"/}"
    persist_limit_req_exemptions
  else
    tune_miss "http.d: no active limit_req_zone"
  fi

  # Bound custom cache paths that are not part of the standard set.  Scan
  # only files Angie includes, so inert legacy leftovers are left untouched.
  local extra_zone extra_max file tmp
  local -a cache_files=()
  extra_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)
  if (( active_weight == 0 )); then
    # No standard cache type is present: the whole budget is available to
    # whatever custom cache path the host actually uses.
    extra_max=$cache_total_mb
    (( extra_max < 64 )) && extra_max=64
  else
    extra_max=$(tune_clamp $(( cache_total_mb / 8 )) 64 1024)
  fi
  if (( ${#TUNE_ACTIVE_HTTP[@]} > 0 )); then
    cache_files=("${TUNE_ACTIVE_HTTP[@]}")
  else
    mapfile -t cache_files < <(grep -rlE '^[[:space:]]*(fastcgi|proxy)_cache_path[[:space:]]' \
      "$target/http.d" 2>/dev/null || true)
  fi
  for file in "${cache_files[@]}"; do
    [[ -n $file ]] || continue
    if [[ $file == "${f_fcgi:-}" || $file == "${f_chev:-}" || \
          $file == "${f_xf:-}" || $file == "${f_proxy:-}" ]]; then
      continue
    fi
    tmp=$(tmp_file)
    awk -v zcap="$extra_zone" -v mcap="$extra_max" '
      function cap_zone(line,    s, n, unit, mb, repl) {
        if (!match(line, /keys_zone=[A-Za-z0-9_]+:[0-9]+[mMgG]/)) return line
        s = substr(line, RSTART, RLENGTH)
        n = s; sub(/^.*:/, "", n)
        unit = substr(n, length(n), 1); sub(/[mMgG]$/, "", n)
        mb = (unit == "g" || unit == "G") ? n * 1024 : n
        if (mb + 0 <= zcap) return line
        repl = s; sub(/:[0-9]+[mMgG]$/, ":" zcap "m", repl)
        return substr(line, 1, RSTART - 1) repl substr(line, RSTART + RLENGTH)
      }
      {
        line = cap_zone($0)
        if (match(line, /max_size=[0-9]+[mMgG]/)) {
          s = substr(line, RSTART, RLENGTH)
          n = s; sub(/^max_size=/, "", n)
          unit = substr(n, length(n), 1); sub(/[mMgG]$/, "", n)
          mb = (unit == "g" || unit == "G") ? n * 1024 : n
          if (mb + 0 > mcap) {
            repl = "max_size=" mcap "M"
            line = substr(line, 1, RSTART - 1) repl substr(line, RSTART + RLENGTH)
          }
        } else if (line ~ /^[[:space:]]*(fastcgi|proxy)_cache_path[[:space:]]/ \
                   && line ~ /;[[:space:]]*$/) {
          sub(/;[[:space:]]*$/, " max_size=" mcap "M;", line)
        }
        print line
      }
    ' "$file" > "$tmp"
    if commit_if_changed "$file" "$tmp"; then
      tune_note "${file#"${target}"/}: custom cache capped at ${extra_zone}m zone / ${extra_max}M max"
    fi
  done

  tune_replace "$target/h5bp/tls/ssl_engine.conf" \
    '^([[:space:]]*ssl_session_cache[[:space:]]+shared:SSL:)[0-9]+m;' \
    "\\1${ssl_cache_mb}m;" "h5bp/tls/ssl_engine.conf: SSL cache=${ssl_cache_mb}m"
  tune_replace "$target/h5bp/web_performance/cache-file-descriptors.conf" \
    'open_file_cache max=[0-9]+' "open_file_cache max=${open_files}" \
    "h5bp/web_performance/cache-file-descriptors.conf: max=${open_files}"
  tune_replace "$target/h5bp/web_performance/cache-file-descriptors.conf" \
    'open_log_file_cache max=[0-9]+' "open_log_file_cache max=$(( open_files / 4 ))" \
    "h5bp/web_performance/cache-file-descriptors.conf: log max=$(( open_files / 4 ))"

  local php_conf
  for php_conf in "$target"/h5bp/php*.conf; do
    [[ -f $php_conf ]] || continue
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_buffer_size[[:space:]]+).*;' "\\1${body_buffer};" "${php_conf#"${target}"/}: fastcgi_buffer_size=${body_buffer}"
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_buffers[[:space:]]+).*;' "\\1${fastcgi_buffers};" "${php_conf#"${target}"/}: fastcgi_buffers=${fastcgi_buffers}"
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_busy_buffers_size[[:space:]]+).*;' "\\1${fastcgi_busy};" "${php_conf#"${target}"/}: fastcgi_busy_buffers_size=${fastcgi_busy}"
  done

  tune_cache_error_policy "$target/h5bp/wordpress_cache.conf" "h5bp/wordpress_cache.conf"
  tune_cache_error_policy "$target/h5bp/php_xf.conf" "h5bp/php_xf.conf"
  tune_cache_error_policy "$target/h5bp/php_xf_proxy.conf" "h5bp/php_xf_proxy.conf"
  tune_cache_error_policy "$target/h5bp/php_chev.conf" "h5bp/php_chev.conf"
  tune_cache_error_policy "$target/h5bp/php_flarum.conf" "h5bp/php_flarum.conf"
  # The cache key references $setup_cache_enc, so the map that defines it
  # must exist before the first XenForo vhost is tested (a fresh install
  # tunes the include long before --domain app=xf runs).
  ensure_xf_cookie_bypass_map "$target" || true
  tune_xf_cache_vary "$target/h5bp/php_xf.conf"
  tune_xf_cache_vary "$target/h5bp/php_xf_proxy.conf"
  tune_xf_static_assets "$target/h5bp/xf2.conf"

  tune_summary "angie summary: ${nproc} CPU / ${mem_mb}MB RAM / ${disk_class} / cache_budget=${cache_total_mb}MB"
  return 0
}

# ---------------------------------------------------------------------------
# PHP-FPM
# ---------------------------------------------------------------------------
tune_pool_set() {
  local file=$1 key=$2 value=$3 desc=$4 tmp
  local escaped=${key//./\\.}
  tmp=$(tmp_file) || return 1
  if grep -qE "^[[:space:]]*${escaped}[[:space:]]*=" "$file"; then
    sed -E "s|^[[:space:]]*${escaped}[[:space:]]*=.*|${key} = ${value}|" "$file" > "$tmp" \
      || return 1
  else
    cat -- "$file" > "$tmp" || return 1
    printf '%s = %s\n' "$key" "$value" >> "$tmp"
  fi
  commit_if_changed "$file" "$tmp" && tune_note "$desc"
  return 0
}

# Collapse duplicate directives for keys this script owns, keeping the last
# occurrence (php-fpm's own precedence), without reordering unrelated lines.
tune_pool_dedupe() {
  local file=$1
  shift
  local keys="$*" tmp
  [[ -f $file ]] || return 0
  tmp=$(tmp_file)
  awk -v keys="$keys" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) managed[k[i]] = 1 }
    {
      # Directives are only duplicates inside the same [section]; rlimit_files
      # is valid both globally (master) and in a pool (workers).
      if (match($0, /^[ \t]*\[[^]]+\]/)) {
        section = substr($0, RSTART, RLENGTH)
        gsub(/^[ \t]+|[ \t]+$/, "", section)
      }
      key = ""
      if (match($0, /^[ \t]*[^ \t=]+/)) {
        key = substr($0, RSTART, RLENGTH)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
      }
      if (key in managed) last[section SUBSEP key] = NR
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (match(lines[i], /^[ \t]*\[[^]]+\]/)) {
          section = substr(lines[i], RSTART, RLENGTH)
          gsub(/^[ \t]+|[ \t]+$/, "", section)
        }
        key = ""
        if (match(lines[i], /^[ \t]*[^ \t=]+/)) {
          key = substr(lines[i], RSTART, RLENGTH)
          gsub(/^[ \t]+|[ \t]+$/, "", key)
        }
        if ((key in managed) && last[section SUBSEP key] != i) continue
        print lines[i]
      }
    }' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "$(basename "$file"): removed duplicate managed directives"
  return 0
}

# PHP-FPM opens the pool slowlog/access log when the master starts.  A pool
# upgraded from an older package can still point at a directory that no
# longer exists; enabling request_slowlog_timeout then makes `php-fpm -t`
# fail.  Create the configured parent directory first and, for a fixed path,
# the file itself.  Paths containing a runtime variable (for example
# "$pool.access.log") only get their directory created.
ensure_fpm_log_path() {
  local path=$1 user=${2:-www-data} group=${3:-www-data} dir created=0
  [[ $path == /* ]] || return 0
  dir=$(dirname -- "$path")
  mkdir -p "$dir" 2>/dev/null || return 0
  if [[ ${path##*/} != *'$'* ]]; then
    if [[ ! -e $path ]]; then
      : > "$path" 2>/dev/null || true
      created=1
    fi
    chmod 640 "$path" 2>/dev/null || true
    if (( created )) && getent passwd "$user" >/dev/null 2>&1; then
      chown "$user:$group" "$path" 2>/dev/null || true
    fi
  fi
  return 0
}

# The php-fpm master waits forever for workers when process_control_timeout is
# 0 (the package default).  On a busy pool a stop/restart then sits in
# systemd's "deactivating" state until TimeoutStopSec, and the shared socket
# is gone for the whole window (all PHP vhosts return 502).  Bound it.
ensure_fpm_global_timeout() {
  local ver=$1
  local conf="/etc/php/${ver}/fpm/php-fpm.conf"
  [[ -f $conf ]] || return 0
  if grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=' "$conf"; then
    grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=[[:space:]]*10s' "$conf" \
      && return 0
    sed_in_place -E 's|^[[:space:]]*process_control_timeout[[:space:]]*=.*|process_control_timeout = 10s|' "$conf"
  elif grep -qE '^[[:space:]]*include[[:space:]]*=' "$conf"; then
    # Everything after the pool include is parsed inside the last included
    # pool section, so a global directive must go *before* it.
    sed_in_place -E '/^[[:space:]]*include[[:space:]]*=/i\
; setup.sh: bound master/worker shutdown so a busy pool restarts in seconds\
process_control_timeout = 10s' "$conf"
  else
    printf '\n; setup.sh: bound master/worker shutdown so a busy pool restarts in seconds\nprocess_control_timeout = 10s\n' >> "$conf"
  fi
  tune_note "PHP ${ver}: process_control_timeout=10s"
  return 0
}

# Old hosts can still carry a pre-1.8.41 custom_dan.ini (2 GB memory_limit,
# OPcache JIT off, curl_exec/exec disabled).  The managed
# zz-setup-optimize.ini overrides some values, but not allow_url_fopen or
# disable_functions, and removing the managed file would expose the stale
# limits.  --optimize refreshes the managed template while keeping the
# host's existing date.timezone.
sync_php_ini_template() {
  local ver=$1 target=${2:-} template=${3:-}
  if [[ -z $target ]]; then
    [[ -d /etc/php/${ver}/fpm ]] || return 0
    target="/etc/php/${ver}/fpm/conf.d/custom_dan.ini"
  fi
  [[ -n $template ]] || template="${SCRIPT_DIR}/configs/php/custom_dan.ini"
  [[ -f $template ]] || { tune_miss "PHP ${ver}: custom_dan.ini template not found"; return 0; }

  # Precedence: an explicit install timezone (--basic time=), then the live
  # ini value, then the host's timezone.  timedatectl is the authority on
  # current Ubuntu: /etc/timezone can stay stale after `timedatectl
  # set-timezone` (observed on 26.04: /etc/timezone said America/Los_Angeles
  # while the live zone was Asia/Manila), and reading it made --optimize
  # rewrite the timezone an install had just written.
  local tz=${PHP_INI_TZ:-}
  if [[ -z $tz && -f $target ]]; then
    tz=$(ini_get "$target" date.timezone)
  fi
  if [[ -z $tz ]]; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    tz=${tz//[[:space:]]/}
  fi
  if [[ -z $tz && -r /etc/timezone ]]; then
    tz=$(head -n1 /etc/timezone | tr -d '[:space:]')
  fi

  local tmp
  tmp=$(tmp_file) || return 1
  if [[ -n $tz ]]; then
    awk -v tz="$tz" '
      /^[[:space:]]*date\.timezone[[:space:]]*=/ {
        print "date.timezone = " tz
        done = 1
        next
      }
      { print }
      END { if (!done) print "date.timezone = " tz }
    ' "$template" > "$tmp"
  else
    cat "$template" > "$tmp"
  fi

  # Never leave a global cgi.fix_pathinfo override in the default template.
  # With fix_pathinfo=0 PHP-FPM prefers PATH_TRANSLATED; the deployed PHP
  # includes used to map that to the document root, so every pretty URL was
  # denied.  The opt-in hardening block writes the value deliberately after
  # PATH_TRANSLATED is repaired.
  if [[ ${SETUP_PHP_SESSION_HARDENING:-0} != 1 ]] \
     && grep -qE '^[[:space:]]*cgi\.fix_pathinfo[[:space:]]*=' "$tmp"; then
    local cleaned
    cleaned=$(tmp_file) || return 1
    grep -vE '^[[:space:]]*cgi\.fix_pathinfo[[:space:]]*=' "$tmp" > "$cleaned" || true
    cat "$cleaned" > "$tmp"
  fi

  if [[ -f $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cat "$tmp" > "$target"
  chmod 644 "$target"
  tune_note "PHP ${ver}: custom_dan.ini refreshed from template"
  return 0
}

# Path of the php-fpm binary for a version (PATH first, then the Debian
# location), or non-zero when the version is not installed.
php_fpm_binary() {
  local ver=$1 bin
  if bin=$(command -v "php-fpm${ver}" 2>/dev/null) && [[ -n $bin ]]; then
    printf '%s' "$bin"
  elif [[ -x "/usr/sbin/php-fpm${ver}" ]]; then
    printf '%s' "/usr/sbin/php-fpm${ver}"
  else
    return 1
  fi
}

# Point a pool at its listener (socket path or address) with the socket
# owner, group and mode Angie expects.  Shared by the pool tuner and the
# TCP-to-socket migration.  listen.allowed_clients is meaningless (and noisy)
# for a Unix socket, so it is dropped there.
php_pool_set_listener() {
  local pool=$1 ver=$2 socket=$3
  tune_pool_set "$pool" listen "$socket" "PHP ${ver}: listen=${socket}"
  if [[ $socket == /* ]] && grep -qE '^[[:space:]]*listen\.allowed_clients[[:space:]]*=' "$pool"; then
    sed_in_place -E '/^[[:space:]]*listen\.allowed_clients[[:space:]]*=/d' "$pool"
    tune_note "PHP ${ver}: removed listen.allowed_clients (Unix socket)"
  fi
  tune_pool_set "$pool" listen.owner www-data "PHP ${ver}: listen.owner=www-data"
  tune_pool_set "$pool" listen.group www-data "PHP ${ver}: listen.group=www-data"
  tune_pool_set "$pool" listen.mode 0660 "PHP ${ver}: listen.mode=0660"
}

# OPcache JIT mode and buffer for the pool: always the tracing JIT with a
# buffer of an eighth of the OPcache (32..128 MB).  Shared by the ini writer
# and the dry run.  Argument: opcache.memory_consumption in MB.
#
# The buffer is reserved per PHP-FPM worker, so it is a real memory decision,
# not just a tuning knob: 512 MB OPcache / 8 = 64 MB, which on the 32-worker
# application pool is 2 GiB of reservation instead of the 4 GiB the old
# quarter-size (128 MB) buffer asked for.  Measured on the dev host (PHP 8.5.12,
# tracing JIT, 32 workers, 20 s runs): 64 MB and 128 MB were within 0.5% of
# each other on every tier (XenForo member 909 vs 906 req/s, WordPress
# member 234 vs 229); 256 MB was slower (899 / 225).  Function JIT lost 6-8%
# against tracing (guest 990 vs 1035 req/s, member 852 vs 913, thread 437 vs
# 485, WordPress 251 vs 262) and had a much worse p99 (554 ms vs 188 ms).
# JIT off cost ~5% on XenForo members (864 vs 910 req/s, p50 73 vs 69 ms) and
# was neutral on WordPress members, which is why WordPress roots can still be
# exempted with SETUP_PHP_JIT_WORDPRESS=0.
php_jit_settings() {
  local opcache_mb=${1:-128} buf
  [[ $opcache_mb =~ ^[0-9]+$ ]] || opcache_mb=128
  buf=$(tune_clamp $(( opcache_mb / 8 )) 32 128)
  # Newline-terminated: callers `read` it, and read returns 1 at EOF without one.
  printf 'tracing %s\n' "$buf"
}

# Tracing-JIT hotness thresholds.  Higher values compile later (less CPU
# spent in the JIT, more in the interpreter); lower values compile sooner.
# PHP's defaults are used on every host with four or more effective CPUs: an
# aggressive set (16/64/8/32) measured within noise of the defaults on the dev host,
# while a conservative set (128/255/32/128) lost 3-4% on the member tiers.
# A 1-2 CPU host pays proportionally more for compilation, so it gets the
# conservative set, which keeps the single PHP worker serving requests.
# SETUP_PHP_JIT_HOT_{LOOP,FUNC,RETURN,SIDE_EXIT} override each value.
php_jit_threshold_lines() {
  local cpu=${1:-0} loop=64 func=127 ret=16 side=64
  [[ $cpu =~ ^[0-9]+$ ]] && (( cpu > 0 )) || cpu=$(effective_cpus)
  if (( cpu <= 2 )); then
    loop=128; func=255; ret=32; side=128
  fi
  [[ ${SETUP_PHP_JIT_HOT_LOOP:-} =~ ^[0-9]+$ ]] && loop=$SETUP_PHP_JIT_HOT_LOOP
  [[ ${SETUP_PHP_JIT_HOT_FUNC:-} =~ ^[0-9]+$ ]] && func=$SETUP_PHP_JIT_HOT_FUNC
  [[ ${SETUP_PHP_JIT_HOT_RETURN:-} =~ ^[0-9]+$ ]] && ret=$SETUP_PHP_JIT_HOT_RETURN
  [[ ${SETUP_PHP_JIT_HOT_SIDE_EXIT:-} =~ ^[0-9]+$ ]] && side=$SETUP_PHP_JIT_HOT_SIDE_EXIT
  printf 'opcache.jit_hot_loop = %s\nopcache.jit_hot_func = %s\nopcache.jit_hot_return = %s\nopcache.jit_hot_side_exit = %s\n' \
    "$loop" "$func" "$ret" "$side"
}

# [PATH=] sections that keep the JIT off for every WordPress document root
# when SETUP_PHP_JIT_WORDPRESS=0 asks for it.  php-fpm applies a PATH
# section at request start and restores the global value afterwards, so the
# setting cannot leak to the next vhost the way a fastcgi_param
# PHP_ADMIN_VALUE does.  Prints nothing by default (WordPress uses the JIT).
php_jit_path_sections() {
  local target=${1:-/etc/angie} file root
  (( PHP_JIT_WORDPRESS )) && return 0
  [[ -d $target/conf.d ]] || return 0
  while IFS= read -r file; do
    root=$(angie_vhost_root "$file")
    [[ -n $root ]] || continue
    printf '\n; %s: WordPress keeps the bytecode cache only (SETUP_PHP_JIT_WORDPRESS=1 lifts this)\n[PATH=%s]\nopcache.jit = off\n' "$(basename "$file" .conf)" "$root"
  done < <(angie_wordpress_vhosts "$target" | sort -u)
}

# Keep the operator's WordPress JIT choice in /etc/default/setup-tuning so a
# plain --optimize does not silently change it.  Written once per run.
PHP_JIT_PERSISTED=0
persist_php_jit() {
  if (( PHP_JIT_WORDPRESS_PERSIST )); then
    persist_tuning_var PHP_JIT_WORDPRESS "$PHP_JIT_WORDPRESS"
    tune_note "PHP: PHP_JIT_WORDPRESS=${PHP_JIT_WORDPRESS} persisted in /etc/default/setup-tuning"
  fi
}

# RAM-derived php.ini values shared by the tuner and the dry-run preview so
# the plan and the written file cannot disagree.
php_ini_profile() {
  local ram_mb=${1:-1024}
  [[ $ram_mb =~ ^[0-9]+$ ]] && (( ram_mb > 0 )) || ram_mb=1024
  PHP_PROFILE_OPCACHE_MB=$(( ram_mb / 16 ))
  (( PHP_PROFILE_OPCACHE_MB < 128 )) && PHP_PROFILE_OPCACHE_MB=128
  (( PHP_PROFILE_OPCACHE_MB > 512 )) && PHP_PROFILE_OPCACHE_MB=512
  PHP_PROFILE_MEMORY_MB=$(( ram_mb / 8 ))
  (( PHP_PROFILE_MEMORY_MB < 256 )) && PHP_PROFILE_MEMORY_MB=256
  (( PHP_PROFILE_MEMORY_MB > 512 )) && PHP_PROFILE_MEMORY_MB=512
  # Under 2 GB a 256M per-request ceiling lets a handful of workers claim
  # the whole host; XenForo and WordPress run within 128M.
  (( ram_mb < 2048 )) && PHP_PROFILE_MEMORY_MB=128
  PHP_PROFILE_REALPATH_KB=$(( ram_mb * 2 ))
  (( PHP_PROFILE_REALPATH_KB < 4096 )) && PHP_PROFILE_REALPATH_KB=4096
  (( PHP_PROFILE_REALPATH_KB > 16384 )) && PHP_PROFILE_REALPATH_KB=16384
  # Called plainly under set -e: a false clamp test above must not become
  # the function's exit status.
  return 0
}
PHP_PROFILE_OPCACHE_MB=128
PHP_PROFILE_MEMORY_MB=256
PHP_PROFILE_REALPATH_KB=4096

# opcache.max_accelerated_files for the PHP files under the Angie vhost
# roots (plus /var/www/*/public without Angie): count * 1.5, clamped to
# 16384..128256; the old 128256 ceiling when no root can be found.
php_accelerated_files_target() {
  local file root count=0 n
  local -a roots=()
  for file in /etc/angie/conf.d/*.conf; do
    [[ -f $file ]] || continue
    root=$(angie_vhost_root "$file" 2>/dev/null || true)
    [[ -n $root && -d $root ]] && roots+=("$root")
  done
  if (( ${#roots[@]} == 0 )); then
    for root in /var/www/*/public; do
      [[ -d $root ]] && roots+=("$root")
    done
  fi
  if (( ${#roots[@]} == 0 )); then
    printf '128256'
    return 0
  fi
  n=$(find "${roots[@]}" -xdev -type f -name '*.php' 2>/dev/null | wc -l | tr -d ' ')
  [[ $n =~ ^[0-9]+$ ]] && count=$n
  (( count == 0 )) && { printf '128256'; return 0; }
  printf '%s' "$(tune_clamp $(( count * 3 / 2 )) 16384 128256)"
}

tune_php_fpm_version() {
  local ver=$1
  local socket=${2:-}
  local pool="/etc/php/${ver}/fpm/pool.d/www.conf"
  local ini_dir="/etc/php/${ver}/fpm/conf.d"
  local ini="${ini_dir}/zz-setup-optimize.ini"
  [[ -d /etc/php/${ver}/fpm ]] || return 0
  [[ -f $pool ]] || { tune_miss "PHP ${ver}: no pool.d/www.conf, skipped"; return 0; }  # With no explicit socket request, keep whatever the pool already listens on
  # (TCP for a standalone PHP host, Unix socket for an Angie deployment).
  if [[ -z $socket ]]; then
    socket=$(php_pool_listen "$ver")
    [[ -n $socket ]] || socket=/run/php/php-fpm.sock
  fi

  local nproc ram_mb max_children max_requests php_budget backlog
  local opcache_mb memory_mb realpath_kb
  local current_children
  nproc=$(effective_cpus)
  (( nproc > 0 )) || nproc=1
  ram_mb=$(mem_total_mb)
  backlog=$(effective_backlog)

  php_budget=${OPT_PHP_BUDGET_MB:-0}
  # Capacity and reservation are different numbers.  A live pool keeps its
  # worker count even when the measured per-worker allowance rises; a fresh
  # pool is derived from the budget at the standard 96 MB divisor.  The 50%
  # of RAM ceiling still prevents a small host from overcommitting.
  current_children=$(php_pool_max_children)
  # install_php() sets PHP_FRESH_INSTALL: the package may have auto-started
  # its stock 64-worker pool, and that placeholder must not override the
  # hardware-sized pool.
  [[ ${PHP_FRESH_INSTALL:-0} == 1 ]] && current_children=0
  local live_children="" explicit_value
  if (( current_children > 0 )) \
     && systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
    # A live pool keeps its worker count: the reservation is a memory
    # estimate, not a worker quota.
    live_children=$current_children
  fi
  # An explicit --php children=/max_requests= written at install time is an
  # operator decision, not a hardware guess: keep it across --optimize runs.
  explicit_value=$(explicit_option php_children 2>/dev/null || true)
  max_children=$(php_plan_max_children "$nproc" "$ram_mb" "$live_children" "$explicit_value" "$php_budget")
  if [[ -z $explicit_value ]]; then
    # Informational: the note must not mark the pool dirty, or every
    # --optimize on a host already at the target reloads an unchanged PHP-FPM.
    local per_cpu
    per_cpu=$(awk -v t="$(php_workers_per_cpu_tenths)" 'BEGIN{printf "%.1f", t/10}')
    tune_summary "PHP ${ver}: max_children=${max_children} (hardware target: ${per_cpu} workers per logical CPU; --php children= overrides)"
  fi
  PHP_WRITTEN_CHILDREN=$max_children
  # A pool far larger than the plan is the most expensive misconfiguration
  # seen in the field: a 64-thread host ran 512 static workers (51.8 GB
  # resident, ~103 MB each) and served the same ~850 thread-page req/s as 64
  # workers with a 4x better p50.  Report the delta so the operator sees the
  # memory and latency the next reload returns.
  if (( current_children > 0 )) && (( current_children > max_children * 2 )); then
    local per_worker was_gb now_gb
    per_worker=$(php_worker_allowance_mb "$ver" 2>/dev/null || true)
    [[ $per_worker =~ ^[0-9]+$ ]] && (( per_worker > 0 )) || per_worker=96
    was_gb=$(( current_children * per_worker / 1024 ))
    now_gb=$(( max_children * per_worker / 1024 ))
    tune_summary "PHP ${ver}: pool right-sized ${current_children} -> ${max_children} workers (~${was_gb} GB -> ~${now_gb} GB resident at ${per_worker} MB each; a pool deeper than the thread count only queues on the scheduler)"
  fi
  max_requests=$(( nproc * 1024 ))
  if explicit_value=$(explicit_option php_max_requests); then
    [[ $explicit_value =~ ^[0-9]+$ ]] && (( explicit_value > 0 )) && max_requests=$explicit_value
  fi

  php_ini_profile "$ram_mb"
  opcache_mb=$PHP_PROFILE_OPCACHE_MB
  # The tracing JIT is always on (see the top of the file); WordPress roots
  # can be exempted through [PATH=] sections with SETUP_PHP_JIT_WORDPRESS=0.
  local jit_mode jit_buffer_mb jit_buffer
  read -r jit_mode jit_buffer_mb < <(php_jit_settings "$opcache_mb")
  jit_buffer="${jit_buffer_mb}M"
  # Scripts restored from the OPcache file cache are never JIT-compiled
  # (measured: with the file cache in place the JIT buffer stayed at 2.5 KB
  # through a full load test on 8.4; with it cleared the same warm-up
  # compiled 850 KB).  The file cache only warms restarts, so it stays off.
  local opcache_file_cache=""
  memory_mb=$PHP_PROFILE_MEMORY_MB
  realpath_kb=$PHP_PROFILE_REALPATH_KB

  mkdir -p /run/php
  chown www-data:www-data /run/php 2>/dev/null || true
  chmod 755 /run/php

  # Always a static pool: the worker count is already sized to the host
  # (php_plan_max_children), resident workers answer the first request after
  # an idle period without a fork, and a fixed footprint is what the shared
  # memory plan budgets for.
  tune_pool_set "$pool" pm static "PHP ${ver}: pm=static"
  tune_pool_set "$pool" pm.max_children "$max_children" "PHP ${ver}: max_children=${max_children}"
  tune_pool_set "$pool" pm.max_requests "$max_requests" "PHP ${ver}: max_requests=${max_requests}"
  php_pool_set_listener "$pool" "$ver" "$socket"
  tune_pool_set "$pool" listen.backlog "$backlog" "PHP ${ver}: listen.backlog=${backlog}"
  # Ensure the pool's log destinations exist before enabling slow logging.  A
  # pool upgraded from an older package may still point slowlog at a
  # directory that no longer exists (seen on Ubuntu 24.04); php-fpm -t then
  # fails as soon as request_slowlog_timeout is set.
  local fpm_user fpm_group slowlog accesslog poollog
  fpm_user=$(ini_get "$pool" user)
  fpm_group=$(ini_get "$pool" group)
  slowlog=$(ini_get "$pool" slowlog)
  accesslog=$(ini_get "$pool" access.log)
  poollog=$(ini_get "$pool" error_log)
  if [[ -z $slowlog ]]; then
    slowlog=/var/www/logs/php/php-fpm-slow.log
    tune_pool_set "$pool" slowlog "$slowlog" "PHP ${ver}: slowlog=${slowlog}"
  fi
  ensure_fpm_log_path "$slowlog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  ensure_fpm_log_path "$accesslog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  ensure_fpm_log_path "$poollog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  tune_pool_set "$pool" request_terminate_timeout 300s "PHP ${ver}: request_terminate_timeout=300s"
  tune_pool_set "$pool" request_slowlog_timeout 10s "PHP ${ver}: request_slowlog_timeout=10s"
  tune_pool_set "$pool" catch_workers_output yes "PHP ${ver}: catch_workers_output=yes"
  tune_pool_set "$pool" security.limit_extensions .php "PHP ${ver}: security.limit_extensions=.php"
  tune_pool_set "$pool" rlimit_files 524288 "PHP ${ver}: rlimit_files=524288"
  tune_pool_set "$pool" rlimit_core 0 "PHP ${ver}: rlimit_core=0"
  # Bound master/worker shutdown; see ensure_fpm_global_timeout().
  ensure_fpm_global_timeout "$ver"
  # Older pool templates carried a [global] block inside pool.d/www.conf.
  # pool.d is included after the global settings, so that copy wins over the
  # 10s written above.  Normalise it in place so a restart cannot reintroduce
  # the 60s shutdown wait.
  if grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=' "$pool"; then
    if ! grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=[[:space:]]*10s[[:space:]]*(;.*)?$' "$pool"; then
      sed_in_place -E 's|^[[:space:]]*process_control_timeout[[:space:]]*=.*|process_control_timeout = 10s|' "$pool"
      tune_note "PHP ${ver}: pool-level process_control_timeout=10s"
    fi
  fi

  # Older releases appended the same directive more than once (the live
  # 8.3 pool carried two rlimit_files/rlimit_core pairs).  php-fpm lets the
  # last value win, but duplicates make the file confusing and hide drift.
  tune_pool_dedupe "$pool" \
    user group listen listen.allowed_clients listen.backlog listen.owner \
    listen.group listen.mode pm pm.max_children pm.max_requests \
    request_terminate_timeout catch_workers_output security.limit_extensions \
    rlimit_files rlimit_core process_control_timeout
  # OPcache's script table is sized from the PHP files the vhosts actually
  # hold (XenForo ~8k, WordPress ~5k, plus 50% for plugins and updates),
  # instead of the 128k ceiling that reserved shared memory for scripts that
  # never exist; the ceiling stays for a host whose roots cannot be found.
  local accel_files
  accel_files=$(php_accelerated_files_target)

  mkdir -p "$ini_dir" /var/cache/php/opcache
  chown -R www-data:www-data /var/cache/php 2>/dev/null || true
  chmod 750 /var/cache/php /var/cache/php/opcache 2>/dev/null || true
  # The pool template names its own version (pid path); rewrite any phpN.N,
  # not only php8.x, so a 9.x pool is handled the same way.  The listener is
  # excluded: php_pool_set_listener already wrote the path Angie points at,
  # and renaming a versioned socket here would leave the upstream dangling.
  sed_in_place -E "/^[[:space:]]*listen[[:space:]]*=/! s|php[0-9]+\.[0-9]+|php${ver}|g" "$pool"
  local ini_before=""
  [[ -f $ini ]] && ini_before=$(file_md5 "$ini")
  cat > "$ini" <<EOF
; Managed by setup.sh --optimize (hardware-aware PHP tuning).
; This file sorts last in conf.d so it wins over earlier defaults.
memory_limit = ${memory_mb}M
max_execution_time = 300
max_input_time = 300
realpath_cache_size = ${realpath_kb}k
realpath_cache_ttl = 43200
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${opcache_mb}
opcache.interned_strings_buffer = $(( opcache_mb / 8 < 16 ? 16 : (opcache_mb / 8 > 64 ? 64 : opcache_mb / 8) ))
opcache.jit = ${jit_mode}
opcache.jit_buffer_size = ${jit_buffer}
$(php_jit_threshold_lines "$nproc")
opcache.max_accelerated_files = ${accel_files}
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
opcache.file_cache = ${opcache_file_cache}
opcache.file_cache_only = 0
mysqlnd.net_cmd_buffer_size = 524288
mysqli.default_socket = /run/mysqld/mysqld.sock
pdo_mysql.default_socket = /run/mysqld/mysqld.sock
EOF
  if [[ ${SETUP_PHP_SESSION_HARDENING:-0} == 1 ]]; then
    local php_error_log=/var/www/logs/php/php-error.log
    ensure_fpm_log_path "$php_error_log" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
    cat >> "$ini" <<EOF

; Optional session/cgi hardening, enabled with SETUP_PHP_SESSION_HARDENING=1.
; Not written by default: strict session IDs and Secure cookies can break
; Joomla/Polr sites and applications that validate PHP session identifiers.
cgi.fix_pathinfo = 0
expose_php = Off
display_errors = Off
log_errors = On
error_log = ${php_error_log}
session.use_strict_mode = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
session.cookie_secure = 1
session.cookie_samesite = Lax
session.gc_maxlifetime = 14400
session.sid_length = 48
session.sid_bits_per_character = 6
EOF
  fi
  # Per-directory sections must come last: everything after a section header
  # belongs to that section.
  php_jit_path_sections /etc/angie >> "$ini"
  chmod 644 "$ini"
  if (( ! PHP_JIT_PERSISTED )); then
    persist_php_jit
    PHP_JIT_PERSISTED=1
  fi
  local ini_after jit_desc="${jit_mode}/${jit_buffer}"
  (( PHP_JIT_WORDPRESS )) || jit_desc+=" (WordPress roots off)"
  ini_after=$(file_md5 "$ini")
  if [[ $ini_before != "$ini_after" ]]; then
    tune_note "PHP ${ver}: memory_limit=${memory_mb}M opcache=${opcache_mb}M jit=${jit_desc}"
    if [[ ${SETUP_PHP_SESSION_HARDENING:-0} == 1 ]]; then
      tune_note "PHP ${ver}: optional session/cgi hardening"
    fi
  fi

  local fpm_bin fpm_test
  fpm_bin=$(php_fpm_binary "$ver" || true)
  if [[ -n $fpm_bin ]]; then
    fpm_test=$(tmp_file)
    if ! "$fpm_bin" -t >"$fpm_test" 2>&1; then
      printf 'PHP %s: php-fpm -t failed:\n' "$ver" >&2
      sed 's/^/  /' "$fpm_test" >&2 || true
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Angie dynamic compression (Brotli only)
# ---------------------------------------------------------------------------
# Brotli was chosen over Zstandard after live measurements on a 16-thread
# host.  At level 5 on a 149 KB XenForo thread page, Brotli produced 10.9 KB
# vs 13.7 KB for gzip (-20%) and 11.9 KB for Zstandard.  Zstandard was faster
# to produce (29k vs 16k compressed responses/s on a 34 KB page), but dynamic
# PHP is the bottleneck on uncached pages (~1k req/s logged-in), so Brotli's
# smaller payload wins page load time.  Gzip remains the compatibility
# fallback.  Brotli is the only extra module loaded.
#
# Static assets are intentionally not precompressed.  A CDN normally caches
# them and only the first request reaches the origin; the expensive work here
# is compressing per-user dynamic HTML on every uncached request.
ANGIE_COMPRESSION_CHANGED=0
ANGIE_COMPRESSION_SKIPPED=0
ANGIE_BROTLI_OK=0
ANGIE_BROTLI_LEVEL=4

# Dynamic Brotli level: SETUP_BROTLI_LEVEL when valid, otherwise 5, or 4 on a
# 1-2 CPU host where per-response compression competes with PHP for cores.
# One owner for the install, --optimize and dry-run values.
angie_brotli_level() {
  local level=${SETUP_BROTLI_LEVEL:-}
  if ! [[ $level =~ ^([1-9]|1[01])$ ]]; then
    # Dynamic responses only (static assets use precompressed .br siblings).
    # Measured on an 8 vCPU XenForo origin (130 KB HTML thread page, Angie
    # CPU per request): level 5 = 5.3 ms, level 4 = 2.7 ms, level 3 = 1.5 ms
    # for 21 / 23 / 24 KB on the wire.  Level 4 halves the compression CPU of
    # every member page for 10% more bytes; 1-2 CPU hosts take level 3.
    level=4
    (( $(effective_cpus) <= 2 )) && level=3
  fi
  printf '%s' "$level"
}

ensure_angie_compression() {
  local target=${1:-/etc/angie}
  local conf="${target}/angie.conf"
  [[ -f $conf ]] || return 0
  ANGIE_COMPRESSION_CHANGED=0
  ANGIE_COMPRESSION_SKIPPED=0
  ANGIE_BROTLI_OK=0

  if [[ ${SETUP_ANGIE_COMPRESSION:-1} == 0 ]]; then
    ANGIE_COMPRESSION_SKIPPED=1
    info "Angie dynamic Brotli disabled by SETUP_ANGIE_COMPRESSION=0"
    return 0
  fi

  local brotli_level static_mode=off
  brotli_level=$(angie_brotli_level)
  ANGIE_BROTLI_LEVEL=$brotli_level
  # brotli_static serves a .br sibling when one exists and falls back to the
  # dynamic filter otherwise; it is only useful with precompressed assets.
  (( PRECOMPRESS_ASSETS )) && static_mode=on

  local enabled="${target}/modules-enabled"
  local changed=0
  if ! pkg_ok angie-module-brotli; then
    # --optimize is normally install-free (except cpufrequtils).  This one
    # small module is part of the same compression profile as a fresh --angie
    # install, so installing it here keeps both paths identical.  If the
    # repository or package is unavailable, fall back to gzip.
    if ! apt-cache show angie-module-brotli >/dev/null 2>&1; then
      apt_update || true
    fi
    apt_install angie-module-brotli \
      || warn "Could not install angie-module-brotli; gzip remains active"
  fi
  pkg_ok angie-module-brotli && ANGIE_BROTLI_OK=1

  mkdir -p "$enabled" "${target}/http.d"
  local tmp moved f
  # Remove a managed Zstandard stanza left by an earlier test/release so only
  # one optional compression module is active.
  for f in "${enabled}/40-zstd.conf" "${target}/http.d/zstd.conf"; do
    [[ -e $f ]] || continue
    grep -q '^# Managed by setup.sh' "$f" 2>/dev/null || continue
    moved=$(preserve_to_tmp "$f" 2>/dev/null || true)
    [[ -n $moved ]] && info "Moved superseded Zstandard file to ${moved}"
    changed=1
  done

  if (( ANGIE_BROTLI_OK )); then
    if ! grep -Rqs 'ngx_http_brotli_filter_module' "$enabled" 2>/dev/null; then
      tmp=$(tmp_file)
      cat > "$tmp" <<'EOF'
# Managed by setup.sh: dynamic Brotli compression.
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;
EOF
      cat "$tmp" > "${enabled}/50-brotli.conf"
      chmod 644 "${enabled}/50-brotli.conf"
      changed=1
    fi
    tmp=$(tmp_file)
    if [[ -f "${target}/http.d/brotli_conf" ]]; then
      {
        printf '# Managed by setup.sh: dynamic Brotli from http.d/brotli_conf.\n'
        printf '# brotli_static %s: precompressed .br siblings (SETUP_PRECOMPRESS_ASSETS=%s).\n' "$static_mode" "$PRECOMPRESS_ASSETS"
        cat "${target}/http.d/brotli_conf"
      } > "$tmp"
      sed_in_place -E "s/^brotli_comp_level [0-9]+;/brotli_comp_level ${brotli_level};/" "$tmp"
      sed_in_place -E "s/^brotli_static (on|off);/brotli_static ${static_mode};/" "$tmp"
    else
      cat > "$tmp" <<EOF
# Managed by setup.sh: dynamic Brotli (template was missing).
brotli on;
brotli_static ${static_mode};
brotli_comp_level ${brotli_level};
brotli_min_length 50;
brotli_types text/plain text/css text/xml application/json application/javascript application/xml image/svg+xml font/ttf font/otf;
EOF
    fi
    if commit_if_changed "${target}/http.d/brotli.conf" "$tmp"; then
      chmod 644 "${target}/http.d/brotli.conf"
      changed=1
    fi
  elif [[ -f "${enabled}/50-brotli.conf" ]]; then
    warn "Angie Brotli module is not installed; keeping the existing module stanza"
  fi

  # Never leave the service unable to start because an optional module failed
  # to load.  Move the managed files to /tmp (the script never deletes) and
  # keep the gzip fallback.
  local testlog
  testlog=$(tmp_file)
  if ! /usr/sbin/angie -t >"$testlog" 2>&1; then
    warn "Angie rejected the dynamic compression configuration; disabling Brotli"
    sed 's/^/  /' "$testlog" >&2 || true
    for f in "${enabled}/50-brotli.conf" "${target}/http.d/brotli.conf"; do
      [[ -e $f ]] || continue
      moved=$(preserve_to_tmp "$f" 2>/dev/null || true)
      [[ -n $moved ]] && info "Moved rejected compression file to ${moved}"
    done
    ANGIE_BROTLI_OK=0
    changed=1
    if ! /usr/sbin/angie -t >/dev/null 2>&1; then
      warn "Angie still rejects the configuration after removing compression files"
    fi
  fi

  ANGIE_COMPRESSION_CHANGED=$changed
  if (( changed )); then
    TUNE_DIRTY=1
  fi
  return 0
}

# Fetch the canonical Angie tree and run the repository's deployer.  Kept
# separate from the tuning pass so --optimize can synchronize /etc/angie and
# then apply the hardware-aware profile to the freshly deployed files.
# ---------------------------------------------------------------------------
# Angie config tree
# ---------------------------------------------------------------------------
# This deployer used to live in the server-configs-nginx repository as a
# separate script.  It now lives here so a fresh install and `--optimize`
# share exactly one implementation: fetch -> sync tree -> hardware profile.
# deploy_angie_tree reloads a running Angie after the sync unless the caller
# tunes the tree first and reloads/restarts it itself.
ANGIE_SYNC_RELOAD=1
ANGIE_CACHE_DIRS=(/home/nginx_cache /home/nginx_cache_chev /home/xf_proxy_cache
                  /home/proxy_cache /home/proxy_cdn)

# ---------------------------------------------------------------------------
# Operator upstream preservation
# ---------------------------------------------------------------------------
# The canonical tree is synced with rsync, so a custom vhost under conf.d can
# outlive the upstream block it relied on: the repository may rename or drop an
# upstream between releases (xf_websocket -> xf_websocket_so on one host), and
# Angie then refuses to load the whole tree with
#   [emerg] host not found in upstream "soketi_websocket"
# which made --optimize fail and roll the sync back.  Snapshot every upstream
# block before the sync, then re-add only the blocks a deployed vhost still
# references and the new tree no longer defines.  The preserved block lives in
# one managed include so it is easy to inspect and is regenerated every run.
angie_tree_files() {
  local dir=$1 exclude=${2:-}
  [[ -d $dir ]] || return 0
  local -a prune=()
  [[ -n $exclude ]] && prune=(-not -path "$exclude")
  find "$dir" -type f \( -name '*.conf' -o -name '*_conf' \) \
    "${prune[@]}" -print0 2>/dev/null
}

# Names a deployed vhost passes to a *_pass directive.  Only bare names are
# upstreams; a host:port, unix: path or $variable is not.
angie_referenced_upstreams() {
  local dir=$1
  angie_tree_files "$dir" \
    | xargs -0 -r grep -hoE '(proxy_pass|grpc_pass|grpcs_pass|uwsgi_pass|scgi_pass|fastcgi_pass)[[:space:]]+[^;]+' 2>/dev/null \
    | sed -E -e 's|^[a-z_]+[[:space:]]+||' -e 's#^(https?://|grpcs?://)##' \
    | awk '{print $1}' \
    | grep -E '^[A-Za-z0-9_]+$' | sort -u || true
}

# Upstream names the tree defines.  EXCLUDE (the managed include) is skipped
# so its own definitions do not count as canonical on the next run.
angie_defined_upstreams() {
  local dir=$1 exclude=${2:-}
  angie_tree_files "$dir" "$exclude" \
    | xargs -0 -r grep -hE '^[[:space:]]*upstream[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null \
    | sed -E 's|^[[:space:]]*upstream[[:space:]]+([A-Za-z0-9_]+).*|\1|' | sort -u || true
}

# Write each "upstream NAME { ... }" block of SRC to DEST/NAME.conf.  The awk
# depth counter keeps multi-line blocks together and stops at the closing
# brace; comments before a block are not part of it.
angie_snapshot_upstreams() {
  local src=$1 dest=$2 file
  [[ -d $src && -d $dest ]] || return 0
  angie_tree_files "$src" | while IFS= read -r -d '' file; do
    awk -v out="$dest" '
      /^[[:space:]]*upstream[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/ {
        name = $2
        sub(/[[:space:]]*\{.*/, "", name)
        depth = 0
        inblock = 1
      }
      inblock {
        line = $0
        opens = gsub(/\{/, "{", line)
        line = $0
        closes = gsub(/\}/, "}", line)
        depth += opens - closes
        print $0 >> (out "/" name ".conf")
        if (depth <= 0) { inblock = 0; close(out "/" name ".conf") }
        next
      }
    ' "$file"
  done
}

# Re-add the blocks a vhost still references and the synced tree lost.
angie_restore_upstreams() {
  local target=$1 snapshot=$2
  local include="$target/http.d/zz-setup-preserved-upstreams.conf"
  local name tmp moved
  local -a referenced=() defined=() missing=()
  [[ -d $target ]] || return 0
  mapfile -t referenced < <(angie_referenced_upstreams "$target")
  mapfile -t defined < <(angie_defined_upstreams "$target" "$include")
  for name in "${referenced[@]}"; do
    [[ -n $name ]] || continue
    [[ " ${defined[*]} " == *" $name "* ]] && continue
    [[ -n $snapshot && -f "$snapshot/$name.conf" ]] || continue
    missing+=("$name")
  done
  if (( ${#missing[@]} == 0 )); then
    if [[ -f $include ]] && grep -q 'Managed by setup.sh: upstream definitions preserved' "$include" 2>/dev/null; then
      moved=$(preserve_to_tmp "$include" 2>/dev/null || true)
      [[ -n $moved ]] && info "Preserved upstream include no longer needed -> ${moved}"
    fi
    return 0
  fi
  tmp=$(tmp_file) || return 1
  {
    printf '# Managed by setup.sh: upstream definitions preserved from the previous tree.\n'
    printf '# A deployed vhost still references a name the canonical repository no\n'
    printf '# longer defines; without this block Angie refuses to load with\n'
    printf '# "host not found in upstream".  Regenerated by install/--optimize.\n'
    for name in "${missing[@]}"; do
      printf '\n# preserved from the previous /etc/angie tree: %s\n' "$name"
      # A zone name from the old tree would collide with a zone in the new one;
      # the block works without it.
      sed -E '/^[[:space:]]*zone[[:space:]]/d' "$snapshot/$name.conf"
    done
  } > "$tmp"
  if commit_if_changed "$include" "$tmp"; then
    chmod 644 "$include"
    info "Preserved upstream definition(s) still referenced by a vhost: ${missing[*]}"
  fi
  return 0
}

# Sync CONFIG_SOURCE_DIR into /etc/angie and normalise what a checkout can
# carry (ownership, modes, macOS AppleDouble files, sample keys).  The caller
# has already run fetch_server_configs.
deploy_angie_tree() {
  local target=/etc/angie
  local log_dir="${LOG_ROOT}/angie"
  local src=${CONFIG_SOURCE_DIR:-}
  [[ -n $src && -d $src ]] || { warn "No Angie config source directory available"; return 1; }

  # Capture the live upstream blocks before rsync overwrites the files that
  # define them (see angie_restore_upstreams).
  local upstream_snapshot=""
  if [[ -d $target ]]; then
    upstream_snapshot=$(tmp_dir angie-upstreams.XXXXXX) || upstream_snapshot=""
    [[ -n $upstream_snapshot ]] && angie_snapshot_upstreams "$target" "$upstream_snapshot"
  fi

  # --no-owner/--no-group + --chmod prevents a checkout owned by uid 1000 from
  # leaving writable files in /etc/angie. Never copy the sample private key.
  rsync -a --no-owner --no-group --chmod=D755,F644 \
    --exclude='*.md' --exclude='*.txt' --exclude='.git*' \
    --exclude='.github/' --exclude='test/' --exclude='.editorconfig' \
    --exclude='h5bp/tls/private.key' --exclude='h5bp/tls/certificate.pem' \
    "$src"/ "$target"/ || return 1
  mkdir -p "$target/snippets" "$target/custom.d"
  # macOS AppleDouble files appear when a local checkout is used via
  # CONFIG_SOURCE_DIR.  Move them out of the live tree; nothing is unlinked.
  local -a stale=()
  mapfile -t stale < <(find "$target" -name '._*' 2>/dev/null || true)
  (( ${#stale[@]} > 0 )) && retire_paths "${stale[@]}"

  # Legacy demo/error pages, sample keys and superseded sample templates that
  # older deployments may still carry, plus old setup.sh-managed overrides
  # that duplicated the cache zones, log_format and limiter variables now
  # provided by the repository tree (PHP-FPM templates live in configs/php).
  # None of these ship in the current repository, so each is retired once per
  # host; they go to /tmp, never to rm, per the file-safety policy.
  retire_paths "$target/test" \
        "$target"/v3.html "$target"/ua.html "$target"/503.html \
        "$target"/ssl/default/certificate.pem "$target"/ssl/default/private.key \
        "$target"/conf.d/templates/sample_basic_php.conf \
        "$target"/conf.d/templates/sample_psi.conf \
        "$target"/conf.d/templates/sample_pingvin_proxy.conf \
        "$target"/conf.d/templates/sample_proxy_pass.conf \
        "$target"/scripts/www_*.conf \
        "$target/scripts/custom_dan.ini" \
        "$target/scripts/php-fpm-limits.conf" \
        "$target/scripts/auto_tune.sh" \
        "$target/http.d/98_setup_cache.conf" \
        "$target/http.d/99_setup_overrides.conf" \
        "$target/http.d/limit_req_whitelist.conf" \
        "$target/http.d/fastcgi_cache_conf" \
        "$target/http.d/fastcgi_cache_chev_conf" \
        "$target/http.d/xf_proxy_cache_conf" \
        "$target/http.d/xf_websocket_conf" \
        "$target/http.d/limit_req_conf" \
        "$target/http.d/proxy_cache_conf" \
        "$target/http.d/referer_map_conf" \
        "$target/h5bp/limit_req/_high_conf" \
        "$target/h5bp/limit_req/_medium_conf" \
        "$target/h5bp/tls/private.key" \
        "$target/h5bp/tls/certificate.pem"

  # Re-add any operator-referenced upstream the new tree dropped (rsync
  # overwrites the file that used to define it; a custom vhost survives).
  angie_restore_upstreams "$target" "$upstream_snapshot"

  # Normalise ownership/modes for everything except operator certificates and
  # stream configs.  scripts/*.sh stay executable for the Cloudflare cron job.
  find "$target" -path "$target/ssl" -prune -o \
       -path "$target/stream.d" -prune -o \
       -exec chown root:root {} + 2>/dev/null || true
  find "$target" -path "$target/ssl" -prune -o \
       -path "$target/stream.d" -prune -o \
       -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$target" -path "$target/ssl" -prune -o \
       -path "$target/stream.d" -prune -o \
       -type f -exec chmod 644 {} + 2>/dev/null || true
  chmod 755 "$target"/scripts/*.sh 2>/dev/null || true

  # The catch-all 443 server needs a unique local certificate.  The repository
  # ships no private key; generate one per host instead.
  if [[ ! -s "$target/ssl/default/fullchain.pem" \
        || ! -s "$target/ssl/default/privkey.pem" ]]; then
    local hostname_fqdn
    hostname_fqdn=$(hostname -f 2>/dev/null || hostname)
    install -d -m 700 "$target/ssl/default"
    openssl req -x509 -nodes -newkey rsa:2048 -days 397 \
        -subj "/CN=${hostname_fqdn}" \
        -addext "subjectAltName=DNS:${hostname_fqdn}" \
        -keyout "$target/ssl/default/privkey.pem" \
        -out "$target/ssl/default/fullchain.pem" >/dev/null 2>&1
    chmod 600 "$target/ssl/default/privkey.pem"
    chmod 644 "$target/ssl/default/fullchain.pem"
  fi

  # Central log and cache directories.  All service logs live under
  # /var/www/logs so they can be collected as one tree.
  install -d -m 750 -o www-data -g www-data "$log_dir"
  [[ -e "$log_dir/error.log" ]] || : > "$log_dir/error.log"
  chown www-data:www-data "$log_dir/error.log" 2>/dev/null || true
  chmod 640 "$log_dir/error.log"

  local cache_dir
  for cache_dir in "${ANGIE_CACHE_DIRS[@]}"; do
    mkdir -p "$cache_dir"
    chown www-data:www-data "$cache_dir" 2>/dev/null || true
    chmod 750 "$cache_dir"
  done

  # Validate before anything reloads.  A stopped service is valid (the tree is
  # applied at the next start); reload only when the unit is active.
  if ! /usr/sbin/angie -t; then
    warn "Angie configuration test failed; live service left untouched"
    return 1
  fi
  # The install and --optimize paths tune the synced tree before they reload
  # or restart it themselves (ANGIE_SYNC_RELOAD=0); reloading here as well
  # briefly ran the repository defaults (65535 connections, 16g cache zones)
  # on every --optimize and doubled the reloads.
  if (( ANGIE_SYNC_RELOAD )) && systemctl is-active --quiet angie 2>/dev/null; then
    systemctl daemon-reload || true
    if systemctl reload angie.service 2>/dev/null; then
      info "Angie configuration reloaded"
    else
      warn "Angie configuration is valid but the reload failed"
    fi
  fi
  # Angie's master opens log files as root.  Normalise pre-existing logs for
  # the UMask=0027 drop-in; new files are already 0640.
  find "$log_dir" -type f -name '*.log' -exec chmod 640 {} + 2>/dev/null || true
  return 0
}

sync_angie_repo_configs() {
  fetch_server_configs || return 1
  local limit_src="${CONFIG_SOURCE_DIR}/scripts/limit_nofile.conf"
  local default_src="${CONFIG_SOURCE_DIR}/scripts/etc_default_nginx"
  [[ -f $limit_src && -f $default_src ]] || {
    warn "Downloaded server configs lack the systemd/default Angie files"
    return 1
  }
  mkdir -p /etc/systemd/system/angie.service.d
  install -m 644 "$limit_src" /etc/systemd/system/angie.service.d/limits.conf \
    || return 1
  install -m 644 "$default_src" /etc/default/angie || return 1

  # Load the new drop-in before the tree deployer reloads the unit; otherwise
  # systemctl prints "unit file changed on disk" and may use stale limits.
  systemctl daemon-reload || true

  deploy_angie_tree || return 1
  return 0
}

# The hardware-aware Angie profile applied to a freshly synced /etc/angie:
# guest caches, asset precompression, the tuner and dynamic compression, in
# the one order both the installer and --optimize use (the repository
# templates are restored first so the tuner's cache values win).  Returns 1
# when the tuner fails; the compression outcome is left in
# ANGIE_COMPRESSION_SUMMARY for the caller's report.
ANGIE_COMPRESSION_SUMMARY=""
angie_apply_profile() {
  local target=${1:-/etc/angie}
  optimize_wordpress_cache "$target" || warn "WordPress cache setup was skipped"
  ensure_xf_guest_cache "$target" || warn "XenForo cache setup was skipped"
  configure_asset_precompression "$target" || warn "Asset precompression was skipped"
  tune_angie_configs "$target" || return 1
  # Dynamic Brotli compression.  The module is optional, so a failure here
  # must not stop the run; gzip remains active.
  ensure_angie_compression "$target" || warn "Angie compression setup was skipped"
  (( ANGIE_COMPRESSION_CHANGED )) && TUNE_DIRTY=1
  if (( ANGIE_COMPRESSION_SKIPPED )); then
    ANGIE_COMPRESSION_SUMMARY="Compression: unchanged (SETUP_ANGIE_COMPRESSION=0)"
  elif (( ANGIE_BROTLI_OK )); then
    ANGIE_COMPRESSION_SUMMARY="Compression: Brotli level ${ANGIE_BROTLI_LEVEL} (gzip fallback)"
  else
    ANGIE_COMPRESSION_SUMMARY="Compression: gzip only (Brotli module unavailable)"
  fi
  return 0
}

# md5 of one file, "absent" when it does not exist: the before/after probe
# every tuner uses to decide whether a service needs a restart.
file_md5() {
  [[ -f $1 ]] || { printf 'absent'; return 0; }
  md5sum "$1" | awk '{print $1}'
}

# One digest for a configuration tree, so --optimize can tell whether the
# sync + profile actually changed anything before reloading a service.
config_tree_digest() {
  local dir=$1
  [[ -d $dir ]] || { printf 'absent'; return 0; }
  (cd "$dir" && find . -type f -print0 2>/dev/null | sort -z | xargs -0 md5sum 2>/dev/null) | md5sum | awk '{print $1}'
}

deploy_angie_configs() {
  step "Angie configuration (server-configs-nginx)"
  # install_angie validates and restarts the service after this function;
  # the sync itself must not reload the untuned tree first.
  ANGIE_SYNC_RELOAD=0
  if ! sync_angie_repo_configs; then
    ANGIE_SYNC_RELOAD=1
    warn "Angie config deployment failed"
    return 1
  fi
  ANGIE_SYNC_RELOAD=1

  # Hardware-aware Angie tuning is owned by setup.sh so the same code runs
  # during install and during `--optimize`.
  tune_reset_changes
  if ! angie_apply_profile /etc/angie; then
    warn "Angie tuning failed"
    return 1
  fi
  info "$ANGIE_COMPRESSION_SUMMARY"
  local change
  for change in "${TUNE_CHANGES[@]}"; do info "tune: ${change}"; done
  for change in "${TUNE_MISSES[@]}"; do warn "tune not applied: ${change}"; done
}

# Ensure an embedded key file is present and byte-identical to the payload.
# A truncated file from an interrupted write, or an outdated key, otherwise
# makes every later apt operation fail until an operator removes it manually.
refresh_blob_key() {
  local target=$1 blob=$2 tmp
  tmp=$(tmp_file) || return 1
  "$blob" > "$tmp" 2>/dev/null || { warn "Could not decode ${blob}"; return 1; }
  [[ -s $tmp ]] || { warn "Embedded ${blob} decoded to an empty file"; return 1; }
  if [[ -s $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  install -m 644 "$tmp" "$target" || return 1
  info "Refreshed embedded key: ${target}"
}

refresh_blob_key_dearmor() {
  local target=$1 blob=$2 tmp
  tmp=$(tmp_file) || return 1
  "$blob" 2>/dev/null | gpg --dearmor --yes -o "$tmp" 2>/dev/null \
    || { warn "Could not decode/dearmor ${blob}"; return 1; }
  [[ -s $tmp ]] || { warn "Embedded ${blob} decoded to an empty key"; return 1; }
  if [[ -s $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  install -m 644 "$tmp" "$target" || return 1
  info "Refreshed embedded key: ${target}"
}

ensure_sury_keyring() {
  local keyring=/usr/share/keyrings/debsuryorg-archive-keyring.gpg
  local deb extract embedded
  deb=$(tmp_file --suffix=.deb) || return 1
  blob_sury_deb > "$deb" 2>/dev/null || { warn "Could not decode Sury keyring payload"; return 1; }
  extract=$(tmp_dir) || return 1
  dpkg-deb -x "$deb" "$extract" 2>/dev/null || true
  embedded=$(find "$extract" -type f -name '*.gpg' 2>/dev/null | head -n1)
  if [[ -s $keyring && -n $embedded ]] && cmp -s "$keyring" "$embedded"; then
    return 0
  fi
  dpkg -i "$deb" || { warn "Could not install the Sury keyring package"; return 1; }
  info "Refreshed embedded key: ${keyring}"
}

