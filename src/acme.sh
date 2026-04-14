#!/bin/bash

is_acme_bin=/root/.acme.sh/acme.sh
is_tls_dir=/etc/sing-box/tls

install_acme() {
    [[ -f $is_acme_bin ]] && return
    _green "\n安装 acme.sh ..\n"
    curl -fsSL https://get.acme.sh | sh -s email=singbox@$(hostname) 2>/dev/null
    [[ ! -f $is_acme_bin ]] && {
        _wget -qO- https://get.acme.sh | sh -s email=singbox@$(hostname) 2>/dev/null
    }
    [[ ! -f $is_acme_bin ]] && err "安装 acme.sh 失败."
    $is_acme_bin --set-default-ca --server letsencrypt 2>/dev/null
    _green "安装 acme.sh 成功.\n"
}

issue_cert() {
    local domain=$1
    [[ ! $domain ]] && err "issue_cert: 缺少域名参数."
    local cert_dir=$is_tls_dir/$domain
    mkdir -p $cert_dir

    if [[ -f $cert_dir/fullchain.pem && -f $cert_dir/privkey.pem ]]; then
        return
    fi

    install_acme

    _green "\n为 $domain 申请 TLS 证书..\n"
    $is_acme_bin --issue -d $domain --standalone --keylength ec-256 2>/dev/null
    [[ $? != 0 ]] && {
        $is_acme_bin --issue -d $domain --standalone --httpport $is_http_port --keylength ec-256 2>/dev/null
        [[ $? != 0 ]] && err "为 $domain 申请证书失败. 请确保域名已解析且 80 端口可用."
    }

    local reload_cmd="systemctl restart sing-box 2>/dev/null"
    [[ $is_openrc ]] && reload_cmd="rc-service sing-box restart 2>/dev/null"
    $is_acme_bin --install-cert -d $domain --ecc \
        --fullchain-file $cert_dir/fullchain.pem \
        --key-file $cert_dir/privkey.pem \
        --reloadcmd "$reload_cmd" 2>/dev/null

    [[ ! -f $cert_dir/fullchain.pem || ! -f $cert_dir/privkey.pem ]] && {
        err "为 $domain 安装证书失败."
    }
    _green "证书申请成功: $domain\n"
}

remove_cert() {
    local domain=$1
    [[ ! $domain ]] && return
    [[ -f $is_acme_bin ]] && {
        $is_acme_bin --remove -d $domain --ecc 2>/dev/null
    }
    rm -rf $is_tls_dir/$domain
}

uninstall_acme() {
    [[ -f $is_acme_bin ]] && {
        $is_acme_bin --uninstall 2>/dev/null
        rm -rf /root/.acme.sh
    }
    rm -rf $is_tls_dir
}
