#!/bin/sh
# OpenWrt MTProto Proxy Auto-Installer & LuCI App Integrator (using 9seconds/mtg)
# Installs mtg proxy and adds a modern JavaScript-based LuCI configuration page.

set -e

# Configuration variables
CONFIG_FILE="/etc/mtg.toml"
INIT_FILE="/etc/init.d/mtg"
BINARY_PATH="/usr/bin/mtg"
DEFAULT_PORT=443
DEFAULT_DOMAIN="google.com"

# LuCI app files paths
LUCI_CONFIG="/etc/config/mtg"
LUCI_MENU="/usr/share/luci/menu.d/luci-app-mtg.json"
LUCI_ACL="/usr/share/rpcd/acl.d/luci-app-mtg.json"
LUCI_VIEW_DIR="/www/luci-static/resources/view/mtg"
LUCI_VIEW_FILE="${LUCI_VIEW_DIR}/main.js"

echo "================================================="
echo "  OpenWrt MTProto Proxy Installer + LuCI App     "
echo "================================================="

# Helper functions for downloading files and retrieving output from URLs
download_file() {
    local url="$1"
    local dest="$2"
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$dest" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -sL -o "$dest" "$url"
    else
        wget -qO "$dest" "$url"
    fi
}

fetch_url_stdout() {
    local url="$1"
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O - "$url" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -sL "$url"
    else
        wget -qO- "$url" 2>/dev/null
    fi
}

# 1. Check for space and dependencies
echo "[*] Checking and installing dependencies..."
if command -v apk >/dev/null 2>&1; then
    echo "    apk package manager detected (OpenWrt 25.12+)"
    apk update
    # We do NOT install the 'wget' package because it installs 'wget-nossl' by default,
    # which overrides the working TLS-capable default downloader and breaks HTTPS downloads.
    apk add ca-certificates ca-bundle libustream-openssl tar uci || {
        echo "[!] Warning: Some dependencies failed to install. We will proceed anyway."
    }
elif command -v opkg >/dev/null 2>&1; then
    echo "    opkg package manager detected (OpenWrt 24.10 or older)"
    opkg update
    opkg install ca-bundle ca-certificates libustream-openssl tar uci || {
        echo "[!] Warning: Some dependencies failed to install. We will proceed anyway."
    }
else
    echo "[!] Warning: No known package manager found (neither apk nor opkg). Skipping dependency installation."
fi

# 2. Detect CPU architecture
echo "[*] Detecting CPU architecture..."
UNAME_M=$(uname -m)
RAW_ARCH=""

if command -v opkg >/dev/null 2>&1; then
    RAW_ARCH=$(opkg print-architecture | awk '/arch/ {print $2}' | head -n 1)
elif [ -f /etc/apk/arch ]; then
    RAW_ARCH=$(cat /etc/apk/arch)
fi

echo "    Detected hardware architecture: uname=$UNAME_M, raw_arch=$RAW_ARCH"

MTG_ARCH=""
case "$RAW_ARCH" in
    *aarch64*|*arm64*)
        MTG_ARCH="arm64"
        ;;
    *arm_cortex-a7*|*arm_cortex-a9*|*arm_cortex-a15*|*armv7*)
        MTG_ARCH="armv7"
        ;;
    *mipsel_24kc*|*mipsel_74kc*|*mipsel*)
        MTG_ARCH="mipsle"
        ;;
    *mips_24kc*|*mips_74kc*|*mips*)
        MTG_ARCH="mips"
        ;;
    *x86_64*|*amd64*)
        MTG_ARCH="amd64"
        ;;
esac

# Fallback check using uname -m
if [ -z "$MTG_ARCH" ]; then
    case "$UNAME_M" in
        aarch64|arm64) MTG_ARCH="arm64" ;;
        armv7*) MTG_ARCH="armv7" ;;
        mips64el|mipsel) MTG_ARCH="mipsle" ;;
        mips64|mips) MTG_ARCH="mips" ;;
        x86_64) MTG_ARCH="amd64" ;;
    esac
