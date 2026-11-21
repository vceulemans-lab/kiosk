#!/bin/bash
# Kiosk-setup, versie 2 - Debian 13 (of 12), minimale installatie.
# Uitvoeren als root:   su -    en dan:   bash kiosk-setup2.sh
set -e

if [ "$(id -u)" -ne 0 ]; then echo "Voer dit uit als root (su -)."; exit 1; fi

# Modus voor de automatische installatie: de installer roept dit aan met --eerste-start.
# Het script wordt dan bij de eerste start van het nieuwe systeem op het scherm uitgevoerd.
if [ "${1:-}" = "--eerste-start" ]; then
  cat > /etc/systemd/system/kiosk-firstboot.service <<'EOS'
[Unit]
Description=Kiosk-installatie bij de eerste start
After=network-online.target
Wants=network-online.target
After=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=oneshot
StandardInput=tty-force
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TimeoutStartSec=infinity
ExecStart=/bin/bash /root/kiosk-setup2.sh
# Alleen na een geslaagde installatie: root vergrendelen, dienst uitzetten, herstarten
ExecStartPost=/usr/bin/passwd -l root
ExecStartPost=/bin/systemctl disable kiosk-firstboot.service
ExecStartPost=/bin/systemctl --no-block reboot

[Install]
WantedBy=multi-user.target
EOS
  systemctl enable kiosk-firstboot.service
  exit 0
fi

ja() {  # ja "vraag" j|n   -> geeft 0 bij ja, 1 bij nee
  local d="${2:-j}" a hint="J/n"
  [ "$d" = n ] && hint="j/N"
  while true; do
    read -r -p "$1 [$hint] " a
    a="${a:-$d}"; a="${a,,}"
    case "$a" in j|ja|y|yes) return 0;; n|nee|no) return 1;; esac
  done
}

echo "=============== Kiosk-installatie ==============="

### 1. Beheerder ###########################################################
echo
while true; do
  read -r -p "Gebruikersnaam voor de beheerder (kleine letters, bv. beheer): " ADMIN
  if [[ "$ADMIN" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] && [ "$ADMIN" != kiosk ] && [ "$ADMIN" != root ]; then break; fi
  echo "Ongeldig. Gebruik kleine letters/cijfers, begin met een letter, niet 'kiosk' of 'root'."
done
while true; do
  read -r -s -p "Wachtwoord voor $ADMIN: " PW1; echo
  read -r -s -p "Herhaal het wachtwoord: " PW2; echo
  if [ -n "$PW1" ] && [ "$PW1" = "$PW2" ]; then break; fi
  echo "De wachtwoorden komen niet overeen (of zijn leeg). Probeer opnieuw."
done

### 2. URL #################################################################
echo
while true; do
  read -r -p "Adres (URL) van de cataloguswebsite: " URL
  URL="${URL// /}"
  [ -n "$URL" ] || continue
  case "$URL" in http://*|https://*) ;; *) URL="https://$URL";; esac
  case "$URL" in *\"*|*\\*|*\$*|*\`*) echo "Het adres bevat een ongeldig teken (\" \\ \$ \`)."; continue;; esac
  break
done

### 3. Opties ##############################################################
echo
if ja "Mogen bezoekers usb-sticks gebruiken?" j; then USB=ja; else USB=nee; fi

EXTRA=""
if ja "Mogen bezoekers ook andere websites bezoeken?" j; then
  SURF=ja
else
  SURF=nee
  read -r -p "Extra toegelaten websites (bv. bib.be, gescheiden door komma's; leeg = geen): " EXTRA
  EXTRA="$(printf '%s' "$EXTRA" | tr -cd 'A-Za-z0-9.,-')"
fi

echo
echo "Wat moet er gebeuren bij inactiviteit?"
echo "  1) Niets"
echo "  2) Screensaver (scherm uitschakelen)"
echo "  3) Slaapstand"
echo "  4) Computer afsluiten"
while true; do
  read -r -p "Keuze [1-4]: " C
  case "$C" in 1) INACT=niets;; 2) INACT=scherm;; 3) INACT=slaap;; 4) INACT=uit;; *) continue;; esac
  break
