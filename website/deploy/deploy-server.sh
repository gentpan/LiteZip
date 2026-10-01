#!/usr/bin/env bash
set -euo pipefail
site_root="$(cd "$(dirname "$0")/.." && pwd)"
deploy_key="${LITEZIP_DEPLOY_KEY:-$HOME/Desktop/gentpan.pem}"
deploy_host="${LITEZIP_DEPLOY_HOST:-root@51.38.126.148}"
deploy_port="${LITEZIP_DEPLOY_PORT:-22}"
release_id="$(date -u +%Y%m%dT%H%M%SZ)-$(shasum -a 256 "$site_root/dist/index.html" | cut -c1-8)"
test -f "$deploy_key"
python3 "$site_root/scripts/build-pages.py"
node --check "$site_root/dist/site.js"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$temp_dir/site.tar.gz" -C "$site_root/dist" .
ssh_options=(-i "$deploy_key" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
scp "${ssh_options[@]}" -P "$deploy_port" "$temp_dir/site.tar.gz" "$deploy_host:/tmp/litezip-$release_id.tar.gz"
scp "${ssh_options[@]}" -P "$deploy_port" "$site_root/deploy/litezip.app.caddy" "$deploy_host:/tmp/litezip-$release_id.caddy"
ssh "${ssh_options[@]}" -p "$deploy_port" "$deploy_host" bash -s -- "$release_id" <<'REMOTE'
set -euo pipefail
release_id="$1"
site_dir=/var/www/litezip.app
release_dir="$site_dir/releases/$release_id"
config=/etc/caddy/sites/litezip.app.caddy
backup="$site_dir/backups/$release_id.caddy"
old_current="$(readlink "$site_dir/current" || true)"
config_existed=false
install -d -m 755 "$release_dir" "$site_dir/backups"
if test -e "$config"; then
    config_existed=true
    cp -a "$config" "$backup"
fi
rollback() {
    trap - ERR
    if "$config_existed"; then cp -a "$backup" "$config"; else rm -f "$config"; fi
    if test -n "$old_current"; then
        ln -s "$old_current" "$site_dir/current.rollback"
        mv -Tf "$site_dir/current.rollback" "$site_dir/current"
    else
        rm -f "$site_dir/current"
    fi
    systemctl reload caddy || true
    echo 'LiteZip deployment failed; previous configuration restored.' >&2
    exit 1
}
tar -xzf "/tmp/litezip-$release_id.tar.gz" -C "$release_dir"
test -s "$release_dir/index.html"
find "$release_dir" -type d -exec chmod 755 {} +
find "$release_dir" -type f -exec chmod 644 {} +
trap rollback ERR
install -m 644 "/tmp/litezip-$release_id.caddy" "$config"
caddy validate --config /etc/caddy/Caddyfile
ln -s "$release_dir" "$site_dir/current.next"
mv -Tf "$site_dir/current.next" "$site_dir/current"
systemctl reload caddy
trap - ERR
rm -f "/tmp/litezip-$release_id.tar.gz" "/tmp/litezip-$release_id.caddy"
printf 'Deployed LiteZip release: %s\n' "$release_dir"
REMOTE