fi

if [ -z "$MTG_ARCH" ]; then
    echo "[!] Could not auto-detect architecture."
    echo "Please select architecture manually:"
    echo "1) arm64"
    echo "2) armv7"
    echo "3) mipsle (MIPS Little Endian, e.g. MediaTek MT7621)"
    echo "4) mips (MIPS Big Endian, e.g. Atheros)"
    echo "5) amd64 (x86_64)"
    printf "Enter choice [1-5]: "
    read ARCH_CHOICE
    case "$ARCH_CHOICE" in
        1) MTG_ARCH="arm64" ;;
        2) MTG_ARCH="armv7" ;;
        3) MTG_ARCH="mipsle" ;;
        4) MTG_ARCH="mips" ;;
        5) MTG_ARCH="amd64" ;;
        *) echo "[!] Invalid choice. Exiting."; exit 1 ;;
    esac
else
    echo "[+] Auto-detected architecture for mtg: $MTG_ARCH"
fi

# 3. Find and download the latest version of mtg
VERSION="2.1.7"
DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/v${VERSION}/mtg-${VERSION}-linux-${MTG_ARCH}.tar.gz"

echo "[*] Downloading mtg v${VERSION}..."
echo "    URL: $DOWNLOAD_URL"

rm -rf /tmp/mtg-install
mkdir -p /tmp/mtg-install
cd /tmp/mtg-install

if ! download_file "$DOWNLOAD_URL" "mtg.tar.gz"; then
    echo "[!] Download failed. Please check internet connection or manually upload the binary to /usr/bin/mtg."
    exit 1
fi

echo "[*] Extracting binary..."
tar -xzf mtg.tar.gz
if [ -f "mtg" ]; then
    mv mtg "$BINARY_PATH"
else
    FOUND_BIN=$(find . -type f -name "mtg" | head -n 1)
    if [ -n "$FOUND_BIN" ]; then
        mv "$FOUND_BIN" "$BINARY_PATH"
    else
        echo "[!] Binary 'mtg' not found in archive."
        exit 1
    fi
fi

chmod +x "$BINARY_PATH"
cd /
rm -rf /tmp/mtg-install
echo "[+] Binary successfully installed to $BINARY_PATH"

# 4. Prompt for Configuration
printf "Enter port for proxy (default: $DEFAULT_PORT): "
read PORT
PORT=${PORT:-$DEFAULT_PORT}

printf "Enter host to impersonate for FakeTLS (default: $DEFAULT_DOMAIN): "
read DOMAIN
DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

echo "[*] Generating FakeTLS secret..."
SECRET=$($BINARY_PATH generate-secret --hex "$DOMAIN")
echo "    Generated Secret: $SECRET"

# 5. Create UCI configuration file (/etc/config/mtg)
echo "[*] Creating UCI configuration at $LUCI_CONFIG..."
cat << EOF > "$LUCI_CONFIG"
config mtg 'config'
	option enabled '1'
	option port '$PORT'
	option domain '$DOMAIN'
	option secret '$SECRET'
EOF

# 6. Create init.d script (/etc/init.d/mtg) that integrates with UCI config
echo "[*] Creating service script at $INIT_FILE..."
cat << 'EOF' > "$INIT_FILE"
#!/bin/sh /etc/rc.common

# Service script for mtg proxy using OpenWrt procd system.
# Reads settings from UCI config '/etc/config/mtg'.

USE_PROCD=1
START=99
STOP=10

cleanup_firewall() {
    while true; do
        local match=$(uci show firewall | grep -E "name='Allow-MTProto|name='Redirect-MTProto" | head -n 1)
        [ -z "$match" ] && break
        local sec=$(echo "$match" | cut -d'.' -f2)
        uci delete firewall.$sec
    done
    uci commit firewall
    /etc/init.d/firewall reload
}

