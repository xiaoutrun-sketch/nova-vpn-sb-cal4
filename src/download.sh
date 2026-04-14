get_latest_version() {
    case $1 in
    core)
        name=sing-box
        url="https://api.github.com/repos/SagerNet/sing-box/releases/latest?v=$RANDOM"
        ;;
    sh)
        name="sing-box 脚本"
        url="https://api.github.com/repos/xiaoutrun-sketch/nova-sbv/releases/latest?v=$RANDOM"
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
    [[ ! $latest_ver ]] && get_latest_version $1
    # tmp dir
    tmpdir=$(mktemp -u)
    [[ ! $tmpdir ]] && {
        tmpdir=/tmp/tmp-$RANDOM
    }
    mkdir -p $tmpdir
    case $1 in
    core)
        name=sing-box
        tmpfile=$tmpdir/sing-box.tar.gz
        link="https://github.com/SagerNet/sing-box/releases/download/${latest_ver}/${is_core}-${latest_ver:1}-linux-${is_arch}.tar.gz"
        download_file
        tar zxf $tmpfile --strip-components 1 -C /etc/sing-box/bin
        chmod +x /etc/sing-box/bin/sing-box
        ;;
    sh)
        name="sing-box 脚本"
        tmpfile=$tmpdir/sh.tar.gz
        link="https://github.com/xiaoutrun-sketch/nova-sbv/releases/download/${latest_ver}/code.tar.gz"
        download_file
        tar zxf $tmpfile -C /etc/sing-box/sh
        chmod +x /usr/local/bin/sing-box ${is_sh_bin/sing-box/sb}
        ;;
    caddy)
        name="Caddy (with layer4 plugin)"
        tmpfile=$tmpdir/caddy
        link="https://caddyserver.com/api/download?os=linux&arch=${is_arch}&p=github.com/mholt/caddy-l4"
        download_file
        cp -f $tmpfile /usr/local/bin/caddy
        chmod +x /usr/local/bin/caddy
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