done
MIN=0
if [ "$INACT" != niets ]; then
  while true; do
    read -r -p "Na hoeveel minuten inactiviteit (1-60)? " MIN
    if [[ "$MIN" =~ ^[0-9]+$ ]] && [ "$MIN" -ge 1 ] && [ "$MIN" -le 60 ]; then break; fi
  done
fi

echo
if ja "Knop 'Computer afsluiten' tonen in de kiosk?" j; then KNOP=ja; else KNOP=nee; fi

### 4. Achtergrond via usb-stick ###########################################
BGTMP=""
echo
if ja "Een andere achtergrond dan zwart (afbeelding van een usb-stick)?" n; then
  while [ -z "$BGTMP" ]; do
    echo
    read -r -p "Steek de usb-stick in en druk op Enter (typ 's' om over te slaan): " X
    if [ "$X" = s ]; then break; fi
    sleep 3
    mapfile -t PARTS < <(lsblk -rpno NAME,TYPE,RM,FSTYPE | awk '$2=="part" && $3=="1" && NF==4 {print $1}')
    if [ "${#PARTS[@]}" -eq 0 ]; then echo "Geen usb-stick gevonden."; continue; fi
    echo "Gevonden partities:"
    for i in "${!PARTS[@]}"; do
      echo "  $((i+1))) ${PARTS[$i]}  $(lsblk -no SIZE,LABEL "${PARTS[$i]}" | head -n1)"
    done
    read -r -p "Nummer: " N
    if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ] || [ "$N" -gt "${#PARTS[@]}" ]; then continue; fi
    mkdir -p /mnt/kioskusb
    if ! mount -o ro "${PARTS[$((N-1))]}" /mnt/kioskusb 2>/dev/null; then
      echo "Kon de stick niet aankoppelen."; continue
    fi
    mapfile -d '' -t IMGS < <(find /mnt/kioskusb -maxdepth 3 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -print0 | head -z -n 40)
    if [ "${#IMGS[@]}" -eq 0 ]; then
      echo "Geen afbeeldingen (jpg/png) gevonden."; umount /mnt/kioskusb; continue
    fi
    for i in "${!IMGS[@]}"; do echo "  $((i+1))) ${IMGS[$i]#/mnt/kioskusb/}"; done
    read -r -p "Nummer van de afbeelding (0 = andere stick kiezen): " N
    if [[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le "${#IMGS[@]}" ]; then
      f="${IMGS[$((N-1))]}"; ext="${f##*.}"; ext="${ext,,}"
      cp "$f" "/root/.kiosk-achtergrond.$ext"
      BGTMP="/root/.kiosk-achtergrond.$ext"
    fi
    umount /mnt/kioskusb
  done
fi

### Overzicht ##############################################################
echo
echo "================= Overzicht ================="
echo "Beheerder        : $ADMIN"
echo "Startpagina      : $URL"
echo "USB-sticks       : $USB"
echo "Andere websites  : $SURF ${EXTRA:+(uitzonderingen: $EXTRA)}"
case "$INACT" in
  niets)  echo "Inactiviteit     : niets";;
  scherm) echo "Inactiviteit     : scherm uit na $MIN min";;
  slaap)  echo "Inactiviteit     : slaapstand na $MIN min";;
  uit)    echo "Inactiviteit     : afsluiten na $MIN min";;
esac
echo "Afsluitknop      : $KNOP"
echo "Achtergrond      : ${BGTMP:-zwart}"
echo "============================================="
if ! ja "Doorgaan met installeren?" j; then echo "Afgebroken."; exit 1; fi

