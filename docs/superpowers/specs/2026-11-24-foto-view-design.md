# Foto-View: Vollbild, Fixfokus/Makro, Blitz mit LED, Galerie, Zoomrad

Stand: 2026-11-24. Status: Entwurf, Builder-Check eingearbeitet, wartet auf Freigabe durch Jo.

## Anlass

Die Serienkamera aus Phase S (PR 4, `ios/Legulus/Features/Camera/CameraView.swift`)
wird zur allgemeinen Foto-View. Sie soll mehrere Use Cases tragen:

1. Serienaufnahmen des Fundorts im Sample (jetzt),
2. später die Dokumentation von Pflanzenaufnahmen am Sample,
3. später Fotos zur Exkursion,
4. später Fotos für die Pflanzenbestimmung (Jo nennt PlantNet, `PROJECT_PLAN.md`
   §6.4 und Phase 9 nennen FloraIncognita; Phase 9 ist zurückgestellt).

Gebaut wird jetzt nur Use Case 1. Die View soll aber so geschnitten sein, dass
die anderen sie ohne Umbau verwenden können.

Jos Gerätetest hat gezeigt, dass die heutige Leiste nicht selbsterklärend ist
(drei Icons für Zoom und Fokus ohne sichtbaren Nutzen, „Fertig“ bricht als
„Fert / ig“ um). Dazu kommen zwei Anforderungen aus dem Feld:

- **Sehr nah:** Blütendetails, Fraßspuren, Käfer von 2 bis 3 mm, Abstand etwa
  2 cm.
- **Fokus im Vordergrund halten:** Bei Gräsern springt der Autofokus auf den
  Hintergrund statt auf den Halm. Abstand eher 10 bis 40 cm, das Problem ist
  das Springen, nicht die Nähe.

## Ausgangslage im Code

- `CameraView` (SwiftUI) mit `CameraSession`/`CameraCore`
  (`ios/Legulus/Features/Camera/CameraSession.swift`). Aufgerufen nur aus
  `SampleEditorView.swift:250` als `fullScreenCover`, Callback
  `onPhoto: (Data) throws -> Void`, `onDone`.
- Layout heute: `VStack` aus oberer Leiste (Blitz, Zoom −, Zoom +, Fokus Mitte,
  „Fertig“), `CameraPreview`, unterer Leiste (letztes Foto, Auslöser, Zähler).
- Gerät: virtuelle Mehrfachkamera bevorzugt (`builtInTripleCamera`,
  `builtInDualWideCamera`, …). Start auf dem Hauptobjektiv über den ersten
  Switch-over-Faktor. Die virtuelle Kamera schaltet heute selbständig aufs
  Ultraweitwinkel, wenn man nah herangeht.
- Fokus: Tippen setzt einmalig `.autoFocus` + `.autoExpose` am Punkt. Zoom:
  Pinch mit Obergrenze `maxZoom = 10`, Buttons in Schritten von 1,5.
- Blitz: `.auto`/`.off`, nur beim Auslösen.
- Fotos: Originaldatei der Kamera mit EXIF und GPS-Block aus `LocationProvider`
  (`PhotoGPSMetadata`). Speicherung im Sample über
  `SampleEditorViewModel.addCapturedPhoto(_:)` → `PhotoStorage.write` +
  `LocalPhoto` + `sync.kick()`.
- Galerie-Import existiert beim Nachtragen: `RetrospectiveEntryView` mit
  `PhotosPicker`, Umwandlung über `PhotoImportFormat.prepared(_:)` (HEIC → JPEG,
  Metadaten bleiben erhalten).
- Deployment Target iOS 17.

## Ziele

- Kamerabild über den ganzen Bildschirm, Bedienelemente liegen darüber.
- Ein Fixfokus-Modus (Blüten-Icon), der beide Feldfälle abdeckt: 2 cm Makro
  und „Fokus bleibt auf dem Halm“.
- Blitz mit drei Zuständen: Automatik, aus, LED-Dauerlicht.
- Foto aus der Galerie übernehmen, ohne die Kamera zu verlassen.
- Zoom per Pinch mit eingeblendetem Zoomrad wie in der Kamera-App.
- Letztes Foto und Anzahl unten links, Schließen an einer Stelle, die man im
  Serienfluss nicht versehentlich trifft.

## Nicht-Ziele

