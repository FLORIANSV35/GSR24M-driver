# Test de référence sur le vieux MacBook Pro avec le pilote A&H d'origine

But : savoir si, à 96 kHz, la GS-R24M joue elle-même un son à la bonne hauteur avec le pilote d'origine.
Sur le M1 avec notre logiciel, un 1 kHz envoyé à 96 kHz ressort à 2 kHz (à 48 kHz tout est correct).

## Matériel
- Le vieux MacBook Pro (Intel, macOS 10.12 ou plus ancien), pilote A&H 4.3.1 installé, console connectée en FireWire.
- Les trois fichiers de ce dossier : `tone_1000Hz_96k.wav`, `tone_1000Hz_48k.wav`, `measure_freq.py`.

## Console
- Comme pour nos tests : les retours FireWire 1 à 24 envoyés au master L/R (qui revient sur les canaux 31 et 32 de la carte).
- Baissez les enceintes avant de commencer. Les fichiers sont à -20 dBFS.

## Étapes
1. Ouvrez le panneau de contrôle A&H (ou Réglages Audio MIDI) et mettez la carte à **96000 Hz**. Vérifiez qu'elle est verrouillée.
2. Jouez `tone_1000Hz_96k.wav` vers la sortie A&H (QuickTime Player, ou un logiciel de musique réglé sur la carte A&H en 96 kHz). Le fichier joue un 1 kHz sur les sorties 1 et 2.
3. Pendant la lecture, enregistrez les canaux 31 et 32 de la carte A&H, avec un logiciel de musique réglé à 96 kHz (10 secondes suffisent). Exportez en WAV.
4. Lancez : `python measure_freq.py enregistrement.wav`
5. Refaites avec la carte à **48000 Hz** et `tone_1000Hz_48k.wav` (même méthode).

## Ce qu'on cherche
- 48 kHz : le script doit afficher environ 1000 Hz.
- 96 kHz : 1000 Hz signifie que le pilote d'origine joue juste, donc notre flux diffère et on cherchera encore.
  2000 Hz signifie que la carte ou la console double aussi avec le pilote d'origine : rien à corriger chez nous.
- Notez aussi le niveau affiché.
