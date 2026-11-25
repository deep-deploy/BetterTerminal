# BetterTerminal interactive login banner.
case $- in
    *i*)
        if [ -t 1 ] && [ "${_BT_BANNER_SHOWN:-0}" != 1 ]; then
            _BT_BANNER_SHOWN=1
            _bt_type() {
                _bt_text=$1
                while [ -n "$_bt_text" ]; do
                    _bt_rest=${_bt_text#?}
                    printf '%s' "${_bt_text%"$_bt_rest"}"
                    _bt_text=$_bt_rest
                    if [ "${BETTERTERMINAL_NO_ANIMATION:-0}" != 1 ]; then
                        sleep 0.018
                    fi
                done
                printf '\n'
            }
            printf '\n\033[92m================================\033[0m\n\n'
            printf '\033[1;92m'
            _bt_type '         BETTERTERMINAL'
            printf '\033[0;92m'
            _bt_type '     Powered by Betteronics'
            printf '\033[92m\n================================\033[0m\n\n'
            printf '%s\n' 'Local ARM64 Linux Environment' 'Running directly on your iPhone.'
            printf '\n\033[92m%s\n\n================================\033[0m\n\n' 'No Cloud | No VPS | No SSH'
            unset -f _bt_type
            unset _bt_text _bt_rest
        fi
        ;;
esac
