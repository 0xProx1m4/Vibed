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

Tide propose en plus son propre écran de verrouillage (`⌃⌥⌘L`), entièrement personnalisé.

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
barre ne s'affiche simplement plus (le reste continue de marcher) : désactive‑la dans le menu.

Boutons de la barre : **♥** (ajoute le morceau à tes Titres likés via le raccourci Spotify ⌥⇧B —
nécessite l'autorisation Accessibilité, bouton dans le menu 🌊), **⏮ ⏯ ⏭**, et **💻 sortie audio**
(haut‑parleurs du Mac, casque Bluetooth, AirPlay…). Spotify ne permettant pas de savoir de
l'extérieur si un morceau est déjà liké, le cœur ne reflète que ce que tu as fait depuis Tide.

## Réglages (icône 🌊 dans la barre des menus)

- **Pochette sur l'écran verrouillé** : active ou désactive le mode écran de verrouillage macOS.
- **Taille / Position** : ajuste la pochette pour qu'elle tombe bien entre l'horloge et le lecteur de macOS.

Si le lecteur de macOS n'apparaît pas sur l'écran de verrouillage : Réglages Système ›
Écran verrouillé, et vérifie que l'affichage des contrôles multimédia est autorisé.

Limites : le fond d'écran n'est changé que sur l'Espace (bureau) actif de chaque écran.
Les fonds d'écran animés d'Apple (« aériens ») peuvent ne pas être restaurés à l'identique.

## Écran Tide (optionnel)



| Action | Comment |
|---|---|
| Verrouiller | `⌃⌥⌘L`, ou icône 🌊 dans la barre des menus → *Verrouiller maintenant* |
| Lecture / pause | `Espace` ou bouton ⏯ |
| Morceau précédent / suivant | `←` / `→` ou boutons |
| Avancer dans le morceau | glisser sur la barre de progression |
| Déverrouiller | clic sur le fond ou n'importe quelle autre touche → Touch ID / mot de passe du Mac |

Dans le menu 🌊 : verrouillage auto après X minutes d'inactivité, et verrouillage quand l'écran s'éteint.

## Bon à savoir

- **Liquid Glass** : sur macOS 26 (Tahoe), compilé avec Xcode 26, Tide utilise le vrai
  matériau `glassEffect`. Sur les versions plus anciennes, il l'imite (flou + reflets).
- macOS ne laisse aucune app tierce dessiner sur le *vrai* écran de verrouillage du système.
  Tide affiche donc **son propre écran**, par‑dessus tout (Dock, barre des menus,
  ⌘Tab et Forcer à quitter sont bloqués), et ne le retire qu'avec ton Touch ID ou ton mot de passe.
  Ça ne remplace pas totalement le verrouillage système (ex. un redémarrage forcé le contourne) :
  pour une sécurité maximale, garde aussi le verrouillage macOS activé.
- Si « Verrouiller quand l'écran s'éteint » est activé et que macOS demande déjà le mot de passe
  à la sortie de veille, tu devras t'authentifier deux fois. Dans ce cas, mets un délai dans
  Réglages Système → Écran verrouillé, ou désactive l'option.
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
  TideApp.swift            app barre des menus, raccourci, verrouillage auto
  WallpaperManager.swift   pochette → fond d'écran (vrai écran de verrouillage)
  WallpaperRenderer.swift  génération de l'image de fond
  LockScreenBar.swift      barre Liquid Glass sur le vrai écran verrouillé
  AudioOutputs.swift       liste et choix de la sortie audio (CoreAudio)
  SkyLight.swift           accès privé au serveur de fenêtres (au-dessus du verrouillage)
  LockScreenManager.swift  fenêtres plein écran + Touch ID
  LockScreenView.swift     l'écran : fond, horloge, pochette, lecteur
  SpotifyController.swift  lecture/pilotage de Spotify via AppleScript
  Glass.swift              effet Liquid Glass (natif macOS 26 + imitation)
  MenuContent.swift        panneau de la barre des menus
  HotKey.swift             raccourci global ⌃⌥⌘L
```
