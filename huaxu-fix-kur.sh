#!/usr/bin/env bash
# =============================================================================
#  HAVIT HUAXU-X1 2.4GHz DONGLE — TEK KULAK / BOZUK HACIM SORUNU KURULUMU
# =============================================================================
#
#  SORUN:
#    Dongle'in ALSA "PCM" donanim hacim kontrolu bozuk. PipeWire yazilim
#    hacmini %100'den dusurdugunde donanim degeri 0'a duser ve cihaz yedek
#    olarak MONO yola gecer -> ses yalnizca SOL kulaktan gelir.
#    Mikrofon slider'i oynatilinca stereo gecici olarak doner, cunku mixer
#    yeniden senkronize olur.
#
#  COZUM:
#    Ses seviyesini donanimdan tamamen yazilima tasimak.
#      1) WirePlapper -> api.alsa.soft-mixer  (donanim karistiricisini kapat)
#      2) systemd user servisi + udev kurali -> donanimi %100'de sabit tut
#
#  KURULUM:
#      ./huaxu-fix-kur.sh              # kullanici yetkisiyle
#      sudo ./huaxu-fix-kur.sh         # udev kuralini da otomatik kurar
#
#  GEREKSINIMLER: pipewire, wireplamber, alsa-lib, gcc
#    Arch: sudo pacman -S pipewire wireplamber pipewire-pulse alsa-lib gcc
# =============================================================================

set -euo pipefail

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[uyari]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[hata]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0) Kim olarak calisiyoruz?
#    sudo ile calistirildiginda $HOME root'unki olur ve systemctl --user
#    root'un oturumunu arar (orada PipeWire yok). Bu yuzden gercek kullanici
#    sudo ile bulunur ve tum komutlar onun adina calistirilir.
# ---------------------------------------------------------------------------
RUN_AS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
    RUN_AS_ROOT=1
    REAL_USER="${SUDO_USER:-${USER:-root}}"
    if [ "$REAL_USER" = "root" ]; then
        warn "root olarak calistirildin ve SUDO_USER yok."
        warn "Gercek kullaniciya ait dosyalar yazilacak; ev dizini $HOME olarak alindi."
        HOME_DIR="$HOME"
        REAL_UID=0
    else
        HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        REAL_UID="$(id -u "$REAL_USER")"
    fi
else
    REAL_USER="$(id -un)"
    HOME_DIR="$HOME"
    REAL_UID="$(id -u)"
fi

BIN="$HOME_DIR/.local/bin"
WP_CONF_DIR="$HOME_DIR/.config/wireplumber/wireplumber.conf.d"
SD_UNIT_DIR="$HOME_DIR/.config/systemd/user"
UDEV_RULE="/etc/udev/rules.d/91-huaxu-volume.rules"

# systemd --user komutlarini gercek kullanici adina calistir
as_user() {
    if [ "$RUN_AS_ROOT" -eq 1 ] && [ "$REAL_UID" -ne 0 ]; then
        sudo -u "$REAL_USER" env \
            HOME="$HOME_DIR" \
            XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
            "$@"
    else
        "$@"
    fi
}

echo
echo "==========================================================="
echo " Havit Huaxu-X1 tek kulak sorunu — kurulum basliyor"
echo "==========================================================="
[ "$RUN_AS_ROOT" -eq 1 ] && echo " root olarak calistirildi; kullanici: $REAL_USER ($HOME_DIR)"
echo

# ---------------------------------------------------------------------------
# 0b) On kosullar
# ---------------------------------------------------------------------------
command -v gcc >/dev/null 2>&1 || die "gcc yok. Kur: sudo pacman -S gcc"
as_user bash -c 'command -v pactl' >/dev/null 2>&1 \
    || die "pactl yok. Kur: sudo pacman -S pipewire-pulse"
[ -e /usr/include/alsa/asoundlib.h ] || die "alsa-lib basligi yok. Kur: sudo pacman -S alsa-lib"
say "On kosullar tamam"