- Pflanzenaufnahmen, Exkursions-Fotos, PlantNet/FloraIncognita. Die View
  bekommt keine Parameter „auf Vorrat“ für diese Fälle.
- Frontkamera, Video, Live Photos, RAW/ProRAW, 48-MP-Modus.
- Belichtungskorrektur, Weißabgleich, manuelle ISO.
- Bildbearbeitung oder Zuschnitt nach der Aufnahme.

## Anti-Ziele

- Der Fixfokus-Modus darf nicht „fest auf nah“ sein, wenn das Gerät dort nicht
  scharf stellen kann. Ein Modus, der schärfer verspricht als der heutige
  Autofokus und es nicht ist, wäre schlechter als keiner.
- Die Kamera darf auf nichts warten (GPS, Speichern, Galerie-Import):
  Der Auslöser bleibt sofort wieder bereit, wie heute.
- Kein Bedienelement, das nur per Geste erreichbar ist. VoiceOver und
  Schaltersteuerung müssen alles können (`ACCESSIBILITY-IOS.md` §4).

## Ansätze für den Fixfokus-Modus

Diskutiert mit Jo am 2026-11-24:

- **A) Blüten-Knopf mit Fokusregler.** Knopf schaltet Autofokus ab, wechselt
  aufs Makro-Objektiv, stellt auf den Nahpunkt; ein Regler verschiebt die
  Schärfe-Entfernung. Vorhersehbar, einhändig etwas Gepfriggel.
- **B) Blüten-Knopf nur Makro, Fokus sperren per langem Druck** (wie
  „AE/AF-Sperre“ der Kamera-App). Schnell, trifft bei dünnem Halm vor
  kontrastreichem Hintergrund nicht immer.
- **C) A und B zusammen.** Langer Druck sperrt, Regler korrigiert fein.

**Jo hat C gewählt.**

## Entwurf

### Layout

```
                                   [Blüte] [Blitz]

                (Kamerabild, Vollbild)

                 [Fokusregler, nur in Fokus fest/Makro]
                   ( 0,5   1×   2   5 )  <- Objektivknöpfe / Zoomrad
 [letztes Foto (3)] [Galerie]   ( O )        [Fertig]
```

Nachtrag nach Jos Gerätetest (2026-11-24): Das X oben links klang nach
Abbruch und entfällt. „Fertig“ steht unten rechts (bei sehr großer Schrift
ein Haken). Das Vorschaubild ist kleiner und trägt die Anzahl innen; der
Auslöser steht in der Bildschirmmitte. Aktive Modi (Blitz-Automatik, LED,
Fokus fest, Makro) sind gelb (`AppColor.cameraActive`). Das Zoomrad folgt
der Kamera-App: dunkle Halbscheibe, Skala am Rand, Objektive als lange
Striche mit Zahl, aktueller Wert gelb unter dem Zeiger.

Zweiter Nachtrag (2026-11-24): Nur optischer Zoom, der Bereich endet am
längsten Objektiv (14 Pro: 3×; in den festen Stufen am Hauptausschnitt).
Der Zoom rastet bei 0,5 / 1 / 1,5 / 2,5 / 3 ein, der ganze Bereich passt
in eine halbe Bildschirmbreite Daumenweg. Alle Bedienelemente geben
haptisches Feedback.

- `CameraPreview` füllt den Bildschirm inkl. Safe Area (Aspect Fill).
  Bedienelemente liegen in der Safe Area darüber, auf einem leichten
  Verlauf/Scrim, damit weiße Icons auf hellem Bild lesbar bleiben (bei
  Increase Contrast kräftiger).
- Oben rechts: Blüten-Icon, rechts daneben (also ganz außen) das Blitz-Icon.
  Beides von Jo vorgegeben.
- Auslöser mittig unten (bleibt). Links neben dem Auslöser das Galerie-Icon
  (von Jo vorgegeben).
- Unten links: Vorschaubild des letzten Fotos mit der Anzahl
  (von Jo vorgegeben). *Claudes Entscheidung:* Anzahl als Badge bzw. Zeile
  am Vorschaubild; vor dem ersten Foto ein leerer Platzhalter mit „0“.
- Schließen: *Claudes Entscheidung, von Jo nicht bestätigt:* X-Knopf oben
  links, Beschriftung für VoiceOver „Schließen“. Begründung: weit weg von
  Auslöser, Galerie und Zoom, wird im Serienfluss nicht versehentlich
  getroffen; X braucht keine Breite und bricht nicht um.