### Installatie ############################################################
echo ">> Pakketten installeren"
export DEBIAN_FRONTEND=noninteractive
PKGS="xorg openbox lightdm lightdm-gtk-greeter firefox-esr rsync sudo x11-xserver-utils unattended-upgrades apt-listchanges fonts-dejavu libpam-systemd dbus-x11 dbus-user-session numlockx"
if [ "$USB" = ja ]; then PKGS="$PKGS udisks2 udiskie gvfs ntfs-3g exfatprogs"; fi
if [ "$KNOP" = ja ]; then PKGS="$PKGS tint2 zenity"; fi
if [ "$INACT" = slaap ] || [ "$INACT" = uit ]; then PKGS="$PKGS xprintidle"; fi
if [ -n "$BGTMP" ]; then PKGS="$PKGS feh"; fi
apt-get -o DPkg::Lock::Timeout=300 update
# shellcheck disable=SC2086
apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends $PKGS

echo ">> Beheerder $ADMIN instellen"
if ! id "$ADMIN" >/dev/null 2>&1; then adduser --disabled-password --gecos "" "$ADMIN"; fi
printf '%s:%s\n' "$ADMIN" "$PW1" | chpasswd
usermod -aG sudo "$ADMIN"

echo ">> Gebruiker kiosk (geen wachtwoord, geen sudo)"
if ! id kiosk >/dev/null 2>&1; then adduser --disabled-password --gecos "Kiosk" kiosk; fi
for g in audio video render; do
  if getent group "$g" >/dev/null; then usermod -aG "$g" kiosk; fi
done

echo ">> Configuratie opslaan in /etc/kiosk.conf"
cat > /etc/kiosk.conf <<EOF
URL="$URL"
SURF="$SURF"
EXTRA="$EXTRA"
EOF

echo ">> Automatische aanmelding"
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-kiosk.conf <<EOF
[Seat:*]
autologin-user=kiosk
autologin-user-timeout=0
autologin-session=openbox
greeter-setup-script=/usr/bin/numlockx on
session-setup-script=/usr/bin/numlockx on
EOF

echo ">> Hulpprogramma's"
cat > /usr/local/sbin/kiosk-beleid <<'EOF'
#!/bin/bash
# Maakt het Firefox-beleid (policies.json) op basis van /etc/kiosk.conf
. /etc/kiosk.conf
HOST=$(printf '%s' "$URL" | sed -E 's|^[a-zA-Z]+://([^/:?#]+).*|\1|')
FILTER=""
if [ "$SURF" = "nee" ]; then
  EX="\"*://*.$HOST/*\""
  IFS=',' read -ra L <<< "$EXTRA"
  for d in "${L[@]}"; do
    d="${d// /}"
    if [ -n "$d" ]; then EX="$EX, \"*://*.$d/*\""; fi
  done
  FILTER=", \"WebsiteFilter\": { \"Block\": [\"<all_urls>\"], \"Exceptions\": [ $EX ] }"
fi
mkdir -p /usr/lib/firefox-esr/distribution
cat > /usr/lib/firefox-esr/distribution/policies.json <<EOP
{
  "policies": {
    "Homepage": { "URL": "$URL", "StartPage": "homepage" },
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "NoDefaultBookmarks": true,
    "DontCheckDefaultBrowser": true,
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableAppUpdate": true,
    "DisableProfileImport": true,
    "DisableAccounts": true,
    "PasswordManagerEnabled": false,
    "BlockAboutConfig": true
    $FILTER
  }
}
EOP
EOF

cat > /usr/local/sbin/kiosk-url <<'EOF'
#!/bin/bash
# Gebruik: sudo kiosk-url https://nieuw-adres
if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi
U="${1// /}"
if [ -z "$U" ]; then echo "Gebruik: sudo kiosk-url https://adres"; exit 1; fi
case "$U" in http://*|https://*) ;; *) U="https://$U";; esac
case "$U" in *\"*|*\\*|*\$*|*\`*) echo "Ongeldig teken in het adres."; exit 1;; esac
grep -v '^URL=' /etc/kiosk.conf > /etc/kiosk.conf.new
echo "URL=\"$U\"" >> /etc/kiosk.conf.new
mv /etc/kiosk.conf.new /etc/kiosk.conf
/usr/local/sbin/kiosk-beleid
echo "Startpagina is nu: $U  (herstart de kiosk om het te zien)"
EOF