start_service() {
    config_load mtg
    
    local enabled port domain secret
    
    config_get_bool enabled config enabled 0
    config_get port config port 443
    config_get domain config domain "google.com"
    config_get secret config secret ""
    
    # 1. Clean up old rules first
    cleanup_firewall
    
    [ "$enabled" -eq 0 ] && return
    [ -z "$secret" ] && return

    # Fetch public IP from router and save it to file
    local public_ip=""
    if command -v uclient-fetch >/dev/null 2>&1; then
        public_ip=$(uclient-fetch -q -O - http://icanhazip.com || uclient-fetch -q -O - http://ifconfig.me || echo "")
    elif command -v curl >/dev/null 2>&1; then
        public_ip=$(curl -sL http://icanhazip.com || curl -sL http://ifconfig.me || echo "")
    else
        public_ip=$(wget -qO- http://icanhazip.com || wget -qO- http://ifconfig.me || echo "")
    fi
    public_ip=$(echo "$public_ip" | tr -d '\r\n[:space:]')
    echo "$public_ip" > /var/run/mtg.ip
    
    local bind_port=$port
    local use_redirect=0
    
    if [ "$port" -eq 443 ]; then
        bind_port=8443
        use_redirect=1
    fi
    
    # 2. Add appropriate firewall rules
    if [ "$use_redirect" -eq 1 ]; then
        # Redirect WAN 443 -> Local 8443 to avoid conflict with uhttpd
        uci add firewall redirect
        uci set firewall.@redirect[-1].name="Redirect-MTProto-443"
        uci set firewall.@redirect[-1].src="wan"
        uci set firewall.@redirect[-1].src_dport="443"
        uci set firewall.@redirect[-1].dest_port="8443"
        uci set firewall.@redirect[-1].proto="tcp"
        uci set firewall.@redirect[-1].target="DNAT"
        
        # Open the redirected port 8443 in the firewall input chain
        uci add firewall rule
        uci set firewall.@rule[-1].name="Allow-MTProto-8443"
        uci set firewall.@rule[-1].src="wan"
        uci set firewall.@rule[-1].proto="tcp"
        uci set firewall.@rule[-1].dest_port="8443"
        uci set firewall.@rule[-1].target="ACCEPT"
    else
        # Open port $port directly
        uci add firewall rule
        uci set firewall.@rule[-1].name="Allow-MTProto-$port"
        uci set firewall.@rule[-1].src="wan"
        uci set firewall.@rule[-1].proto="tcp"
        uci set firewall.@rule[-1].dest_port="$port"
        uci set firewall.@rule[-1].target="ACCEPT"
    fi
    uci commit firewall
    /etc/init.d/firewall reload
    
    # Write a temporary mtg.toml configuration file in RAM
    local temp_config="/var/run/mtg.toml"
    cat << F_EOF > "$temp_config"
secret = "$secret"
bind-to = "0.0.0.0:$bind_port"

[network]
dns = "udp://127.0.0.1:53"
F_EOF

    procd_open_instance
    procd_set_param command /usr/bin/mtg run "$temp_config"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall mtg 2>/dev/null
    rm -f /var/run/mtg.toml
    rm -f /var/run/mtg.ip
    cleanup_firewall
}

service_triggers() {
    procd_add_reload_trigger "mtg"
}
EOF

chmod +x "$INIT_FILE"
echo "[+] Service registered."

# 7. Create LuCI JSON Menu Definition
echo "[*] Registering LuCI Web Interface menu..."
cat << EOF > "$LUCI_MENU"
{
  "admin/services/mtg": {
    "title": "MTProto Proxy",
    "order": 60,
    "action": {
      "type": "view",
      "path": "mtg/main"
    }
  }
}
EOF

# 8. Create LuCI Access Control List (ACL)
echo "[*] Creating LuCI Access Control Permissions..."
cat << EOF > "$LUCI_ACL"
{
  "luci-app-mtg": {
    "description": "Grant access to MTProto Proxy settings",
    "read": {
      "uci": [ "mtg" ],
      "file": {
        "/var/run/mtg.ip": [ "read" ]
      }
    },
    "write": {
      "uci": [ "mtg" ]
    }
  }
}
EOF

# 9. Create LuCI JS view file (/www/luci-static/resources/view/mtg/main.js)
echo "[*] Creating LuCI Web View..."
mkdir -p "$LUCI_VIEW_DIR"
cat << 'EOF' > "$LUCI_VIEW_FILE"
'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';
'require network';

return view.extend({
    load: function() {
        var getWAN = network.getWANNetworks()
            .then(function(n) { return n; })
            .catch(function() { return []; });
            
        var getPublicIP = fs.read('/var/run/mtg.ip')
            .then(function(t) { return t ? t.trim() : null; })
            .catch(function() { return null; });

        return Promise.all([
            uci.load('mtg'),
            getWAN,
            getPublicIP
        ]);
    },

    render: function(data) {
        var m, s, o;

        var wanNetworks = data[1];
        var publicIP = data[2];
        
        var wanIP = null;
        if (wanNetworks && wanNetworks.length > 0) {
            for (var i = 0; i < wanNetworks.length; i++) {
                var addrs = wanNetworks[i].getIPAddrs();
                if (addrs && addrs.length > 0) {
                    wanIP = addrs[0];
                    break;
                }
            }
        }
        
        var displayHost = publicIP || wanIP || window.location.hostname;

        m = new form.Map('mtg', _('Telegram MTProto Proxy (mtg)'), 
            _('Веб-интерфейс для управления легковесным прокси-сервером MTProto от разработчика 9seconds с поддержкой FakeTLS.'));

        s = m.section(form.NamedSection, 'config', 'mtg', _('Настройки прокси'));

        // Enabled
        var o_enabled = s.option(form.Flag, 'enabled', _('Включить службу'));
        o_enabled.rmempty = false;

        // Port
        var o_port = s.option(form.Value, 'port', _('Входящий порт'), 
            _('Порт, который прокси-сервер будет слушать. Рекомендуется использовать 443 (стандартный HTTPS).'));
        o_port.datatype = 'port';
        o_port.default = '443';
        o_port.rmempty = false;

        // Domain
        var o_domain = s.option(form.Value, 'domain', _('Домен маскировки (FakeTLS)'), 
            _('Домен, под который маскируется трафик (например, google.com). Пользователи будут видеть обычное TLS-соединение.'));
        o_domain.default = 'google.com';
        o_domain.rmempty = false;

        // Secret
        var o_secret = s.option(form.Value, 'secret', _('Секретный ключ (Secret)'),
            _('Криптографический FakeTLS-секрет (начинается на "ee"). Вы можете сгенерировать его кнопкой ниже или ввести вручную.'));
        o_secret.rmempty = false;
        o_secret.render = function(section_id, option_index) {
            return form.Value.prototype.render.apply(this, [section_id, option_index]).then(function(node) {
                var btn = E('button', {
                    'class': 'cbi-button cbi-button-action',
                    'style': 'margin-top: 8px; display: inline-block;',
                    'click': function(ev) {
                        ev.preventDefault();
                        
                        var domainInput = document.querySelector('input[name$=".domain"]') || 
                                          document.querySelector('[id$=".domain"]') || 
                                          document.getElementById('cbid.mtg.config.domain');
                        var domain = domainInput ? domainInput.value.trim() : 'google.com';
                        if (!domain) domain = 'google.com';
                        
                        var chars = '0123456789abcdef';
                        var randHex = '';
                        for (var i = 0; i < 32; i++) {
                            randHex += chars[Math.floor(Math.random() * 16)];
                        }
                        var domainHex = '';
                        for (var i = 0; i < domain.length; i++) {
                            domainHex += domain.charCodeAt(i).toString(16).padStart(2, '0');
                        }
                        var secret = 'ee' + randHex + domainHex;
                        
                        var secretInput = node.querySelector('input');
                        if (secretInput) {
                            secretInput.value = secret;
                            secretInput.dispatchEvent(new Event('change'));
                            ui.add_notification(null, _('Секретный ключ сгенерирован под домен: ') + domain, 'info');
                        }
                    }
                }, [ _('Сгенерировать секрет') ]);
                
                var fieldContainer = node.querySelector('.cbi-value-field');
                if (fieldContainer) {
                    fieldContainer.appendChild(E('br'));
                    fieldContainer.appendChild(btn);
                } else {
                    node.appendChild(btn);
                }
                
                return node;
            });
        };

        // Connections links based on saved UCI values
        var s_links = m.section(form.NamedSection, 'config', 'mtg', _('Подключение клиентов'));
        o = s_links.option(form.DummyValue, '_links', _('Готовые ссылки'));
        o.rawhtml = true;
        o.cfgvalue = function(section_id) {
            var host = displayHost;
            var enabled = uci.get('mtg', section_id, 'enabled');
            var port = uci.get('mtg', section_id, 'port') || '443';
            var secret = uci.get('mtg', section_id, 'secret');
            
            if (enabled !== '1') {
                return '<em>' + _('Включите службу (поставьте галочку "Включить службу" выше) и примените настройки (нажмите "Save & Apply"), чтобы увидеть ссылки для подключения.') + '</em>';
            }
            
            if (!secret) {
                return '<em style="color: red;">' + _('Сгенерируйте секретный ключ и сохраните настройки.') + '</em>';
            }
            
            var link1 = 'https://t.me/proxy?server=' + host + '&port=' + port + '&secret=' + secret;
            var link2 = 'tg://proxy?server=' + host + '&port=' + port + '&secret=' + secret;
            
            return '<div style="margin-top: 10px;">' +
                   '<strong>' + _('Ссылка для подключения:') + '</strong><br/>' +
                   '<a href="' + link1 + '" target="_blank" style="word-break: break-all; color: #106fb8; font-weight: bold; font-size: 1.15em; display: inline-block; margin: 8px 0;">' + link1 + '</a><br/>' +
                   '<span style="color: #666; font-size: 0.9em;">' + _('Примечание: если вы используете белый динамический IP, замените в ссылке IP-адрес роутера (' + host + ') на ваше DDNS имя.') + '</span><br/><br/>' +
                   '<strong>' + _('Альтернативная ссылка (tg://):') + '</strong><br/>' +
                   '<code style="word-break: break-all; display: inline-block; margin-top: 5px; padding: 6px 10px; background: #f8f9fa; border-radius: 4px; border: 1px solid #e9ecef; font-family: monospace; font-size: 0.95em;">' + link2 + '</code>' +
                   '</div>';
        };

        return m.render();
    }
});
EOF
echo "[+] LuCI Web View created."

# 10. Open Firewall Port via UCI
echo "[*] Firewall rules will be managed dynamically by the mtg service."

# 11. Restart services and clear LuCI cache
echo "[*] Restarting services and clearing LuCI cache..."
/etc/init.d/rpcd restart
rm -f /var/luci-indexcache
/etc/init.d/mtg enable
/etc/init.d/mtg start

PUBLIC_IP=$(fetch_url_stdout http://icanhazip.com || fetch_url_stdout http://ifconfig.me || echo "<YOUR_PUBLIC_IP_OR_DDNS>")

echo "================================================="
echo "   Installation & LuCI App Setup Completed!      "
echo "================================================="
echo "1. Web configuration is now available in LuCI under:"
echo "   Services -> MTProto Proxy"
echo ""
echo "2. Initial proxy details:"
echo "   Port: $PORT"
echo "   Domain: $DOMAIN"
echo "   Secret: $SECRET"
echo ""
echo "3. Connection Link:"
echo "   https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${SECRET}"
echo "================================================="