- Die heutigen Knöpfe Zoom −, Zoom + und „Fokus Mitte“ entfallen. Ihre
  Aufgabe für VoiceOver übernehmen Zoomrad und Fokusregler (siehe A11y).
- Hoch- und Querformat: wie heute bleibt die Oberfläche im Hochformat, die
  Aufnahme wird über `RotationCoordinator` richtig gedreht.
  *Claudes Entscheidung:* Icons drehen sich im Querformat mit (wie die
  Kamera-App), das Layout bleibt.
- *Hinweis Vollbild:* Das Foto ist 4:3, der Bildschirm schmaler. Bei Aspect
  Fill sieht man links und rechts weniger, als auf dem Foto landet. Das ist
  der übliche Kompromiss (Kamera-App zeigt 4:3 mit Balken). Jo wünscht Vollbild,
  also Aspect Fill.

### Fixfokus-Modus (Blüten-Icon)

Nach dem Builder-Check mit Jo geklärt (2026-11-24): Die Blüte schaltet wie
der Blitz zyklisch durch Stufen, und beim Wechsel darf das Bild kurz schwarz
werden. Testgerät ist ein iPhone 14 Pro (Ultraweitwinkel mit Autofokus, Nahgrenze
etwa 2 cm; Hauptobjektiv etwa 20 cm), dort sind alle Stufen prüfbar.

Stufen: **Auto → Fokus fest → Makro → Auto.**

- **Auto** (Default): virtuelle Mehrfachkamera wie heute, Objektivwechsel
  automatisch, `.continuousAutoFocus`/`.continuousAutoExposure`.
- **Fokus fest** (Gräser, 10 bis 40 cm): physisches Hauptobjektiv,
  `setFocusModeLocked(lensPosition:)`, Start am Nahpunkt des Hauptobjektivs,
  Fokusregler sichtbar.
- **Makro** (Blütendetails, Fraß, Käfer, etwa 2 cm): physisches
  Ultraweitwinkel, `setFocusModeLocked(lensPosition:)` am Nahpunkt (0,0),
  digital auf etwa den 1×-Ausschnitt gezoomt (wie die Kamera-App beim Makro),
  Fokusregler sichtbar. Gibt es nur, wenn das Ultraweitwinkel nah scharf stellt;
  sonst fällt die Stufe weg und der Zyklus ist Auto → Fokus fest → Auto.

Warum der Objektivwechsel: Eine feste, frei wählbare Schärfe-Entfernung
(`isLockingFocusWithCustomLensPositionSupported`) gibt es laut Builder-Check
nur an den physischen Objektiven, die virtuelle Kamera lehnt sie ab (beim
ersten Gerätetest prüfen). Deshalb tauscht die Session für „Fokus fest“ und
„Makro“ den Input gegen das physische Objektiv und für Auto zurück gegen die
virtuelle Kamera. Dabei werden `RotationCoordinator` und Preview-Verbindung
neu aufgebaut; das Bild ist etwa 0,5 bis 1 s schwarz. Jo akzeptiert das.
Während des Wechsels ist der Auslöser gesperrt.

Erkennung über Fähigkeiten, nicht über das Modell: Makro gibt es, wenn
`.builtInUltraWideCamera` existiert, `isLockingFocusWithCustomLensPositionSupported`
meldet und `minimumFocusDistance` klein ist (*Claudes Entscheidung:* Grenze
≤ 50 mm; 11, 12, Basis-14/15 haben ein Ultraweitwinkel mit Fixfokus und fallen
heraus). „Fokus fest“ gibt es, wenn das Hauptobjektiv eine feste Linsenposition
erlaubt (praktisch immer).

Der **Fokusregler** steuert `lensPosition` von nah (links) nach fern (rechts),
live im Bild, Beschriftung „Nah“ / „Fern“ an den Enden. Die Belichtung bleibt
in beiden Fix-Stufen automatisch (Punkt Bildmitte).

**Langer Druck** aufs Bild, in jeder Stufe: Ist die Kamera in Auto, wechselt
sie zuerst auf das gerade aktive physische Objektiv (`activePrimaryConstituent`;
meist das Hauptobjektiv, nah dran ggf. das Ultraweitwinkel) und damit in
„Fokus fest“ bzw. „Makro“. Dann einmal `.autoFocus` und `.autoExpose` am
gedrückten Punkt, nach Abschluss (`isAdjustingFocus == false`) fest auf der
gefundenen `lensPosition`. Der Regler steht auf diesem Wert und stellt von dort
fein nach. Rückmeldung am Punkt (Rahmen + „Fokus fest“, für VoiceOver als
Ansage). *Claudes Entscheidung:* Der Wechsel vor dem Fokussieren (mit kurzem
Schwarzbild), damit der Regler danach sofort geht. Den Punkt rechnet die View
nach dem Wechsel neu in Gerätekoordinaten um.