mkdir -p "$BIN" "$WP_CONF_DIR" "$SD_UNIT_DIR"

# ---------------------------------------------------------------------------
# 1) setmixer — ALSA mixer kontrolunu dogrudan yazan kucuk C programi
# ---------------------------------------------------------------------------
say "1/5 setmixer kaynak kodu yaziliyor..."
cat > "$BIN/setmixer.c" <<'EOF_C'
/*
 * setmixer - ALSA karistirici kontrolunu dogrudan ayarlar.
 *
 * amixer, ayni isimde birden fazla "PCM" elemani bulunan bu cihazda
 * ("PCM",0 ve "PCM",1) kontrolu isimle bulamiyor. Bu program alsa-lib'yi
 * dogrudan kullanarak tum eslesen elemanlari ayarlar.
 *
 * Kullanim: setmixer hw:N [eleman] [yuzde]
 */
#include <alsa/asoundlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	const char *hw   = (argc > 1) ? argv[1] : "hw:3";
	const char *want = (argc > 2) ? argv[2] : "PCM";
	int          pct  = (argc > 3) ? atoi(argv[3]) : 100;

	snd_mixer_t *mixer;
	snd_mixer_elem_t *elem;
	snd_mixer_selem_id_t *sid;
	int found = 0, rc = 0;

	if (pct < 0 || pct > 100) {
		fprintf(stderr, "yuzde 0-100 araliginda olmali\n");
		return 2;
	}

	if (snd_mixer_open(&mixer, 0) < 0)            { perror("snd_mixer_open"); return 1; }
	if (snd_mixer_attach(mixer, hw) < 0)          { perror("snd_mixer_attach"); return 1; }
	if (snd_mixer_selem_register(mixer, NULL, NULL) < 0) { perror("snd_mixer_selem_register"); return 1; }
	if (snd_mixer_load(mixer) < 0)                { perror("snd_mixer_load"); return 1; }

	snd_mixer_selem_id_alloca(&sid);

	for (elem = snd_mixer_first_elem(mixer); elem; elem = snd_mixer_elem_next(elem)) {
		const char *name = snd_mixer_selem_get_name(elem);
		long pmin, pmax, v;

		if (!name || strcmp(name, want) != 0)
			continue;
		if (!snd_mixer_selem_has_playback_volume(elem))
			continue;

		snd_mixer_selem_get_playback_volume_range(elem, &pmin, &pmax);
		v = pmin + (long)((pmax - pmin) * pct / 100);

		snd_mixer_selem_set_playback_volume_all(elem, v);
		if (snd_mixer_selem_has_playback_switch(elem))
			snd_mixer_selem_set_playback_switch_all(elem, 1);

		printf("  %s,%d -> %ld/%ld (%%%d)  [on]\n",
		       name, snd_mixer_selem_get_index(elem), v, pmax, pct);
		found++;
	}

	if (!found) {
		fprintf(stderr, "'%s' kontrolu bulunamadi (%s)\n", want, hw);
		rc = 1;
	}

	snd_mixer_close(mixer);
	return rc;
}
EOF_C

say "2/5 setmixer derleniyor..."
gcc -O2 -Wall -o "$BIN/setmixer" "$BIN/setmixer.c" -lasound
say "derlendi: $BIN/setmixer"

