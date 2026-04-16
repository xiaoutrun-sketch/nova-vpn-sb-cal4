get_latest_version() {
    case $1 in
    core)
        name=sing-box
        url="https://api.github.com/repos/SagerNet/sing-box/releases/latest?v=$RANDOM"
        ;;
    sh)
        name="sing-box 脚本"
        url="https://api.github.com/repos/nova-vpn-sb-ca/nova-sbv/releases/latest?v=$RANDOM"
        ;;
    caddy)
        name="Caddy"
        url="https://api.github.com/repos/$is_caddy_repo/releases/latest?v=$RANDOM"
        ;;
    esac
    latest_ver=$(_wget -qO- $url | grep tag_name | grep -E -o 'v([0-9.]+)')
    [[ ! $latest_ver ]] && {
        err "获取 ${name} 最新版本失败."
    }
    unset name url
}
download() {
    latest_ver=$2
    # tmp dir
    tmpdir=$(mktemp -u)
    [[ ! $tmpdir ]] && {
        tmpdir=/tmp/tmp-$RANDOM
    }
    mkdir -p $tmpdir
    case $1 in
    core)
        [[ ! $latest_ver ]] && get_latest_version $1
        name=sing-box
        tmpfile=$tmpdir/sing-box.tar.gz
        link="https://github.com/SagerNet/sing-box/releases/download/${latest_ver}/${is_core}-${latest_ver:1}-linux-${is_arch}.tar.gz"
        download_file
        tar zxf $tmpfile --strip-components 1 -C /etc/sing-box/bin
        chmod +x /etc/sing-box/bin/sing-box
        ;;
    sh)
        [[ ! $latest_ver ]] && get_latest_version $1
        name="sing-box 脚本"
        tmpfile=$tmpdir/sh.tar.gz
        link="https://github.com/xiaoutrun-sketch/nova-vpn-sb-cal4/releases/download/${latest_ver}/code.tar.gz"
        download_file
        tar zxf $tmpfile -C /etc/sing-box/sh
        chmod +x /usr/local/bin/sing-box ${is_sh_bin/sing-box/sb}
        ;;
    caddy)
        # Caddy 使用官方 API 下载，不需要获取版本号
        download_caddy_l4
        ;;
    esac
    rm -rf $tmpdir
    unset latest_ver
}
download_file() {
    if ! _wget -t 5 -c $link -O $tmpfile; then
        rm -rf $tmpdir
        err "\n下载 ${name} 失败.\n"
    fi
}

caddy_has_l4() {
    [[ -f $1 && -x $1 ]] && $1 list-modules 2>/dev/null | grep -q "layer4"
}

download_caddy_l4() {
    name="Caddy (with layer4 plugin)"
    tmpfile=$tmpdir/caddy

    _yellow "\n下载 $name ..\n"

    # method 1: Caddy official download API
    local caddy_api="https://caddyserver.com/api/download?os=linux&arch=${is_arch}&p=github.com/mholt/caddy-l4"
    _yellow "尝试方式1: Caddy 官方 API 构建.."
    _yellow "下载地址: $caddy_api"
    if _wget -t 3 -T 30 "$caddy_api" -O $tmpfile; then
        chmod +x $tmpfile 2>/dev/null
        if caddy_has_l4 $tmpfile; then
            cp -f $tmpfile /usr/local/bin/caddy
            _green "Caddy (含 L4 插件) 下载成功.\n"
            return
        else
            _yellow "下载的文件不包含 L4 插件或无法执行"
        fi
    else
        _yellow "方式1 下载失败 (可能是网络问题或被墙)"
    fi

    # method 2: xcaddy build
    _yellow "方式1 失败, 尝试方式2: xcaddy 本地构建.."
    xcaddy_build_caddy_l4
    if caddy_has_l4 $tmpfile; then
        cp -f $tmpfile /usr/local/bin/caddy
        _green "Caddy (含 L4 插件) 构建成功.\n"
        return
    fi

    err "无法获取包含 layer4 插件的 Caddy. 请手动构建: https://github.com/mholt/caddy-l4"
}

xcaddy_build_caddy_l4() {
    local need_cleanup_go=

    if [[ ! $(type -P go) ]]; then
        _yellow "安装 Go 编译环境 (临时).."
        local go_ver=$(_wget -qO- "https://go.dev/VERSION?m=text" | head -1)
        [[ ! $go_ver ]] && go_ver="go1.22.2"
        local go_arch=$is_arch
        _wget -t 3 -q "https://go.dev/dl/${go_ver}.linux-${go_arch}.tar.gz" -O $tmpdir/go.tar.gz
        [[ $? != 0 ]] && return 1
        tar -C $tmpdir -xzf $tmpdir/go.tar.gz
        export PATH=$tmpdir/go/bin:$PATH
        export GOPATH=$tmpdir/gopath
        mkdir -p $GOPATH
        need_cleanup_go=1
    fi

    if [[ ! $(type -P xcaddy) ]]; then
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest 2>/dev/null
        export PATH=$(go env GOPATH)/bin:$PATH
    fi

    if [[ $(type -P xcaddy) ]]; then
        _yellow "正在使用 xcaddy 构建 Caddy + L4 插件 (可能需要几分钟).."
        xcaddy build --with github.com/mholt/caddy-l4 --output $tmpfile 2>/dev/null
    fi

    [[ $need_cleanup_go ]] && {
        rm -rf $tmpdir/go $tmpdir/gopath $tmpdir/go.tar.gz
        unset GOPATH
    }
}
