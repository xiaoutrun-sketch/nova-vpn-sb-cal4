#!/bin/bash

# 加载证书管理模块
[[ -f /etc/sing-box/sh/src/cert.sh ]] && source /etc/sing-box/sh/src/cert.sh

caddy_config() {
    is_caddy_site_file=$is_caddy_conf/${host}.conf
    is_root_domain=$(get_root_domain ${host})
    is_custom_cert=/etc/caddy/certs/${is_root_domain}/cert.pem
    is_custom_key=/etc/caddy/certs/${is_root_domain}/key.pem
    case $1 in
    new)
        mkdir -p /etc/caddy /etc/caddy/sites /etc/caddy/certs $is_caddy_conf $is_caddy_conf/layer4
        caddy_rebuild_caddyfile
        # 添加证书续约定时任务（每天凌晨3点执行）
        local cron_job="0 3 * * * root source /etc/sing-box/sh/src/cert.sh && renew_all_certs >/dev/null 2>&1"
        if ! grep -q "renew_all_certs" /etc/crontab 2>/dev/null; then
            echo "$cron_job" >> /etc/crontab
        fi
        ;;
    l4_add_naive | l4_add_reality)
        local l4_domain=$2
        local l4_port=$3
        [[ ! $l4_domain || ! $l4_port ]] && return
        # 从命令中提取协议类型：l4_add_naive -> naive, l4_add_reality -> reality
        local l4_protocol=${1#l4_add_}
        create_l4_config $l4_protocol $l4_domain "127.0.0.1:$l4_port"
        ;;
    l4_del_naive | l4_del_reality)
        local l4_domain=$2
        [[ ! $l4_domain ]] && return
        # 从命令中提取协议类型
        local l4_protocol=${1#l4_del_}
        remove_l4_config $l4_protocol $l4_domain
        ;;
    *ws* | *http*)
        # 拉取证书（如果需要）
        pull_cert
        cat >${is_caddy_site_file} <<<"
${host} {
    tls ${is_custom_cert} ${is_custom_key}
    reverse_proxy ${path} 127.0.0.1:${port}
    import ${is_caddy_site_file}.add
}"
        ;;
    *h2*)
        # 拉取证书（如果需要）
        pull_cert
        cat >${is_caddy_site_file} <<<"
${host} {
    tls ${is_custom_cert} ${is_custom_key}
    reverse_proxy ${path} h2c://127.0.0.1:${port} {
        transport http {
			tls_insecure_skip_verify
		}
    }
    import ${is_caddy_site_file}.add
}"
        ;;
    *grpc*)
        # 拉取证书（如果需要）
        pull_cert
        cat >${is_caddy_site_file} <<<"
${host} {
    tls ${is_custom_cert} ${is_custom_key}
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
    # 使用 listener_wrappers 结构，始终启用 layer4
    cat >/etc/caddy/Caddyfile <<EOF
{
    admin off
    http_port $is_http_port
    https_port $is_https_port
    # 在服务器的监听器包装器链中，将layer4放在tls之前
    servers {
        listener_wrappers {
            # 1. layer4作为第一个包装器，优先处理所有进入443端口的连接
            layer4 {
                import $is_caddy_conf/layer4/*.conf
            }
            # 2. tls包装器处理回落下来的HTTPS连接
            tls
        }
    }
}

import $is_caddy_conf/*.conf
import /etc/caddy/sites/*.conf
EOF
}

# 生成单个 L4 路由配置文件
create_l4_config() {
    local l4_protocol_upper=${1^^}  # 转为大写（用于文件名）
    local l4_protocol_lower=${1,,}  # 转为小写（用于匹配器名）
    local l4_domain=$2
    local l4_upstream=$3
    local l4_conf_dir=$is_caddy_conf/layer4
    local l4_conf_file=$l4_conf_dir/${l4_protocol_upper}-${l4_domain}.conf
    
    mkdir -p $l4_conf_dir
    
    # 生成 layer4 匹配和路由规则
    local match_name="${l4_protocol_lower}-match"
    cat >$l4_conf_file <<EOF
@${match_name} {
    tls sni ${l4_domain}
}
# 匹配到的连接，由layer4直接代理给本地的${l4_protocol_upper}后端
route @${match_name} {
    proxy ${l4_upstream}
}
EOF
}

# 删除单个 L4 路由配置文件
remove_l4_config() {
    local l4_protocol=${1^^}  # 转为大写
    local l4_domain=$2
    local l4_conf_file=$is_caddy_conf/layer4/${l4_protocol}-${l4_domain}.conf
    rm -f $l4_conf_file
}
