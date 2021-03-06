#!/bin/sh
set -e

# default parameters
SOURCES_DIR="${SOURCES_DIR:-$CHROOT/usr/src/kube-lustre}"
[ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="$(uname -r)"

cleanup_wrong_versions() {
    WRONG_PACKAGES="$(rpm -qa zfs kmod-zfs kmod-spl kmod-zfs kmod-spl-devel kmod-zfs-devel zfs-dkms zfs-dracut zfs-test libzpool2 libzfs2-devel libzfs2 libuutil1 libnvpair1 spl spl-dkms zfs-test | grep -v "$1" | xargs)"
    [ -z "$WRONG_PACKAGES" ] || yum -y remove $WRONG_PACKAGES
}

install_lustre_repo() {
    if [ -z "$1" ]; then
        RELEASE="latest-release"
    else
        RELEASE="lustre-$1"
    fi

    cat > "$CHROOT/etc/yum.repos.d/lustre.repo" <<EOF
[lustre-server]
name=lustre-server
baseurl=https://downloads.hpdd.intel.com/public/lustre/$RELEASE/el7/server
# exclude=*debuginfo*
gpgcheck=0

[lustre-client]
name=lustre-client
baseurl=https://downloads.hpdd.intel.com/public/lustre/$RELEASE/el7/client
# exclude=*debuginfo*
gpgcheck=0

[e2fsprogs-wc]
name=e2fsprogs-wc
baseurl=https://downloads.hpdd.intel.com/public/e2fsprogs/latest/el7
# exclude=*debuginfo*
gpgcheck=0
EOF

}

# if chroot is set, use yum and rpm from chroot
if [ ! -z "$CHROOT" ]; then
    alias rpm="chroot $CHROOT rpm"
    alias yum="chroot $CHROOT yum"
    alias dkms="chroot $CHROOT dkms"
fi

# check for distro
if [ "$(sed 's/.*release\ //' "$CHROOT/etc/redhat-release" | cut -d. -f1)" != "7" ]; then
    >&2 echo "Error: Host system not supported"
    exit 1
fi

rpm -q --quiet epel-release || yum -y install epel-release

# install repositories
if [ "$MODE" == "from-repo" ]; then

    if [ "$REPO" == "zfs" ]; then
        # install repositories at this time
        rpm -q zfs-release || yum -y install --nogpgcheck http://download.zfsonlinux.org/epel/zfs-release.el7.noarch.rpm
        case "$TYPE" in
            kmod) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs-kmod\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo ;;
            kmod-testing) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs-testing-kmod\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo && TYPE=kmod ;;
            dkms) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo ;;
            dkms-testing) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs-testing\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo && TYPE=dkms ;;
        esac
    elif [ "$REPO" == "lustre" ]; then
        install_lustre_repo "$LUSTRE_VERSION"
    fi

fi

# check for mode
if [ "$MODE" != "from-source" ] && [ "$MODE" != "from-repo" ]; then
    >&2 echo "Error: Please specify MODE variable"
    >&2 echo "       MODE=<from-repo|from-source>"
    exit 1
fi

# check for repo
if [ "$MODE" == "from-repo" ] && [ "$REPO" != "lustre" ] && [ "$REPO" != "zfs" ]; then
    >&2 echo "Error: Please specify REPO variable"
    >&2 echo "       REPO=<lustre|zfs>"
    exit 1
fi

# check for type
if [ "$TYPE" != "kmod" ] && [ "$TYPE" != "dkms" ]; then
    >&2 echo "Error: Please specify TYPE variable"
    if [ "$REPO" == "zfs" ]
    then >&2 echo "       TYPE=<dkms|kmod|dkms-testing|kmod-testing>"
    else >&2 echo "       TYPE=<dkms|kmod>"
    fi
    exit 1
fi

# check for module
if ! (find "$CHROOT/lib/modules/$KERNEL_VERSION" -name zfs.ko | grep -q "."); then
    FORCE_REINSTALL=1
