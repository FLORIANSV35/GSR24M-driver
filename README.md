# GSR24M — pilote macOS pour la carte FireWire Allen & Heath GS-R24

Fait fonctionner la carte FireWire **Allen & Heath GS-R24** (console GS-R24M) sur un Mac **Apple silicon** sous **macOS 13 ou plus**, sans extension noyau : une application, un démon et un plug-in audio CoreAudio.

*English: macOS driver for the Allen & Heath GS-R24 FireWire card (Apple silicon, no kernel extension): app + daemon + CoreAudio plug-in. Not affiliated with Allen & Heath.*

## Installer

1. Télécharger `GSR24M-x.y.z.pkg` dans les [Releases](../../releases/latest) (l'application peut aussi le faire : *Info → Rechercher une mise à jour*).
2. Ouvrir le .pkg. L'installateur n'est pas signé par un compte développeur Apple : si macOS le refuse, clic droit sur le fichier → *Ouvrir*.
3. À la fin de l'installation le son du Mac s'arrête quelques secondes (redémarrage de CoreAudio).

Ce qui est installé : `/Applications/GSR24M.app`, le démon `/usr/local/libexec/gsrd` (LaunchDaemon `com.gsr24m.gsrd`), le plug-in `/Library/Audio/Plug-Ins/HAL/GSR24M.driver`.
Désinstaller : `sudo /usr/local/libexec/gsr24m-uninstall.sh` (`--purge` efface aussi les noms de canaux gardés par le démon).

## Ce que ça fait

- Appareil CoreAudio « GS-R24M FireWire » : 32 entrées et 32 sorties, 44,1 / 48 / 88,2 / 96 kHz, 24 bits.
- Noms de canaux modifiables dans l'application, repris par Audio MIDI Setup et les logiciels audio.
- Changement de fréquence, de source de synchronisation (Internal / Word Clock) et de mode de latence depuis l'application.
- Latence aller-retour dans la console mesurée : 2,2 ms (48 kHz) ; latence de sortie vue par un logiciel : avance de lecture (40 à 300 ms selon le mode) + 3 ms.

## Limites connues

- Testé sur une seule carte (GS-R24, firmware DICE 1.0.12.0, A&H 4.2.0) avec un MacBook Pro M1 Pro, via adaptateurs Thunderbolt → FireWire. Pas de ZED-R16 testé.
- Pas de MIDI pour l'instant. Pas de Word Clock externe testé (retour automatique sur l'horloge interne s'il n'y a pas de signal).
- Les logiciels qui ouvrent la carte pendant que le démon tourne (comme l'outil `dicedump`) font réinitialiser le bus : le son s'arrête environ 3 s.
- Apple silicon uniquement. Le plug-in et le démon sont signés *ad hoc*.
- Le démon n'a pas de contrôle d'accès : tout processus local peut changer fréquence et noms.

## Règles du projet

Aucun firmware n'est jamais écrit dans la carte. Seuls des registres volatils sont modifiés (propriétaire, horloge, activation et canaux des flux) et remis en place à l'arrêt. Le firmware, les installateurs et le code du fabricant ne font pas partie de ce dépôt.

## Construire depuis les sources

Outils : Command Line Tools (pas besoin de Xcode). `./build_release.sh` construit le démon, le plug-in, l'application, lance les tests et produit `dist/GSR24M-<version>.pkg` et sa somme SHA-256. Version : fichier `VERSION`.

| Dossier | Contenu |
| --- | --- |
| `gsrd/` | démon (moteur FireWire isochrone, anneaux partagés, XPC) |
| `hal/` | plug-in AudioServerPlugIn, simulateur et bancs d'essai |
| `GSRCore/` | paquet Swift : modèles testés et application SwiftUI |
| `dicedump/` | lecteur de registres DICE en lecture seule |
| `gsrcap/` | outils d'essai en ligne de commande (capture, lecture, tenue, charge) |
| `installer/` | scripts et textes de l'installateur |
| `re/NOTES.md`, `ARCHITECTURE.md` | mesures, décisions, conception |

## Licence

Apache-2.0 (voir `LICENSE`). Les connaissances sur le protocole DICE viennent en partie du projet [ASFireWire](https://github.com/mrmidi/ASFireWire) (Apache-2.0).
