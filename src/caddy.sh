#!/bin/bash

# 证书 API 地址
is_cert_api="https://m.site-manager.top/vpn/site/domain/cert/pull"

# 证书续约提前天数
is_cert_renew_days=15

# 飞书告警 Webhook URL
is_feishu_webhook="https://open.feishu.cn/open-apis/bot/v2/hook/1fdf5127-7044-40d5-8e7b-93848fe7f8ca"

# 发送飞书告警通知
send_feishu_alert() {
    local message=$1
    local json_data='{
        "msg_type": "text",
        "content": {
            "text": "'"${message}"'"
        }
    }'
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "$is_feishu_webhook" >/dev/null 2>&1
}

# 提取1级域名（如 owen.launchix.top -> launchix.top）
get_root_domain() {
    echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
}

# 从 API 拉取证书
pull_caddy_cert() {
    local root_domain=$(get_root_domain ${host})
    local cert_dir=/etc/caddy/certs/${root_domain}
    local cert_file=${cert_dir}/cert.pem
    local key_file=${cert_dir}/key.pem

    mkdir -p ${cert_dir}

    # 检查证书是否需要续约
    if check_caddy_cert_expiry ${cert_file}; then
        # 调用 API 获取证书（使用根域名请求通配符证书）
        local response=$(curl -s --max-time 30 "${is_cert_api}?domain=${root_domain}")

        # 检查请求是否成功
        if [[ -z "$response" ]]; then
            send_feishu_alert "【Caddy证书续约失败】\n域名: ${root_domain}\n原因: API 请求超时或无响应\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi

        # 检查 API 返回是否成功
        local code=$(echo "$response" | jq -r '.code // .status // "null"')
        if [[ "$code" != "0" && "$code" != "200" && "$code" != "null" ]]; then
            local msg=$(echo "$response" | jq -r '.message // .msg // "未知错误"')
            send_feishu_alert "【Caddy证书续约失败】\n域名: ${root_domain}\n原因: ${msg}\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi

        # 解析证书内容
        local cert_content=$(echo "$response" | jq -r '.data.certContent')
        local key_content=$(echo "$response" | jq -r '.data.keyContent')

        # 检查证书内容是否有效
        if [[ -z "$cert_content" || "$cert_content" == "null" || -z "$key_content" || "$key_content" == "null" ]]; then
            send_feishu_alert "【Caddy证书续约失败】\n域名: ${root_domain}\n原因: 证书内容为空\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi

        # 保存证书
        echo "$cert_content" > ${cert_file}
        echo "$key_content" > ${key_file}

        # 设置权限
        chmod 644 ${cert_file}
        chmod 600 ${key_file}

        return 0  # 已续约
    fi
    return 1  # 无需续约
}

# 检查证书是否需要续约
check_caddy_cert_expiry() {
    local cert_file=$1

    # 证书不存在，需要拉取
    [[ ! -f ${cert_file} ]] && return 0

    # 获取证书过期时间
    local expiry_date=$(openssl x509 -enddate -noout -in ${cert_file} 2>/dev/null | cut -d= -f2)
    [[ -z ${expiry_date} ]] && return 0

    # 转换为时间戳
    local expiry_ts=$(date -d "${expiry_date}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${expiry_date}" +%s 2>/dev/null)
    local now_ts=$(date +%s)
    local renew_ts=$((now_ts + is_cert_renew_days * 86400))

    # 证书即将过期或已过期，需要续约
    [[ ${expiry_ts} -le ${renew_ts} ]] && return 0

    return 1
}

# 续约所有 Caddy 证书
renew_all_caddy_certs() {
    local certs_dir=/etc/caddy/certs
    local conf_dir=/etc/sing-box/conf
    local renewed=0

    [[ ! -d ${certs_dir} ]] && return

    # 获取所有有效的根域名（从 VLESS-WS-TLS-* 配置文件中提取）
    local valid_domains=""
    if [[ -d ${conf_dir} ]]; then
        for conf_file in ${conf_dir}/VLESS-WS-TLS-*.json; do
            [[ ! -f ${conf_file} ]] && continue
            # 从文件名提取域名：VLESS-WS-TLS-owen.launchix.top.json -> owen.launchix.top
            local domain=$(basename ${conf_file} | sed 's/^VLESS-WS-TLS-//;s/\.json$//')
            local root_domain=$(get_root_domain ${domain})
            valid_domains="${valid_domains} ${root_domain}"
        done
    fi

    # 遍历证书目录
    for cert_dir in ${certs_dir}/*/; do
        [[ ! -d ${cert_dir} ]] && continue
        local cert_domain=$(basename ${cert_dir})

        # 检查该证书的根域名是否还在使用
        if [[ -n "$valid_domains" && ! "$valid_domains" =~ " ${cert_domain}" && ! "$valid_domains" =~ "^${cert_domain}" ]]; then
            echo "删除无效证书: ${cert_domain}"
            rm -rf ${cert_dir}
            continue
        fi

        # 续约证书
        host=${cert_domain}
        if pull_caddy_cert; then
            echo "证书已续约: ${host}"
            renewed=1
        fi
    done

    # 如果有证书被续约，重载 Caddy
    [[ ${renewed} -eq 1 ]] && systemctl reload caddy
}

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
        local cron_job="0 3 * * * root source /etc/sing-box/src/caddy.sh && renew_all_caddy_certs >/dev/null 2>&1"
        if ! grep -q "renew_all_caddy_certs" /etc/crontab 2>/dev/null; then
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
        pull_caddy_cert
        cat >${is_caddy_site_file} <<<"
${host} {
    tls ${is_custom_cert} ${is_custom_key}
    reverse_proxy ${path} 127.0.0.1:${port}
    import ${is_caddy_site_file}.add
}"
        ;;
    *h2*)
        # 拉取证书（如果需要）
        pull_caddy_cert
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
        pull_caddy_cert
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
