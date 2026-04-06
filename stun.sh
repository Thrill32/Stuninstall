#!/usr/bin/env bash

#install stunnel4, openvpn, and easyrsa

get_pm () {
    for mgr in apt dnf yum pacman zypper apk; do
        if command -v "$mgr" >/dev/null 2>&1; then
            echo "$mgr Selected"
            PM="$mgr"
            return
        fi
    done
    echo "Unsupported Package Manager"
    exit 1
    
}

get_stunnel_bin () {
    if command -v stunnel4 >/dev/null 2>&1; then
        echo "stunnel4"
        return 0
    fi

    if command -v stunnel >/dev/null 2>&1; then
        echo "stunnel"
        return 0
    fi

    return 1
}

get_default_iface () {
    local iface

    if command -v ip >/dev/null 2>&1; then
        iface="$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
    fi

    if [ -z "$iface" ] && command -v route >/dev/null 2>&1; then
        iface="$(route -n 2>/dev/null | awk '$1 == "0.0.0.0" {print $8; exit}')"
    fi

    if [ -z "$iface" ]; then
        return 1
    fi

    echo "$iface"
}

add_masq_rule () {
    local iface="$1"

    iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE >/dev/null 2>&1 || \
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
}

remove_masq_rule () {
    local iface="$1"

    while iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE >/dev/null 2>&1; do
        iptables -t nat -D POSTROUTING -o "$iface" -j MASQUERADE || break
    done
}

install_deps () {
    get_pm || return 1

    case "$PM" in
        apt)
            apt-get update
            apt-get install -y stunnel4 openvpn easy-rsa
            ;;
        dnf)
            dnf install -y stunnel openvpn easy-rsa
            ;;
        yum)
            yum install -y stunnel openvpn easy-rsa
            ;;
        zypper)
            zypper install -y stunnel openvpn easy-rsa
            ;;
        pacman)
            pacman -Sy --noconfirm stunnel openvpn easy-rsa
            ;;
        apk)
            apk add --no-cache stunnel openvpn easy-rsa
            ;;
        *)
            echo "Failed to install dependencies"
            exit 1
            ;;
    esac

    if [ -d /usr/share/easy-rsa ]; then
        EASYRSA_SRC="/usr/share/easy-rsa"
    elif [ -d /usr/share/easy-rsa3 ]; then
        EASYRSA_SRC="/usr/share/easy-rsa3"
    else
        echo "easy-rsa install directory not found"
        exit 1
    fi

    cp -r "$EASYRSA_SRC"/. /etc/stun/easy-rsa/

}

case "$1" in
    install)
        mkdir -p /etc/stun/easy-rsa
        cd /etc/stun/easy-rsa || exit

        install_deps
        echo "Dependencies installed"

        export EASYRSA_BATCH=1
        export EASYRSA_REQ_CN="server"

        ./easyrsa init-pki
        ./easyrsa build-ca nopass
        ./easyrsa gen-req server nopass
        ./easyrsa sign-req server server
        ./easyrsa gen-dh
        ./easyrsa gen-crl

        openvpn --genkey secret /etc/stun/ta.key

        cp pki/ca.crt /etc/stun
        cp pki/issued/server.crt /etc/stun
        cp pki/private/server.key /etc/stun
        cp pki/dh.pem /etc/stun
        cp pki/crl.pem /etc/stun
        chmod 644 /etc/stun/crl.pem

        cd /etc/stun || exit

        cat <<EOF > server.conf
port 1194
proto tcp
dev tun

local 127.0.0.1
ca /etc/stun/ca.crt
cert /etc/stun/server.crt
key /etc/stun/server.key
dh /etc/stun/dh.pem

