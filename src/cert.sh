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
pull_cert() {
    local domain=$1
    [[ ! $domain ]] && domain=$host
    local root_domain=$(get_root_domain ${domain})
    local cert_dir=/etc/caddy/certs/${root_domain}
    local cert_file=${cert_dir}/cert.pem
    local key_file=${cert_dir}/key.pem
    local server_ip=$(curl -s --max-time 5 ip.sb 2>/dev/null || echo "未知")

    mkdir -p ${cert_dir}

    # 检查证书是否需要续约
    if check_cert_expiry ${cert_file}; then
        # 调用 API 获取证书（使用二级域名请求证书）
        local response=$(curl -s --max-time 30 "${is_cert_api}?domain=${domain}")

        # 检查请求是否成功
        if [[ -z "$response" ]]; then
            send_feishu_alert "【证书续约失败】\n域名: ${domain}\nIP: ${server_ip}\n原因: API 请求超时或无响应\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi

        # 检查 API 返回是否成功
        local code=$(echo "$response" | jq -r '.code // .status // "null"')
        if [[ "$code" != "0" && "$code" != "200" && "$code" != "null" ]]; then
            local msg=$(echo "$response" | jq -r '.message // .msg // "未知错误"')
            send_feishu_alert "【证书续约失败】\n域名: ${domain}\nIP: ${server_ip}\n原因: ${msg}\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi

        # 解析证书内容
        local cert_content=$(echo "$response" | jq -r '.data.certContent')
        local key_content=$(echo "$response" | jq -r '.data.keyContent')

        # 检查证书内容是否有效
        if [[ -z "$cert_content" || "$cert_content" == "null" || -z "$key_content" || "$key_content" == "null" ]]; then
            send_feishu_alert "【证书续约失败】\n域名: ${domain}\nIP: ${server_ip}\n原因: 证书内容为空\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
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
check_cert_expiry() {
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

# 续约所有证书
renew_all_certs() {
    local certs_dir=/etc/caddy/certs
    local conf_dir=/etc/sing-box/conf
    local renewed=0

    [[ ! -d ${certs_dir} ]] && return

    # 获取所有有效的根域名（从配置文件中提取）
    local valid_domains=""
    if [[ -d ${conf_dir} ]]; then
        for conf_file in ${conf_dir}/*.json; do
            [[ ! -f ${conf_file} ]] && continue
            # 从文件名提取域名
            local filename=$(basename ${conf_file} .json)
            # 跳过不含域名的配置文件（如端口命名的）
            [[ ! $filename =~ \. ]] && continue
            # 提取域名部分（去掉协议前缀）
            local domain=$(echo "$filename" | sed 's/^[A-Z]*-//')
            [[ ! $domain =~ \. ]] && continue
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
        if pull_cert ${cert_domain}; then
            echo "证书已续约: ${cert_domain}"
            renewed=1
        fi
    done

    # 如果有证书被续约，重载 Caddy
    [[ ${renewed} -eq 1 ]] && systemctl reload caddy
}