# ---------------------------------------------------------------------------
# 2) huaxu-volume-fix — donanimi %100'de tutan betik
# ---------------------------------------------------------------------------
say "3/5 huaxu-volume-fix betigi yaziliyor..."
cat > "$BIN/huaxu-volume-fix" <<EOF_SH
#!/bin/sh
# Huaxu-X1 donanim hacim sabitleyici
#
# Bu dongle'in ALSA "PCM" kontrolu bozuk: 100 disindaki herhangi bir deger
# cihazi mono yola (tek kulak) dusuruyor. Donanimi %100'de sabit tutuyoruz;
# ses seviyesini PipeWire'in yazilim karistiricisi yonetiyor.
#
# Bu betik udev tarafindan dongle takildiginda calistirilir. udev "add" olayi,
# ALSA mixer arayuzu (/dev/snd/controlC3) hazir olmadan gelebilir; bu yuzden
# hazir olana kadar kisa araliklarla yeniden deniyoruz.
#
# Kullanim: huaxu-volume-fix [-q] [-d] [kart-no|cardN|hw:N]
#   -q  sessiz (udev icin)     -d  tanilama (elle calistirmak icin)

PATH=/usr/local/bin:/usr/bin:/bin
export PATH

SETMIXER="$BIN/setmixer"
LOG=/tmp/huaxu-volume-fix.log
QUIET=0
[ "\$1" = "-q" ] && QUIET=1 && shift
[ "\$1" = "-d" ] && QUIET=0 && shift

log() { [ "\$QUIET" = 1 ] || echo "\$(date '+%H:%M:%S') \$*" >>"\$LOG"; }

to_hw() {
    case "\$1" in
        hw:*)  echo "\$1" ;;
        card*) echo "hw:\${1#card}" ;;
        "")    echo "" ;;
        *)     echo "hw:\$1" ;;
    esac
}

hw=\$(to_hw "\$1")
log "cagrildi, kart='\$1' -> '\$hw'"

# Kart belirtilmediyse HuaxuX1'i ara
if [ -z "\$hw" ]; then
    for id in /proc/asound/card*/id; do
        [ "\$(cat "\$id" 2>/dev/null)" = "HuaxuX1" ] || continue
        card=\${id%/id}; card=\${card##*/}
        hw="hw:\${card#card}"
        log "otomatik bulundu: \$hw"
        break
    done
fi

[ -z "\$hw" ] && { log "HuaxuX1 bulunamadi, cikiliyor"; exit 0; }

# ALSA mixer arayuzu hazir olana kadar bekle (en fazla ~5 sn)
n=0
while [ \$n -lt 12 ]; do
    if "\$SETMIXER" "\$hw" PCM 100 >>"\$LOG" 2>&1; then
        log "basarili: \$hw PCM=%100"
        [ "\$QUIET" = 1 ] || tail -3 "\$LOG"
        exit 0
    fi
    log "deneme \$n basarisiz (hazir degil), tekrar..."
    n=\$((n + 1))
    sleep 0.4
done

log "HATA: \$hw mixer 5 sn icinde hazir olmadi"
exit 1
EOF_SH
chmod +x "$BIN/huaxu-volume-fix"
say "hazir: $BIN/huaxu-volume-fix"

# ---------------------------------------------------------------------------
# 3) WirePlapper — donanim karistiricisini yazilim hacmine cevir
# ---------------------------------------------------------------------------
say "4/5 WirePlapper yapilandirmasi yaziliyor..."
cat > "$WP_CONF_DIR/99-huaxu-software-volume.conf" <<'EOF_WP'
# Havit Huaxu-X1 2.4GHz dongle (XiiSound, USB 040b:0897)
#
# Bu dongle'in donanim hacim kontrolu bozuk. PipeWire yazilim hacmini
# %100'den dusurdugunde ALSA'nin stereo "PCM" kontrolu SIFIR'a duser ve
# cihaz yedek olarak mono yola gecerek sesi tek kulaktan verir.
#
# api.alsa.soft-mixer: donanim karistiricisini hacim/sessize alma icin
# tamamen devre disi birakir; tum hacim yazilimda yapilir ve donanim
# karistiricisi HICBIR ZAMAN degistirilmez (hep %100'de kalir).

monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "alsa_card.usb-XiiSound_Technology_Corporation_Huaxu-X1-00"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer          = true
        api.alsa.disable-mixer-path  = true
      }
    }
  }
]
EOF_WP
say "hazir: $WP_CONF_DIR/99-huaxu-software-volume.conf"

