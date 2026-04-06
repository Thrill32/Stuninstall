#!/usr/bin/env bash

#install stunnel4, openvpn, and easyrsa

get_pm () {
    for mgr in apt dnf yum pacman zypper apk; do
        if command -v "$mgr" >/dev/null 2>&1; then
            echo "$mgr Selected"
            PM = "$mgr"
            return
        fi
    done
    echo "Unsupported Package Manager"
    exit 1
    ;;
}

install_deps () {
    get_pm || return 1

    case "$PM" in
        apt)
            apt-get update
            apt-get install -y stunnel4 openvpn easy-rsa
            EASYRSA_SRC="/usr/share/easy-rsa"
            ;;
        dnf)
            dnf install -y stunnel openvpn easy-rsa
            EASYRSA_SRC="/usr/share/easy-rsa"
            ;;
        yum)
            yum install -y stunnel openvpn easy-rsa
            EASYRSA_SRC="/usr/share/easy-rsa"
            ;;
        zypper)
            zypper install -y stunnel openvpn easy-rsa
            EASYRSA_SRC="/usr/share/easy-rsa"
            ;;
        pacman)
            pacman -Sy --noconfirm stunnel openvpn easy-rsa
            EASYRSA_SRC="/usr/share/easy-rsa"
            ;;
        *)
            echo "Failed to install dependencies"
            exit 1
            ;;
    esac

    cp -r "$EASYRSA_SRC"/. /etc/stun/easy-rsa/

}

case "$1" in
    install)
        mkdir -p /etc/stun/easy-rsa
        cd /etc/stun/easy-rsa

        install_deps
        echo "Dependencies installed"

        export EASYRSA_BATCH=1
        export EASYRSA_REQ_CN="server"

        ./easyrsa init-pki
        ./easyrsa build-ca nopass
        ./easyrsa gen-req server nopass
        ./easyrsa sign-req server server
        ./easyrsa gen-dh

        openvpn --genkey secret /etc/stun/ta.key

        cp pki/ca.crt /etc/stun
        cp pki/issued/server.crt /etc/stun
        cp pki/private/server.key /etc/stun
        cp pki/private/dh.pem /etc/stun

        cd /etc/stun

        #SERVER_IP=$(curl -s icanhazip.com)

        cat <<EOF > config.conf 
        port 1194
        proto tcp
        dev tun

        local 127.0.0.1
        ca /etc/stun/ca.crt
        cert /etc/stun/server.crt
        key /etc/stun/server.key
        dh /etc/stun/dh.pem

        tls-crypt /etc/stun/ta.key
        topology subnet
        server 10.8.0.0 255.255.255.0

        ifconfig-pool-persist ipp.txt

        keepalive 10 120
        cipher AES-256-GCM
        user nobody
        group nogroup
        persist-key
        persist-tun

        status openvpn-status.log
        verb 3

        push "redirect-gateway def1 bypass-dhcp"
        EOF
        ;;
        
        echo "Enter dns servers separated by slashes '/')"
        RDNS = $(read -r)
        DNS='/' read -ra arr <<< "$RDNS"

        for _d in DNS; do
            echo "push dhcp-option DNS ($_d)" >> config.conf
        done

        #Stunnel -------------------------------------------------------------------------------

        echo "Enter TCP port"
        PORT = $(read -r)





        #cat server.crt server.key ca.crt > stunnel.pem
        openssl req -new -x509 -days 36500 -nodes -out stunnel.pem -keyout stunnel.pem

        chmod 600 stunnel.pem




        cat <<EOF > stunconfig.conf 
        pid = /etc/stun/stunnel.pid
        cert = /etc/stun/stunnel.pem
        client = no
        setuid = stunnel4
        setgid = stunnel4
        socket = l:TCP_NODELAY=1
        socket = r:TCP_NODELAY=1
        foreground = no

        [openvpn]
        accept = $PORT
        connect = 127.0.0.1:1194
        EOF


    start)
        openvpn --config /etc/stun/server.conf
        stunnel /etc/stun/stunconfig.conf
        ;;
    stop)
        pkill openvpn
        pkill stunnel
        ;;
    help|"")
        echo "Usage: "
        ;;
    *)
        echo "Unknown command: $1 Aborting..."
        exit 1
        ;;
esac 