**Kurzes Tippen:** in Auto Schärfe und Belichtung am Punkt, danach weiter
kontinuierlich. In den Fix-Stufen verschiebt ein Tippen nur den Belichtungspunkt,
der Fokus bleibt. *Claudes Entscheidung*, damit ein versehentliches Tippen den
eingestellten Halm nicht verliert.

Zurück nach **Auto**: virtuelle Kamera, Zoom zurück auf den Wert vor der
Fix-Stufe, Regler verschwindet.

Der Modus bleibt beim Schließen der Kamera nicht erhalten: jedes Öffnen
startet in Auto. *Claudes Entscheidung*; in einer Fix-Stufe zu öffnen und es nicht
zu merken, ergäbe unscharfe Serien.

*Hinweis zu heute:* Der heutige Code setzt nach dem Tippen `.autoFocus`
(einmalig), danach bleibt der Fokus stehen, bis man erneut tippt. Mit dieser
Änderung läuft Auto als `.continuousAutoFocus`, Tippen setzt den Punkt, und
nach einer deutlichen Bildänderung (`isSubjectAreaChangeMonitoringEnabled`)
fällt der Punkt zurück auf kontinuierlich in der Mitte.

### Blitz

Drei Zustände, ein Knopf, zyklisch: **Automatik → aus → LED → Automatik**.

- Automatik: `flashMode = .auto` beim Auslösen, Torch aus.
- Aus: `flashMode = .off`, Torch aus.
- LED: Torch an (`torchMode = .on`, Standardhelligkeit), `flashMode = .off`
  beim Auslösen. Das Licht leuchtet dauerhaft, solange LED gewählt ist und die
  Kamera offen ist; beim Schließen und beim Wechsel in den Hintergrund aus.
- Icons: `bolt.badge.automatic.fill`, `bolt.slash.fill`, `flashlight.on.fill`
  (o.ä.). VoiceOver-Label nennt den Zustand („Licht: automatischer Blitz“,
  „Licht: aus“, „Licht: LED-Dauerlicht“), Hint „Wechselt zum nächsten Modus“.
- Geräte ohne Torch/Blitz: Knopf ausgeblendet bzw. nur die verfügbaren
  Zustände.
- Wie heute startet jedes Öffnen in Automatik.

### Galerie

- Galerie-Icon links neben dem Auslöser öffnet den System-`PhotosPicker`
  (keine Foto-Berechtigung nötig, Picker läuft außerhalb des App-Prozesses).
- *Claudes Entscheidung:* Mehrfachauswahl erlaubt, Reihenfolge der Auswahl.
- Übernommen wird das Original wie beim Nachtragen:
  `PhotoImportFormat.prepared(_:)` (HEIC → JPEG, Metadaten bleiben), dann
  derselbe `onPhoto`-Callback wie bei einer Aufnahme. Ein EXIF-GPS des
  Galeriefotos bleibt wie es ist; es wird **kein** GPS der aktuellen Position
  ergänzt (das Foto wurde woanders gemacht).
- Galeriefotos zählen in die Anzahl und werden zum „letzten Foto“.
- Der Import läuft asynchron; die Kamera bleibt währenddessen bedienbar. Bei
  Fehlern dieselbe Fehlermeldung wie bei einer fehlgeschlagenen Aufnahme.
- Der Picker läuft außerhalb des Prozesses, die App bleibt aber im
  Vordergrund: iOS unterbricht die Session nicht. Während der Picker offen
  ist, schaltet die View das LED-Licht aus und pausiert die Session; danach
  läuft beides wieder.

### Zoom und Zoomrad

- Pinch zoomt wie heute (Obergrenze `maxZoom = 10`).
- Über dem Auslöser stehen Objektivknöpfe, abgeleitet aus den
  Switch-over-Faktoren der virtuellen Kamera, angezeigt relativ zum
  Hauptobjektiv: z.B. „0,5“, „1×“, „2“/„3“/„5“ je nach Gerät. Tippen springt
  auf das Objektiv. Der aktive Knopf zeigt den aktuellen Faktor („1,4×“).
