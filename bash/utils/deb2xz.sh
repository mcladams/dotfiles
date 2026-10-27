deb2xz() {
    # TODO: move to .dotfiles/scripts or similar as part of homedir normalization project
    # debian 11 bullseye and earlier can only install xz compressed deb packaing, not zstd
    # this converts zstd comrpessed deb to xz, not really required in .bash_aliases anymore
    set -e
    pkges="$@"
    for pkg in $pkges; do
        if [ ! "${pkg##*.}" = "deb" ] || [ ! -f $pkg ]; then
            echo '"'$pkg'"' is not a file or does not end in .deb
            continue
        elif grep -q "control.tar.xz" <<< $files; then
            echo '"'$pkg'"' is already in tar.xz format, not touching it.
            continue
        fi
        pathname=$(readlink -f $pkg)
        path=${pathname%/*}
        filename=${pathname##*/}
        pkgname=${filename%.*}
        # do it in a tmp dir
        mkdir /tmp/$pkgname
        pushd /tmp/$pkgname
        ar -x $pathname
        zstd -d < control.tar.zst | xz > control.tar.xz
        zstd -d < data.tar.zst | xz > data.tar.xz
        mv $pathname /tmp/$filename
        ar -m -c -a sdsd $pathname debian-binary control.tar.xz data.tar.xz
        popd
    done
    echo "Done. Original debs move to /tmp"
}
