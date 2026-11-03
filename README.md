# Tide 🌊

Un écran de verrouillage pour macOS qui affiche ce que tu écoutes sur **Spotify** :
la pochette agrandie en fond, la pochette nette au centre, la grosse horloge et un
lecteur en **Liquid Glass** (lecture/pause, précédent, suivant, barre de progression).

## Installation

Il faut un Mac avec Xcode (ou les Command Line Tools) installé.

```bash
git clone <ce-repo> && cd Vibed
./build.sh
open build/Tide.app
```

Au premier lancement, macOS demande l'autorisation de contrôler **Spotify** : accepte.
(Si tu as refusé : Réglages Système → Confidentialité et sécurité → Automatisation → Tide → Spotify.)

## Utilisation

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

## Structure

```
Sources/Tide/
  TideApp.swift            app barre des menus, raccourci, verrouillage auto
  LockScreenManager.swift  fenêtres plein écran + Touch ID
  LockScreenView.swift     l'écran : fond, horloge, pochette, lecteur
  SpotifyController.swift  lecture/pilotage de Spotify via AppleScript
  Glass.swift              effet Liquid Glass (natif macOS 26 + imitation)
  MenuContent.swift        panneau de la barre des menus
  HotKey.swift             raccourci global ⌃⌥⌘L
```
