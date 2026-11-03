# Tide 🌊

Affiche ce que tu écoutes sur **Spotify** sur le **vrai écran de verrouillage de macOS** :
la pochette agrandie et floutée en fond, la pochette nette au centre, et par‑dessus
l'horloge et le lecteur Liquid Glass natifs de macOS.

### Comment ça marche

macOS ne laisse aucune app dessiner directement sur l'écran de verrouillage. Mais depuis
Sonoma, cet écran utilise **le fond d'écran du bureau**, et macOS y affiche lui‑même
l'horloge et le lecteur « En lecture » (cœur, ⏮ ⏸ ⏭, AirPlay) pour Spotify.

Tide prépare donc, à chaque morceau, une image (pochette floutée + pochette au centre) et
**ne l'applique qu'au moment où tu verrouilles le Mac**. Dès que tu déverrouilles, ton fond
d'écran d'origine revient exactement comme avant (y compris les fonds aériens/dynamiques) :
sur ton bureau, rien ne change. Le lecteur natif de macOS sur l'écran verrouillé permet de
mettre en pause, passer au morceau suivant et voir la barre de durée.

## Installation

Il faut un Mac avec Xcode (ou les Command Line Tools) installé.

```bash
git clone <ce-repo> && cd Vibed
./build.sh
open build/Tide.app
```

Au premier lancement, macOS demande l'autorisation de contrôler **Spotify** : accepte.
(Si tu as refusé : Réglages Système → Confidentialité et sécurité → Automatisation → Tide → Spotify.)

### Barre Liquid Glass sur l'écran verrouillé

Tide affiche aussi sa propre barre de lecture (titre, barre de durée déplaçable, ⏮ ⏯ ⏭) sous
la pochette, directement sur le vrai écran verrouillé. macOS ne prévoit aucune API officielle
pour ça : Tide passe par une fonction privée du serveur de fenêtres (SkyLight), la même
technique que d'autres apps de la barre des menus. Si une mise à jour de macOS la casse, la
barre ne s'affiche simplement plus (le reste continue de marcher).

Boutons de la barre : **♥**, **⏮ ⏯ ⏭**, et **💻 sortie audio** (haut‑parleurs du Mac, casque
Bluetooth, AirPlay…).

#### Le ♥ (Titres likés)

Pour que le cœur soit **rempli quand le morceau est déjà liké**, Tide doit lire ta bibliothèque
via l'API web de Spotify (c'est la seule source de cette info). Une seule fois :

1. Va sur [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → **Create app**.
2. Redirect URI : `http://127.0.0.1:43821/callback` — coche **Web API** — enregistre.
3. Copie le **Client ID** dans le menu 🌊 › Compte Spotify, puis **Se connecter à Spotify**.

Connexion OAuth « PKCE » : aucun mot de passe ni secret n'est stocké ; seul un jeton de
renouvellement est gardé dans `~/Library/Application Support/Tide/spotify-token` (lisible par
toi seul). Sans compte connecté, le ♥ envoie le raccourci Spotify ⌥⇧B (autorisation
Accessibilité), mais Tide ne peut alors pas savoir si un morceau est déjà liké.

## Réglages (masqués pour l'instant)

Ces réglages sont cachés du menu 🌊 : passe `showsCustomization` à `true` dans
`Sources/Tide/MenuContent.swift` et recompile pour les retrouver.

- **Pochette sur l'écran verrouillé** : active ou désactive le mode écran de verrouillage macOS.
- **Taille / Position** : ajuste la pochette pour qu'elle tombe bien entre l'horloge et le lecteur de macOS.

Si le lecteur de macOS n'apparaît pas sur l'écran de verrouillage : Réglages Système ›
Écran verrouillé, et vérifie que l'affichage des contrôles multimédia est autorisé.

Limites : le fond d'écran n'est changé que sur l'Espace (bureau) actif de chaque écran.
Les fonds d'écran animés d'Apple (« aériens ») peuvent ne pas être restaurés à l'identique.

## Bon à savoir

- **Liquid Glass** : sur macOS 26 (Tahoe), compilé avec Xcode 26, Tide utilise le vrai
  matériau `glassEffect`. Sur les versions plus anciennes, il l'imite (flou + reflets).
- Comme l'app est signée en ad‑hoc, macOS peut redemander l'autorisation Spotify après chaque rebuild.

## Dépannage : « Rien en lecture »

1. Ouvre le menu 🌊 : s'il affiche un avertissement orange, clique sur le bouton proposé.
2. Vérifie Réglages Système › Confidentialité et sécurité › Automatisation › **Tide** › **Spotify** coché.
3. Si rien n'apparaît ou si ça bloque après un rebuild, remets l'autorisation à zéro puis relance Tide :

   ```bash
   tccutil reset AppleEvents app.tide.lockscreen
   ```

Même sans cette autorisation, Tide affiche le morceau dès que tu changes de piste ou que tu
fais play/pause (Spotify diffuse l'info), mais les boutons ne fonctionneront pas.

## Structure

```
Sources/Tide/
  TideApp.swift            app barre des menus
  WallpaperManager.swift   pochette → fond d'écran (vrai écran de verrouillage)
  WallpaperRenderer.swift  génération de l'image de fond
  LockScreenBar.swift      barre Liquid Glass sur le vrai écran verrouillé
  SpotifyWebAPI.swift      connexion au compte Spotify (♥ et état liké)
  AudioOutputs.swift       liste et choix de la sortie audio (CoreAudio)
  SkyLight.swift           accès privé au serveur de fenêtres (au-dessus du verrouillage)
  SpotifyController.swift  lecture/pilotage de Spotify via AppleScript
  Glass.swift              effet Liquid Glass (natif macOS 26 + imitation)
  MenuContent.swift        panneau de la barre des menus
```
