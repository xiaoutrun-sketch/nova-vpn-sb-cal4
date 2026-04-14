#!/bin/bash

# Caddy L4 config dir for SNI route fragments
is_caddy_l4_dir=/etc/caddy/l4-routes

caddy_config() {
    is_caddy_site_file=$is_caddy_conf/${host}.conf
    case $1 in
    new)
        mkdir -p /etc/caddy /etc/caddy/sites $is_caddy_conf $is_caddy_l4_dir
        caddy_rebuild_caddyfile
        ;;
    l4_add)
        local l4_domain=$2
        local l4_port=$3
        [[ ! $l4_domain || ! $l4_port ]] && return
        cat >$is_caddy_l4_dir/${l4_domain}.conf <<<"$l4_domain 127.0.0.1:$l4_port"
        caddy_rebuild_caddyfile
        ;;
    l4_del)
        local l4_domain=$2
        [[ ! $l4_domain ]] && return
        rm -f $is_caddy_l4_dir/${l4_domain}.conf
        caddy_rebuild_caddyfile
        ;;
    *ws* | *http*)
        cat >${is_caddy_site_file} <<<"
${host} {
    reverse_proxy ${path} 127.0.0.1:${port}
    import ${is_caddy_site_file}.add
}"
        ;;
    *h2*)
        cat >${is_caddy_site_file} <<<"
${host} {
    reverse_proxy ${path} h2c://127.0.0.1:${port} {
        transport http {
			tls_insecure_skip_verify
		}
    }
    import ${is_caddy_site_file}.add
}"
        ;;
    *grpc*)
        cat >${is_caddy_site_file} <<<"
${host} {
    reverse_proxy /${path}/* h2c://127.0.0.1:${port}
    import ${is_caddy_site_file}.add
}"
        ;;
    proxy)
        cat >${is_caddy_site_file}.add <<<"
reverse_proxy https://$proxy_site {
        header_up Host {upstream_hostport}
}"
        ;;
    esac
    [[ $1 != "new" && $1 != 'proxy' && $1 != l4_* ]] && {
        [[ ! -f ${is_caddy_site_file}.add ]] && echo "# custom caddy config" >${is_caddy_site_file}.add
    }
}

caddy_rebuild_caddyfile() {
    local l4_routes=""
    if [[ -d $is_caddy_l4_dir ]] && ls $is_caddy_l4_dir/*.conf &>/dev/null; then
        while IFS=' ' read -r domain upstream; do
            [[ ! $domain || ! $upstream ]] && continue
            l4_routes+="
            @${domain//\./_} tls sni $domain
            route @${domain//\./_} {
                proxy $upstream
            }"
        done < <(cat $is_caddy_l4_dir/*.conf 2>/dev/null)
    fi

    local has_l4=
    [[ $l4_routes ]] && has_l4=1

    if [[ $has_l4 ]]; then
        cat >/etc/caddy/Caddyfile <<EOF
{
    admin off
    http_port $is_http_port
    layer4 {
        0.0.0.0:$is_https_port {
${l4_routes}
            route {
                tls
                proxy localhost:$is_caddy_internal_https_port
            }
        }
    }
}
:${is_caddy_internal_https_port} {
    tls internal
}
import $is_caddy_conf/*.conf
import /etc/caddy/sites/*.conf
EOF
    else
        cat >/etc/caddy/Caddyfile <<-EOF
{
  admin off
  http_port $is_http_port
  https_port $is_https_port
}
import $is_caddy_conf/*.conf
import /etc/caddy/sites/*.conf
EOF
    fi
}