- Beim Pinch und beim Ziehen über die Knöpfe erscheint das Zoomrad: ein
  Halbbogen mit Skala und Markierungen an den Objektivfaktoren, aktueller
  Wert in der Mitte. Ziehen auf dem Rad zoomt. Nach etwa 1,5 s ohne Berührung
  blendet es aus und die Knöpfe kommen zurück. Mit Reduce Motion ohne
  Animation, nur ein-/ausblenden.
- In den Fix-Stufen (physisches Objektiv): Zoom bleibt möglich (digital), die
  Objektivknöpfe sind ausgeblendet, das Rad zeigt nur den Faktor.
  *Claudes Entscheidung.*
- Zahlen nach Locale (Dezimalkomma).

*Claudes Entscheidung:* Das Rad wird als eigene SwiftUI-View gebaut
(`ZoomDial`), keine Fremdbibliothek. Es ist der aufwändigste Teil dieser
Arbeit.

### Schnittstelle der View

`CameraView(onPhoto: (Data) throws -> Void, onDone: () -> Void)` bleibt. Die
Galeriefotos laufen durch denselben `onPhoto`. Damit braucht `SampleEditorView`
keine Änderung, und spätere Use Cases geben ihren eigenen Callback mit.
*Claudes Entscheidung:* Kein Konfigurationsobjekt, bis ein zweiter Use Case
tatsächlich etwas anderes braucht.

### Accessibility

Gilt `ACCESSIBILITY-IOS.md` und `DESIGN-SYSTEM.md`.

- Alle Knöpfe ≥ 44 × 44 pt, Icons mit Label, Zustand als Value.
- Zoomrad und Objektivknöpfe: als ein Element mit
  `accessibilityAdjustableAction` (hoch/runter = nächste Stufe), Value
  „1,4-fach“. Ersetzt die bisherigen Zoom-Knöpfe für VoiceOver.
- Fokusregler: `Slider` bzw. adjustable mit Value „nah“ … „fern“ in Stufen.
- Langer Druck hat einen Weg ohne Geste: Blüten-Stufe + Regler. Das
  Blüten-Icon nennt die Stufe als Value („Fokus: automatisch“, „Fokus fest“,
  „Makro“), Hint „Wechselt zur nächsten Stufe“. Kurzes Tippen
  zum Scharfstellen: Auto-Modus fokussiert kontinuierlich, braucht also keinen
  Ersatz-Knopf mehr. *Claudes Entscheidung*, statt den „Fokus Mitte“-Knopf zu
  behalten.
- Dynamic Type: Zähler und Rad-Werte skalieren; bei AX-Größen dürfen Texte
  unter die Icons, sie werden nicht abgeschnitten.
- Statusansagen: „Fokus fest“, „Foto aufgenommen, 3 Fotos“, „LED an“.
- Snapshot-Tests der Bedienleisten (ohne Kamerabild) für Default, AX5, Dark
  sind wie bei den anderen Atoms Pflicht, sobald etwas in `Core/UI/` landet.

### Tests

- Unit-Tests für die reine Logik in `CameraSession` (statische Funktionen wie
  heute): Blitz-Zyklus, Objektivknöpfe aus Switch-over-Faktoren, Anzeige des
  Faktors relativ zum Hauptobjektiv, Abbildung Regler ↔ `lensPosition`,
  Stufenzyklus Auto/Fokus fest/Makro inkl. Wegfall von Makro ohne nahes
  Ultraweitwinkel, Erkennung aus Gerätefähigkeiten (über ein Protokoll, damit
  ohne Kamera testbar).
- Kamera, Makro, Torch und Picker lassen sich nur auf dem Gerät prüfen
  (Gerätetest durch Jo). Im Simulator bleibt der heutige Ersatzweg.

## Offen für den Builder

- Konkrete Icons (SF Symbols) für Blüte, LED, Galerie.
- Aufteilung in PRs (Vorschlag: 1. Vollbild + Layout + Schließen + Blitz/LED +
  Galerie, 2. Fixfokus mit Regler und langem Druck, 3. Zoomrad).
- Ob `ZoomDial` und Fokusregler als Atoms nach `Core/UI/` gehören (erst beim
  dritten Auftreten Pflicht).
- Eintrag als neue Phase in `PHASES.md` vor Beginn.