fi

# check for source repository
if [ -z "$FORCE_REINSTALL" ]; then
    case "$MODE-$REPO" in
        from-repo-zfs    ) yum list installed zfs | tail -n 1 | grep -q '@\(zfs-kmod\|zfs-testing-kmod\|zfs\|zfs-testing\)$' || FORCE_REINSTALL=1 ;;
        from-repo-lustre ) yum list installed zfs | tail -n 1 | grep -q '@lustre-server$' || FORCE_REINSTALL=1 ;;
        from-source-*    ) yum list installed zfs | tail -n 1 | grep -q '@\(zfs-kmod\|zfs-testing-kmod\|zfs\|zfs-testing\|lustre-server\)$' && FORCE_REINSTALL=1 ;;
    esac
fi

# get installed version
INSTALLED_VERSION="$(rpm -qa zfs | awk -F- '{print $2}')"
VERSION="${VERSION:-$INSTALLED_VERSION}"

# get latest version
if [ -z "$VERSION" ] || [ "$AUTO_UPDATE" == "1" ] || [ "$FORCE_REINSTALL" == "1" ]; then
    case "$MODE-$REPO" in
        from-repo-zfs      ) LATEST_VERSION="$(yum list available zfs --showduplicates | grep '\(zfs-kmod\|zfs-testing-kmod\|zfs\|zfs-testing\)$' | tail -n 1 | awk '{print $2}' | cut -d- -f1)" ;;
        from-repo-lustre   ) LATEST_VERSION="$(yum --disablerepo=* --enablerepo=lustre-server  list available zfs --showduplicates | tail -n 1 | awk '{print $2}' | cut -d- -f1)" ;;
        from-source-*      ) LATEST_VERSION="$(curl https://api.github.com/repos/zfsonlinux/zfs/releases/latest -s | grep tag_name | sed 's/.*"zfs-\(.\+\)",/\1/')" ;;
    esac
    VERSION="$LATEST_VERSION"
fi

# check for needed packages and version
if [ -z "$FORCE_REINSTALL" ]; then
    case "$TYPE" in
        kmod ) [ "$(rpm -qa zfs libzfs2-devel kmod-zfs kmod-spl-devel kmod-zfs-devel | grep -c "$VERSION")" == "5" ] || FORCE_REINSTALL=1 ;;
        dkms ) [ "$(rpm -qa zfs libzfs2-devel zfs-dkms spl-dkms | grep -c "$VERSION")" == "4" ] || FORCE_REINSTALL=1 ;;
    esac
fi

# install kernel-headers
if ! ( [ "$MODE" == "from-repo" ] && [ "$TYPE" == "kmod" ] ) && [ ! -d "$CHROOT/lib/modules/$KERNEL_VERSION/build" ]; then
    if ! yum -y install "kernel-devel-uname-r == $KERNEL_VERSION"; then
        >&2 echo "Error: Can not found kernel-headers for current kernel"
        >&2 echo "       try to ugrade kernel then reboot your system"
        >&2 echo "       or install kernel-headers package manually"
        exit 1
    fi
fi


# install packages
if [ "$MODE" == "from-repo" ]; then

    DISABLE_ZFS_REPOS="$(yum repolist all | grep '^zfs' | awk -F'[ /]' '{printf "--disablerepo=" $1 " "}')"
    DISABLE_LUSTRE_REPOS="$(yum repolist all | grep '^lustre' | awk -F'[ /]' '{printf "--disablerepo=" $1 " "}')"

    if [ "$FORCE_REINSTALL" != "1" ]; then
        echo "Info: Needed packages already installed"
    else
        case "$TYPE" in
            kmod )
                yum remove -y zfs-dkms spl-dkms
                cleanup_wrong_versions "$VERSION"
                [ "$REPO" == zfs ] && yum $DISABLE_LUSTRE_REPOS install -y zfs libzfs2-devel kmod-zfs kmod-spl-devel kmod-zfs-devel
                [ "$REPO" == lustre ] && yum $DISABLE_ZFS_REPOS install -y zfs libzfs2-devel kmod-zfs kmod-spl-devel kmod-zfs-devel
            ;;
            dkms )
                yum remove -y kmod-zfs kmod-spl kmod-zfs kmod-spl-devel kmod-zfs-devel
                cleanup_wrong_versions "$VERSION"
                [ "$REPO" == zfs ] && yum $DISABLE_LUSTRE_REPOS install -y zfs libzfs2-devel zfs-dkms spl-dkms
                [ "$REPO" == lustre ] && yum $DISABLE_ZFS_REPOS install -y zfs libzfs2-devel zfs-dkms spl-dkms
            ;;
        esac
    fi

