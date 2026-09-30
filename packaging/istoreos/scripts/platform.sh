#!/bin/sh
# Pure helpers, also exercised on the development host.
valid_release_repo() {
    case "$1" in agentx1boss/opencode|anomalyco/opencode) return 0 ;; *) return 1 ;; esac
}
detect_target() {
    case "$1" in
        x86_64) echo x64-baseline-musl ;;
        aarch64) echo arm64-musl ;;
        *) return 1 ;;
    esac
}
valid_ipv4() {
    [ "$1" != 0.0.0.0 ] || return 1
    case "$1" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$1" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i>255) exit 1}'
}
valid_data_path() {
    case "$1" in /mnt/*|/opt/*) ;; *) return 1 ;; esac
    case "$1" in *..*|*//*|*/|*[!a-zA-Z0-9_./-]*) return 1 ;; esac
}
valid_version() {
    [ -n "$1" ] || return 1
    case "$1" in *[!0-9.]*|.*|*.) return 1 ;; esac
}
