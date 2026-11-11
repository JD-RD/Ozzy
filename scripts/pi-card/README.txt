us600-setup — de quoi monter le banc sur le Raspberry Pi 3B
==========================================================

Cette carte contient Raspberry Pi OS Lite 64-bit (Trixie, image du 2026-10-06),
préconfigurée par cloud-init (voir ../user-data et ../network-config).

Contenu de ce dossier
---------------------
  us600-linux.tar.gz   le pilote (branche us600-midi) : module, scripts, docs
  tr8-remap.tar.gz     le remappeur TR-8 -> SP-404MK2 (remap.py, unité systemd)
  install.sh           installe tout : paquets, module, service

Après le premier démarrage
--------------------------
cloud-init a déjà :
  - créé l'utilisateur pi (clé SSH de l'ordinateur de dev installée),
  - configuré le WiFi, le fuseau, la locale et le clavier,
  - installé les paquets MIDI de base,
  - extrait les deux dépôts dans /home/pi.

Il reste à construire le module et à installer le service :

    ssh pi@us600.local
    sudo sh /boot/firmware/us600-setup/install.sh

Puis, avec le US-600 et le TR-8 branchés :

    ~/us600-linux/scripts/midi-health.sh      # doit afficher 0 / healthy
    systemctl start tr8-remap                 # TR-8 -> US-600 -> SP-404MK2

Ce qu'il faut savoir (mesuré sur le banc, cf. us600-linux/docs/handoff.md)
-------------------------------------------------------------------------
  - Le pilote expose deux ports MIDI mais ne relie pas l'entrée à la sortie :
    c'est remap.py (ou `aconnect 20:0 20:0`) qui fait le pont.
  - Un débranchement USB ne réinitialise pas l'appareil (il a une alim
    externe) : le vrai cycle d'alimentation coupe l'alim ET l'USB.
  - L'abonnement ALSA sequencer ne survit pas à une veille : le hook
    systemd-sleep installé par install.sh redémarre le service au réveil.
  - Le Pi 3B ne fait que du WiFi 2,4 GHz, et ses ports USB partagent ~1,2 A :
    si l'appareil décroche, passer par un hub alimenté.

En cas de pépin au premier démarrage
------------------------------------
  /var/log/cloud-init-output.log    ce que cloud-init a fait
  /boot/firmware/user-data          le fichier de configuration (relire au besoin)