cat > /usr/local/sbin/kiosk-reset <<'EOF'
#!/bin/bash
# Zet de thuismap van kiosk terug naar het opgeslagen sjabloon
rsync -a --delete /var/lib/kiosk-template/ /home/kiosk/
chown -R kiosk:kiosk /home/kiosk
EOF

cat > /usr/local/sbin/kiosk-opslaan <<'EOF'
#!/bin/bash
# Bewaar de huidige thuismap van kiosk als nieuw sjabloon
mkdir -p /var/lib/kiosk-template
rsync -a --delete \
  --exclude='.cache' --exclude='.Xauthority' --exclude='.xsession-errors*' \
  --exclude='lock' --exclude='.parentlock' --exclude='sessionstore-backups' \
  /home/kiosk/ /var/lib/kiosk-template/
echo "Kiosk-instellingen opgeslagen."
EOF

cat > /usr/local/bin/kiosk-beheer <<'EOF'
#!/bin/bash
# Uitvoeren als beheerder in een terminal in zijn grafische sessie (kiosk is dan afgemeld).
# Opent Firefox met het profiel van kiosk; daarna kan je de wijzigingen bewaren.
. /etc/kiosk.conf
sudo /usr/local/sbin/kiosk-reset
xhost +SI:localuser:kiosk >/dev/null
sudo -u kiosk -H env DISPLAY="$DISPLAY" firefox-esr "$URL"
xhost -SI:localuser:kiosk >/dev/null
read -p "Wijzigingen bewaren voor alle kiosk-starts? [j/N] " a
if [ "$a" = "j" ]; then sudo /usr/local/sbin/kiosk-opslaan; fi
EOF

cat > /usr/local/bin/kiosk-afsluiten <<'EOF'
#!/bin/bash
zenity --question --title="Afsluiten" --text="De computer afsluiten?" \
  --ok-label="Ja, afsluiten" --cancel-label="Annuleren" --width=300 \
  && sudo /usr/bin/systemctl poweroff
EOF
cat > /usr/local/bin/kiosk-inactiviteit <<'EOF'
#!/bin/bash
# Gebruik: kiosk-inactiviteit <minuten> <suspend|poweroff>
case "$2" in suspend|poweroff) ;; *) exit 1;; esac
LIMIT=$(( $1 * 60000 ))
while sleep 20; do
  if [ "$(xprintidle 2>/dev/null || echo 0)" -ge "$LIMIT" ]; then
    sudo /usr/bin/systemctl "$2"
    sleep 60
  fi
done
EOF
chmod +x /usr/local/sbin/kiosk-* /usr/local/bin/kiosk-beheer /usr/local/bin/kiosk-afsluiten /usr/local/bin/kiosk-inactiviteit

/usr/local/sbin/kiosk-beleid

echo ">> Rechten om af te sluiten / slaapstand (alleen die twee commando's)"
if [ "$KNOP" = ja ] || [ "$INACT" = slaap ] || [ "$INACT" = uit ]; then
  echo 'kiosk ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/bin/systemctl suspend' > /etc/sudoers.d/kiosk-power
  chmod 440 /etc/sudoers.d/kiosk-power
  visudo -cf /etc/sudoers.d/kiosk-power
fi

echo ">> Achtergrond"
BGFILE=""
rm -f /usr/share/kiosk/achtergrond.*
if [ -n "$BGTMP" ]; then
  install -d /usr/share/kiosk
  BGFILE="/usr/share/kiosk/achtergrond.${BGTMP##*.}"
  install -m 644 "$BGTMP" "$BGFILE"
  rm -f "$BGTMP"
fi

echo ">> NumLock aan (voor de beheerder via de systeem-autostart)"
if ! grep -q numlockx /etc/xdg/openbox/autostart 2>/dev/null; then
  echo 'numlockx on &' >> /etc/xdg/openbox/autostart
fi

