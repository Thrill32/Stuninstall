#!/usr/bin/env bash

#install stunnel4, openvpn, and easyrsa

apt () { #apt-get

}

dnf () {
    
}

yum () {

}

zypper () {

}

pacman () {

}

case "$1" in
    help|"")
        echo "Usage: "
        ;;
    *)
        echo "Unknown command: $1 Aborting..."
        exit 1
        ;;
esac 