elif [ "$MODE" == "from-source" ]; then

    if [ "$FORCE_REINSTALL" != "1" ]; then
        echo "Info: Needed packages already installed and have version $VERSION"
    else
        yum -y groupinstall 'Development Tools'
        yum -y install zlib-devel libattr-devel libuuid-devel libblkid-devel libselinux-devel libudev-devel

        mkdir -p "$SOURCES_DIR"
        [ -d "$SOURCES_DIR/spl-$VERSION" ] || curl -L "https://github.com/zfsonlinux/zfs/releases/download/zfs-$VERSION/spl-$VERSION.tar.gz" | tar -C "$SOURCES_DIR" -xzf -
        [ -d "$SOURCES_DIR/zfs-$VERSION" ] || curl -L "https://github.com/zfsonlinux/zfs/releases/download/zfs-$VERSION/zfs-$VERSION.tar.gz" | tar -C "$SOURCES_DIR" -xzf -

        # Build and install spl packages
        pushd "$SOURCES_DIR/spl-$VERSION"
        ./autogen.sh
        ./configure --with-spec=redhat --with-linux="$CHROOT/usr/src/kernels/$KERNEL_VERSION/"
        rm -f *.rpm
        case "$TYPE" in
            kmod )
                make pkg-utils pkg-kmod
                yum remove -y zfs-dkms spl-dkms
                cleanup_wrong_versions "$VERSION"
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/spl-$VERSION/|" -e "s|^$CHROOT||" )
            ;;
            dkms )
                make pkg-utils rpm-dkms
                yum remove -y kmod-zfs kmod-spl kmod-zfs kmod-spl-devel kmod-zfs-devel
                cleanup_wrong_versions "$VERSION"
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/spl-$VERSION/|" -e "s|^$CHROOT||" )
            ;;
        esac
        popd

        # Build and install zfs packages
        pushd "$SOURCES_DIR/zfs-$VERSION"
        ./autogen.sh
        ./configure --with-spec=redhat --with-spl-obj="$SOURCES_DIR/spl-$VERSION" --with-linux="$CHROOT/usr/src/kernels/$KERNEL_VERSION/"
        rm -f *.rpm
        case "$TYPE" in
            kmod )
                make pkg-utils pkg-kmod
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/zfs-$VERSION/|" -e "s|^$CHROOT||" )
            ;;
            dkms )
                make pkg-utils rpm-dkms
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/zfs-$VERSION/|" -e "s|^$CHROOT||" )
            ;;
        esac
        popd

    fi

fi

# build dkms module
if [ "$TYPE" == "dkms" ]; then
    VERSION="$(rpm -qa zfs-dkms | awk -F- '{print $3}')"
    if ! (dkms install "spl/$VERSION" && dkms install "zfs/$VERSION"); then
         >&2 echo "Error: Can not build zfs dkms module"
         exit 1
    fi
fi

# final check for module
if ! (find "$CHROOT/lib/modules/$KERNEL_VERSION" -name zfs.ko | grep -q "."); then
     >&2 echo "Error: Can not found installed zfs module for current kernel"
     exit 1
fi

echo "Success"