echo ">> Openbox-sessie voor kiosk"
install -d -o kiosk -g kiosk /home/kiosk/.config/openbox /home/kiosk/.config/tint2
cp /etc/xdg/openbox/rc.xml /home/kiosk/.config/openbox/rc.xml
sed -i '0,/<applications>/s||<applications>\n<application class="firefox*"><maximized>yes</maximized></application>|' \
  /home/kiosk/.config/openbox/rc.xml

AS=/home/kiosk/.config/openbox/autostart
{
  echo ". /etc/kiosk.conf"
  echo "numlockx on &"
  if [ -n "$BGFILE" ]; then echo "feh --no-fehbg --bg-fill $BGFILE &"; else echo "xsetroot -solid black &"; fi
  if [ "$INACT" = scherm ]; then
    echo "xset s off +dpms dpms $((MIN*60)) $((MIN*60)) $((MIN*60)) &"
  else
    echo "xset s off -dpms &"
  fi
  if [ "$USB" = ja ]; then echo "udiskie --no-tray &"; fi
  if [ "$KNOP" = ja ]; then echo "tint2 &"; fi
  if [ "$INACT" = slaap ]; then echo "kiosk-inactiviteit $MIN suspend &"; fi
  if [ "$INACT" = uit ]; then echo "kiosk-inactiviteit $MIN poweroff &"; fi
  cat <<'EOF'
# Firefox start opnieuw als iemand het afsluit (maar nooit dubbel)
( while true; do
    pgrep -u kiosk -f firefox >/dev/null || firefox-esr "$URL"
    sleep 3
  done ) &
EOF
} > "$AS"

if [ "$KNOP" = ja ]; then
cat > /home/kiosk/.config/tint2/tint2rc <<'EOF'
# Achtergrond 1: de balk
rounded = 0
border_width = 0
border_sides = TBLR
background_color = #202020 100
border_color = #202020 100

# Achtergrond 2: de afsluitknop
rounded = 4
border_width = 1
border_sides = TBLR
background_color = #b00020 100
border_color = #ffffff 60

panel_items = PFC
panel_size = 100% 34
panel_position = bottom center horizontal
panel_margin = 0 0
panel_padding = 4 3 4
panel_background_id = 1
panel_dock = 0
wm_menu = 0
panel_layer = top
strut_policy = minimum
autohide = 0

button = new
button_text = Computer afsluiten
button_lclick_command = /usr/local/bin/kiosk-afsluiten
button_font = Sans Bold 11
button_font_color = #ffffff 100
button_padding = 12 4 0
button_background_id = 2
button_centered = 1

time1_format = %H:%M
time1_font = Sans 12
clock_font_color = #ffffff 100
clock_padding = 8 0
clock_background_id = 0
EOF
fi
chown -R kiosk:kiosk /home/kiosk/.config

if [ "$USB" = nee ]; then
  echo ">> USB-opslag blokkeren"
  cat > /etc/modprobe.d/kiosk-geen-usbopslag.conf <<'EOF'
# Verwijder dit bestand (en herstart) om usb-sticks weer toe te laten
install usb_storage /bin/false
install uas /bin/false
EOF
fi

echo ">> Reset bij elke start"
cat > /etc/systemd/system/kiosk-reset.service <<'EOF'
[Unit]
Description=Kiosk-profiel terugzetten
Before=display-manager.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kiosk-reset

[Install]
WantedBy=graphical.target
EOF
systemctl enable kiosk-reset.service
/usr/local/sbin/kiosk-opslaan

echo ">> Automatische updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo ">> Sneller opstarten"
for s in bluetooth cups cups-browsed ModemManager avahi-daemon; do
  systemctl disable "$s" 2>/dev/null || true
done
systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true
if [ -f /etc/default/grub ]; then
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
  update-grub || true
fi
systemctl set-default graphical.target

echo
echo "Klaar. Herstart nu met:  reboot"
echo "Later aanpassen:"
echo "  - startpagina wijzigen:  sudo kiosk-url https://nieuw-adres"
echo "  - Firefox-instellingen van kiosk wijzigen: meld kiosk af, log in als $ADMIN, typ  kiosk-beheer"
