# ModHub upload: Banana Regrow

What to enter in the GIANTS ModHub upload form for this mod. Each text box below has a copy button on GitHub.

<img src="icon_512.png" alt="Mod icon" width="160">

**Mod Icon (512x512):** [`icon_512.png`](icon_512.png)

| Field | Value |
|-------|-------|
| Title English | Banana Regrow |
| Title German | Banana Regrow |
| Title French | Banana Regrow |
| Version | `1` `2` `5` `1` |
| Author | DTM Mods, Fennell |
| Manufacturer | Lizard |
| Category 1 | Gameplay |
| Category 2 | Not Set |
| Category 3 | Not Set |

## Title English
```text
Banana Regrow
```

## Title German
```text
Banana Regrow
```

## Title French
```text
Banana Regrow
```

## Description English
```text
Banana Regrow harvests and cuts back a whole banana plantation at once, instead of one machete swing per plant. Ripe plants are harvested the way your machete does it, the bananas go straight into your farm's nearest washing station, and the other plants are cut back so they regrow from the next month. Needs the banana plantations of the Beans & Alpacas Pack.

- Harvest: ripe plants in the area are harvested, no bunches to carry or hook on the rail
- Cut back: harvested, half-cut and withered plants regrow from the next month; growing plants are left alone
- Only plants on your own farm's land are touched
- Works in multiplayer (the server does the work)
- Keeps the washing station's "Manage workers" button visible when other mods add menu buttons

How to use: carry the machete. Construction menu (Shift + P) > Landscaping > Banana Regrow: click two corners of the area, then click again. Right click a plantation to do all of it. On foot: Left Alt + K marks a corner, Left Alt + L cuts back, Left Alt + J clears the area.

Changelog 1.2.5.0:
- Harvest and cut back in one click; the bananas go straight into the washing station
- Harvest done by the server in multiplayer; brCollect console command for bunches left on the ground
- Messages only on your own screen
- Extra menu button slots so "Manage workers" stays visible
```

## Description German
```text
Banana Regrow erntet eine ganze Bananenplantage auf einmal und schneidet sie zurück, statt jede Pflanze einzeln mit der Machete zu bearbeiten. Reife Pflanzen werden geerntet wie mit der Machete, die Bananen kommen direkt in die nächste Waschstation deines Hofs, und die übrigen Pflanzen werden zurückgeschnitten und wachsen ab dem nächsten Monat nach. Benötigt die Bananenplantagen des Beans & Alpacas Packs.

- Ernten: reife Pflanzen in der Fläche werden geerntet, kein Tragen oder Einhängen der Büschel
- Zurückschneiden: geerntete, halb geschnittene und verdorrte Pflanzen wachsen ab dem nächsten Monat nach; wachsende Pflanzen bleiben unberührt
- Nur Pflanzen auf Land des eigenen Hofs werden bearbeitet
- Funktioniert im Multiplayer (der Server erledigt die Arbeit)
- Die Taste "Arbeiter verwalten" der Waschstation bleibt sichtbar, wenn andere Mods Menütasten hinzufügen

Bedienung: Machete mitnehmen. Baumenü (Umschalt + P) > Landschaftsbau > Banana Regrow: zwei Ecken der Fläche anklicken, dann noch einmal klicken. Rechtsklick auf eine Plantage bearbeitet sie ganz. Zu Fuß: Links Alt + K markiert eine Ecke, Links Alt + L schneidet zurück, Links Alt + J löscht die Fläche.

Changelog 1.2.5.0:
- Ernten und Zurückschneiden mit einem Klick; die Bananen kommen direkt in die Waschstation
- Im Multiplayer erntet der Server; Konsolenbefehl brCollect für Büschel am Boden
- Meldungen nur auf dem eigenen Bildschirm
- Zusätzliche Menütasten-Plätze, damit "Arbeiter verwalten" sichtbar bleibt
```

## Description French
```text
Banana Regrow récolte et recèpe toute une bananeraie d'un coup, au lieu d'un coup de machette par plant. Les plants mûrs sont récoltés comme avec la machette, les bananes vont directement dans la station de lavage la plus proche de votre ferme, et les autres plants sont recépés pour repousser dès le mois suivant. Nécessite les bananeraies du Beans & Alpacas Pack.

- Récolte : les plants mûrs de la zone sont récoltés, sans régimes à porter ni à accrocher au rail
- Recépage : les plants récoltés, à moitié coupés et fanés repoussent dès le mois suivant ; les plants en croissance ne sont pas touchés
- Seuls les plants sur les terres de votre ferme sont concernés
- Fonctionne en multijoueur (le serveur fait le travail)
- Le bouton « Gérer les ouvriers » de la station de lavage reste visible quand d'autres mods ajoutent des boutons

Utilisation : prenez la machette. Menu de construction (Maj + P) > Aménagement paysager > Banana Regrow : cliquez deux coins de la zone, puis cliquez encore. Clic droit sur une bananeraie pour la traiter entière. À pied : Alt gauche + K marque un coin, Alt gauche + L recèpe, Alt gauche + J efface la zone.

Changelog 1.2.5.0 :
- Récolte et recépage en un clic ; les bananes vont directement dans la station de lavage
- En multijoueur, le serveur récolte ; commande console brCollect pour les régimes restés au sol
- Messages uniquement sur votre écran
- Emplacements de boutons en plus pour que « Gérer les ouvriers » reste visible
```

## Before uploading

- The icon was upscaled from 256 px; a sharper 512 px original would look better on ModHub.
- The mod has no French at all: the in-game texts exist in English and German only, and modDesc.xml has only English and German descriptions. The French text here does not add translations to the mod.
- It ships research and debug console commands for admins (`brProbe`, `brTrace`, `brRipen`, which makes plants ripe, and `brDebug`; `scripts/BananaRegrowProbe.lua`). Your decision whether they stay in a ModHub build.
- Harvesting is confirmed in single player but not yet on a dedicated server.