tls-crypt /etc/stun/ta.key
crl-verify /etc/stun/crl.pem
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
        
        
        echo "Enter dns servers separated by slashes '/')"
        read -r RDNS
        IFS='/' read -r -a arr <<< "$RDNS"

        for _d in "${arr[@]}"; do
            echo "push \"dhcp-option DNS ${_d}\"" >> server.conf
        done

        #Stunnel -------------------------------------------------------------------------------

        echo "Enter TCP port (443 is HTTPS)"
        read -r PORT





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
        echo "Enter Server Public IP"
        read -r SERVER_IP

        cat <<EOF > stunclientconfig.conf
client = yes

[openvpn]
accept = 127.0.0.1:1194
connect = $SERVER_IP:$PORT
EOF

        mkdir /etc/stun/clients

        ;;
    start)
        STUNNEL_BIN="$(get_stunnel_bin)" || {
            echo "stunnel binary not found"
            exit 1
        }
        DEFAULT_IFACE="$(get_default_iface)" || {
            echo "Could not detect default network interface for MASQUERADE"
            exit 1
        }
        add_masq_rule "$DEFAULT_IFACE" || {
            echo "Failed to add MASQUERADE rule on interface: $DEFAULT_IFACE"
            exit 1
        }
        echo "$DEFAULT_IFACE" > /etc/stun/masq_iface
        openvpn --daemon --config /etc/stun/server.conf
        "$STUNNEL_BIN" /etc/stun/stunconfig.conf
        ;;
    stop)
        pkill -x openvpn 2>/dev/null
        pkill -x stunnel 2>/dev/null
        pkill -x stunnel4 2>/dev/null

        SAVED_IFACE=""
        if [ -f /etc/stun/masq_iface ]; then
            SAVED_IFACE="$(cat /etc/stun/masq_iface 2>/dev/null)"
        fi

        if [ -n "$SAVED_IFACE" ]; then
            remove_masq_rule "$SAVED_IFACE"
        fi

        CURRENT_IFACE="$(get_default_iface 2>/dev/null || true)"
        if [ -n "$CURRENT_IFACE" ] && [ "$CURRENT_IFACE" != "$SAVED_IFACE" ]; then
            remove_masq_rule "$CURRENT_IFACE"
        fi

        rm -f /etc/stun/masq_iface
        ;;
    addclient) 
        cd /etc/stun || exit
        mkdir -p /etc/stun/clients

        echo "Enter client name:"
        read -r NAME

        if [ -z "$NAME" ]; then
            echo "Client name cannot be empty"
            exit 1
        fi

        BASE_NAME="$NAME"
        NUM=2

        while [ -f "/etc/stun/clients/${NAME}.ovpn" ] || [ -f "/etc/stun/easy-rsa/pki/issued/${NAME}.crt" ] || [ -f "/etc/stun/easy-rsa/pki/private/${NAME}.key" ]; do
            echo "Client name taken.. appending $NUM"
            NAME="${BASE_NAME}${NUM}"
            NUM=$((NUM + 1))
        done

        cd /etc/stun/easy-rsa || exit
        export EASYRSA_BATCH=1
        ./easyrsa build-client-full "$NAME" nopass || {
            echo "Failed to generate client certificate and key"
            exit 1
        }
        cd /etc/stun || exit

        DEFAULT_PORT="$(awk -F '=' '/^[[:space:]]*accept[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); if ($2 ~ /^[0-9]+$/) {print $2; exit}}' /etc/stun/stunconfig.conf 2>/dev/null)"
        DEFAULT_PORT="${DEFAULT_PORT:-1194}"

        echo "Enter Server Public IP"
        read -r SERVER_IP
        echo "Enter remote port (default: $DEFAULT_PORT)"
        read -r REMOTE_PORT
        REMOTE_PORT="${REMOTE_PORT:-$DEFAULT_PORT}"

        cat <<EOF > "clients/${NAME}.ovpn"
client
proto tcp
dev tun

remote $SERVER_IP $REMOTE_PORT
cipher AES-256-GCM
persist-key
persist-tun

key-direction 1
auth SHA256

remote-cert-tls server

nobind
resolv-retry infinite

verb 3