# ---------------------------------------------------------------------------
# 4) systemd user servisi — oturum acilisinda sabitler
# ---------------------------------------------------------------------------
cat > "$SD_UNIT_DIR/huaxu-volume-fix.service" <<'EOF_SD'
[Unit]
Description=Huaxu-X1 dongle donanim hacmini %100'de sabitle
After=pipewire.service wireplumber.service
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=__HOME__/.local/bin/huaxu-volume-fix

[Install]
WantedBy=default.target
EOF_SD
sed -i "s|__HOME__|$HOME_DIR|g" "$SD_UNIT_DIR/huaxu-volume-fix.service"

as_user systemctl --user daemon-reload
as_user systemctl --user enable --now huaxu-volume-fix.service
say "servis etkin: huaxu-volume-fix.service"

# ---------------------------------------------------------------------------
# 5) udev kurali — dongle her takildiginda otomatik calisir
# ---------------------------------------------------------------------------
say "5/5 udev kurali kuruluyor..."
RULE_CONTENT="ACTION==\"add\", SUBSYSTEM==\"sound\", KERNEL==\"card[0-9]*\", ATTRS{idVendor}==\"040b\", ATTRS{idProduct}==\"0897\", RUN+=\"$BIN/huaxu-volume-fix -q %k\""

if [ "$RUN_AS_ROOT" -eq 1 ]; then
    printf '%s\n' "$RULE_CONTENT" > "$UDEV_RULE"
    udevadm control --reload-rules 2>/dev/null || true
    say "udev kurali yazildi: $UDEV_RULE"
else
    warn "sudo gerekiyor — asagidaki komutu kendin calistir:"
    echo
    echo "    sudo tee $UDEV_RULE >/dev/null <<'RULE'"
    echo "    $RULE_CONTENT"
    echo "    RULE"
    echo "    sudo udevadm control --reload-rules"
    echo
fi

# ---------------------------------------------------------------------------
# Root olarak calistirildiysa dosya sahipliklerini duzelt
# ---------------------------------------------------------------------------
if [ "$RUN_AS_ROOT" -eq 1 ] && [ "$REAL_UID" -ne 0 ]; then
    say "dosya sahiplikleri $REAL_USER yapiliyor..."
    chown -R "$REAL_USER" "$HOME_DIR/.local/bin" \
                     "$WP_CONF_DIR/99-huaxu-software-volume.conf" \
                     "$SD_UNIT_DIR/huaxu-volume-fix.service"
fi

# ---------------------------------------------------------------------------
# Uygula + dogrula
# ---------------------------------------------------------------------------
say "WirePlapper yeniden baslatiliyor..."
as_user systemctl --user restart wireplumber.service 2>/dev/null \
    || warn "wireplapper servisi bulunamadi"
sleep 4

"$BIN/huaxu-volume-fix" || warn "HuaxuX1 bulunamadi (dongle takili mi?)"

echo
echo "==========================================================="
echo "  Kurulum tamam. Dogrulama:"
echo "==========================================================="
for f in /proc/asound/card*/id; do
    [ "$(cat "$f" 2>/dev/null)" = "HuaxuX1" ] || continue
    c=${f%/id}; c=${c##*/}
    amixer -c "${c#card}" scontents 2>/dev/null | sed -n '1,8p' | sed 's/^/  /' || true
    break
done
as_user pactl list sinks 2>/dev/null | grep -E '^	Name:|Flags:' | paste - - \
    | grep -i huaxu | sed 's/^/  /' || true
echo
echo "  Beklenen: donanim PCM %100  |  bayrakta HW_VOLUME_CTRL OLMAMALI"
echo "  Dongle'i cikarip tak — ses otomatik duzelmelidir."
echo
echo "  Gunluk tanilama: $BIN/huaxu-volume-fix -d"
echo "  Log dosyasi:     /tmp/huaxu-volume-fix.log"
echo