<ca>
$(cat /etc/stun/ca.crt)
</ca>
<cert>
$(awk '/-----BEGIN CERTIFICATE-----/{print_flag=1} print_flag {print} /-----END CERTIFICATE-----/{print_flag=0}' "/etc/stun/easy-rsa/pki/issued/${NAME}.crt")
</cert>
<key>
$(cat "/etc/stun/easy-rsa/pki/private/${NAME}.key")
</key>
<tls-crypt>
$(cat /etc/stun/ta.key)
</tls-crypt>
EOF

        echo "Client profile created: /etc/stun/clients/${NAME}.ovpn"
        
        ;;
    delclient)
        cd /etc/stun || exit

        echo "Enter client name to delete:"
        read -r NAME

        if [ -z "$NAME" ]; then
            echo "Client name cannot be empty"
            exit 1
        fi

        if [ ! -d /etc/stun/easy-rsa ]; then
            echo "EasyRSA directory not found: /etc/stun/easy-rsa"
            exit 1
        fi

        cd /etc/stun/easy-rsa || exit
        export EASYRSA_BATCH=1

        CERT_STATE="$(awk -v cn="/CN=${NAME}" '$0 ~ cn"$" {state=substr($1,1,1)} END {if (state == "") print "N"; else print state}' pki/index.txt 2>/dev/null)"

        case "$CERT_STATE" in
            V)
                ./easyrsa revoke "$NAME" || {
                    echo "Failed to revoke certificate for ${NAME}"
                    exit 1
                }
                ./easyrsa gen-crl || {
                    echo "Failed to regenerate CRL"
                    exit 1
                }
                cp pki/crl.pem /etc/stun/crl.pem
                chmod 644 /etc/stun/crl.pem
                echo "Revoked certificate for ${NAME} and updated CRL"
                ;;
            R)
                if [ -f pki/crl.pem ]; then
                    cp pki/crl.pem /etc/stun/crl.pem
                    chmod 644 /etc/stun/crl.pem
                fi
                echo "Certificate for ${NAME} is already revoked"
                ;;
            *)
                echo "No certificate record found for ${NAME}; skipping revocation"
                ;;
        esac

        cd /etc/stun || exit

        rm -f "/etc/stun/clients/${NAME}.ovpn"
        rm -f "/etc/stun/easy-rsa/pki/issued/${NAME}.crt"
        rm -f "/etc/stun/easy-rsa/pki/private/${NAME}.key"
        rm -f "/etc/stun/easy-rsa/pki/reqs/${NAME}.req"

        if [ -f /etc/stun/server.conf ] && ! grep -Eq '^[[:space:]]*crl-verify[[:space:]]+/etc/stun/crl\.pem([[:space:]]|$)' /etc/stun/server.conf; then
            echo "crl-verify /etc/stun/crl.pem" >> /etc/stun/server.conf
            echo "Added crl-verify to server.conf"
        fi

        echo "Client ${NAME} deleted from files. Restart OpenVPN to ensure CRL changes are active."

        ;;
    help|"")
        SCRIPT_NAME="$(basename "$0")"
        cat <<EOF
Usage:
  ./$SCRIPT_NAME install
  ./$SCRIPT_NAME start
  ./$SCRIPT_NAME addclient
  ./$SCRIPT_NAME delclient
  ./$SCRIPT_NAME stop

Directions:
1. Run 'install' once on the server to set up OpenVPN, stunnel, and PKI files.
2. Run 'start' to launch OpenVPN and stunnel.
3. Run 'addclient' for each user; their profile is saved in /etc/stun/clients/<name>.ovpn.
4. Import that .ovpn file alongside the stunnel .conf file generated into the user's Stunskin client.
5. Run 'delclient' to revoke and remove a user.
6. After 'delclient', restart services (stop then start) so CRL changes are active.
EOF
        ;;
    *)
        echo "Unknown command: $1 Aborting..."
        exit 1
        ;;
esac 
