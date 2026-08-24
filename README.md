# Windows Makeover 0.2.0-beta

Ein vorsichtiges PowerShell-Tool für die erste Hilfe bei langsamen Windows-PCs. Es ist für Besuche bei Familie und Freunden ausgelegt: zuerst transparent diagnostizieren, danach nur klar begrenzte Maßnahmen anbieten.

> **Beta-Status:** Diagnose, JSON-Berichte und der geführte Bereinigungsablauf sind implementiert und automatisiert getestet. Die Beta sollte vor einem breiten Einsatz noch auf verschiedenen echten Windows-7- bis Windows-11-PCs geprüft werden. Sie ersetzt keine Datensicherung und keine professionelle Fehlerdiagnose bei Hardwaredefekten, Malware oder Laufwerksfehlern.

## Was das Tool macht

### Phase 1: Nur Diagnose

`Diagnose` verändert **nichts**. Sie sammelt und speichert einen JSON-Bericht mit:

- Windows-Version, Rechnername und Admin-Status
- freiem Platz auf dem Systemlaufwerk
- Größe und Anzahl der Dateien im Temp-Ordner des aktuellen Benutzers
- Größe des Papierkorbs des aktuellen Benutzers
- Anzahl und Details der Autostart-Einträge
- ausstehendem Windows-Neustart und Laufzeit seit dem letzten Start
- verfügbarem Arbeitsspeicher sowie den fünf aktuell größten Speicherverbrauchern
- einer standardmäßig fünfsekündigen Kurzprobe für CPU, Systemdatenträger und Commit-Auslastung samt auffälligen CPU- und I/O-Prozessen
- Typ, Modell und Windows-Grundzustand des Systemlaufwerks
- automatischer oder manueller Verwaltung der Auslagerungsdatei
- registriertem Virenschutz und, soweit verfügbar, Defender-Echtzeitschutz
- Alter des letzten über `Win32_QuickFixEngineering` erkannten Hotfixes
- Windows-Produktfamilie und allgemeinem Supportstatus
- aktivem Energiesparplan, soweit Windows ihn auslesen lässt

Die Konsole zeigt eine verständliche Kurzbewertung. Der vollständige Bericht enthält zusätzlich einen versionsabhängigen manuellen Leitfaden für Autostart, Updates, Malware-Scan, Laufwerksoptimierung, Energiemodus, visuelle Effekte, Clean-Boot-Test, Systemdateireparatur, Dateisystemprüfung und Wiederherstellung. Diese Schritte werden nicht automatisch ausgeführt.

### Phase 2: Geführte Maßnahmen

`Remediate` akzeptiert nur einen aktuellen Bericht vom selben PC und demselben Windows-Benutzer. Der Bericht darf maximal 30 Tage alt sein und höchstens fünf Minuten in der Zukunft liegen. Ältere Berichtsformate müssen durch eine neue Diagnose ersetzt werden.

Vor der Auswahl misst das Tool Temp-Ordner und Papierkorb erneut. Editierte Empfehlungen oder Größenangaben aus der JSON-Datei lösen keine Maßnahme aus. Für jede aktuell angebotene Aktion zeigt das Tool Umfang und Speichergewinn an und fordert eine eigene Bestätigung an.

| Aktion | Wann angeboten | Tatsächlicher Umfang |
|---|---|---|
| `CleanTempFiles` | Mehr als 500 MB im Benutzer-Temp-Ordner | Löscht nur Dateien im aktuellen Benutzer-Temp-Ordner. Gesperrte Dateien werden übersprungen und als Fehler gezählt. |
| `CleanRecycleBin` | Mehr als 500 MB im Papierkorb | Leert den Papierkorb des aktuellen Benutzers auf lokalen Laufwerken. Dateien sind danach nicht mehr über den Papierkorb wiederherstellbar. |

Autostart, Updates, Virenschutz, Auslagerungsdatei, Energiesparplan, visuelle Effekte, Clean Boot, Laufwerksoptimierung, Systemreparatur und Wiederherstellung werden nur als **Hinweise** oder manuelle Prüfschritte ausgegeben. Das Tool ändert sie nicht automatisch.

Jeder tatsächlich gestartete Bereinigungsschritt wird zusätzlich im gleichen Ordner wie der verwendete Diagnosebericht als `remediation-audit-YYYYMMDD.jsonl` protokolliert. Jeder Eintrag enthält Zeitstempel, verwendeten Bericht, Aktion, Ergebnis sowie entfernte und fehlgeschlagene Elemente. Ein `-WhatIf`-Lauf erzeugt bewusst keinen Audit-Eintrag, weil dabei keine Bereinigung ausgeführt wird.

## Voraussetzungen

- Windows 7 SP1, Windows 8/8.1, Windows 10 oder Windows 11
- Windows PowerShell 5.1 oder PowerShell 7+
- kein Administratorzugang für die vorgesehenen Maßnahmen erforderlich

Auf älteren Windows-Versionen können einzelne moderne Storage- oder Defender-Schnittstellen fehlen. Die Diagnose markiert diese Probe dann als nicht verfügbar und läuft mit den übrigen Daten weiter. Für Windows 7 muss Windows PowerShell 5.1 bereits installiert sein.

## Schnellstart

1. Repository auf den betroffenen PC kopieren oder klonen.
2. PowerShell im Projektordner öffnen.
3. Diagnose starten:

```powershell
.\windows-makeover.ps1 -Mode Diagnose
```

Der Report wird standardmäßig nach `reports\diagnosis-YYYYMMDD-HHMMSS.json` geschrieben.

Die Kurzprobe lässt sich für einen ruhigeren Mittelwert verlängern oder vollständig überspringen:

```powershell
.\windows-makeover.ps1 -Mode Diagnose -SampleSeconds 15
.\windows-makeover.ps1 -Mode Diagnose -SampleSeconds 0
```

Zulässig sind 0 bis 60 Sekunden. Eine kurze Probe zeigt eine Momentaufnahme und ersetzt bei sporadischen Hängern keine längere Leistungsaufzeichnung.

4. Den gerade erzeugten Report in den geführten Bereinigungslauf geben:

```powershell
.\windows-makeover.ps1 -Mode Remediate -ReportPath .\reports\diagnosis-YYYYMMDD-HHMMSS.json
```

### Erst Vorschau, dann handeln

`-WhatIf` führt **keine** Löschung aus und ist der empfohlene erste Remediate-Lauf:

```powershell
.\windows-makeover.ps1 -Mode Remediate -ReportPath .\reports\diagnosis-YYYYMMDD-HHMMSS.json -WhatIf
```

Eine einzelne Maßnahme lässt sich gezielt auswählen:

```powershell
.\windows-makeover.ps1 -Mode Remediate -ReportPath .\reports\diagnosis-YYYYMMDD-HHMMSS.json -Action CleanTempFiles
```

`-Force` überspringt nur die eigene J/N-Abfrage. Es ist für beaufsichtigte Automatisierung gedacht und nicht der Standardweg.

## Umgang mit Execution Policy

Skripte aus dem Internet sollten vor der Ausführung geprüft werden. Wenn Windows die Datei blockiert, kann man nach Sichtprüfung die Eigenschaften der Datei öffnen und **Zulassen** aktivieren. Alternativ nur diese Datei freigeben:

```powershell
Unblock-File .\windows-makeover.ps1
```

Keine globale Lockerung der Execution Policy und kein `ExecutionPolicy Bypass` nötig.

## Sicherheitsgrenzen

Windows Makeover macht **keinen** aggressiven „Debloat“ und führt insbesondere Folgendes nicht aus:

- keine automatisierte Entfernung vorinstallierter Apps,
- keine Registry-Cleaner oder pauschalen Registry-Änderungen,
- kein Abschalten von Windows-Diensten, Defender, Updates oder Telemetrie,
- kein Löschen von Downloads, Dokumenten oder Desktop-Dateien,
- keine DISM-/Component-Store-Bereinigung,
- keine Treiber- oder BIOS-Änderungen.

Die Laufwerksprüfung liest nur Statuswerte, die Windows bereitstellt. `OK` oder `Healthy` ist keine vollständige SMART-Diagnose und garantiert keinen fehlerfreien Datenträger. Der letzte von WMI gemeldete Hotfix ist außerdem kein vollständiger Nachweis, dass Windows Update lückenlos aktuell ist.

Diagnoseberichte bleiben lokal, enthalten aber Rechnername, Benutzer-SID, Prozess- und Autostart-Namen sowie System- und Sicherheitsstatus. Vor dem Teilen sollten sie geprüft und bei Bedarf anonymisiert werden. Vollständige Autostart-Befehlszeilen werden bewusst nicht gespeichert.

Diese Eingriffe können Wiederherstellung, Updates oder Programme beschädigen. Für ein späteres, optionales Expertenprofil sollten Maßnahmen nur einzeln, nachvollziehbar, reversibel und mit vorherigem Restore-Point umgesetzt werden.

## Fehlersuche außerhalb des Tools

Das Tool kann einen Hardwaredefekt, Überhitzung, Malware oder instabile Treiber nicht zuverlässig ausschließen. Bei dauerhaft langsamen PCs nach der Bereinigung sind gute nächste Schritte:

1. Windows Update abschließen und neu starten.
2. Im Task-Manager nach dauerhaft hoher CPU-, RAM-, Datenträger- oder Netzwerkauslastung schauen.
3. SMART-Werte des Laufwerks mit einem geeigneten Hersteller- oder Diagnosetool prüfen und bei Auffälligkeiten zuerst sichern.
4. Mit dem registrierten Virenschutz einen aktuellen Scan ausführen.
5. Bei mechanischen Festplatten oder nur 4 GB RAM eher Hardware-Upgrade statt weiterer „Tweaks“ erwägen.
6. DISM/SFC beziehungsweise unter Windows 7 SFC und CheckSUR nur bei konkreten Windows-Fehlern einsetzen.
7. CHKDSK mit Reparaturoptionen nur nach einem Dateisystembefund und vorhandener Datensicherung ausführen.

Normale Windows-7-, Windows-8-/8.1- und Windows-10-Ausgaben werden als regulär nicht mehr unterstützt gekennzeichnet. LTSC, LTSB, IoT, Embedded, POSReady und Server erhalten bewusst nur den Hinweis, ihren abweichenden Microsoft-Lebenszyklus einzeln zu prüfen.

## Entwicklung und Tests

Die Tests benötigen Pester 5.7.1. Installation für den aktuellen Benutzer:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
```

Die Pester-Suite prüft Diagnose- und Empfehlungslogik, Windows-Lebenszyklus, manuellen Leitfaden, Live-Schwellenwerte, Bindung des Berichts an PC und Benutzer, `-WhatIf`, JSON-Speicherung, UTF-8-BOM und die Syntax des Einstiegsskripts:

```powershell
Invoke-Pester .\tests\WindowsMakeover.Tests.ps1 -Output Detailed
```

## Releases

Ein Tag wie `v0.2.0-beta` startet den Release-Workflow. Er testet den Stand unter Windows PowerShell 5.1 und PowerShell 7 und veröffentlicht danach drei Dateien:

- `windows-makeover-0.2.0-beta.ps1` ist das eigenständige Skript ohne externes Modul.
- `windows-makeover-0.2.0-beta.zip` enthält das normale Einstiegsskript, das Modul und die README.
- `SHA256SUMS.txt` enthält die SHA-256-Prüfsummen beider Downloads.

Die Prüfsumme eines Downloads lässt sich unter Windows so vergleichen:

```powershell
Get-FileHash .\windows-makeover-0.2.0-beta.ps1 -Algorithm SHA256
```

Der Workflow kann außerdem manuell in GitHub Actions für einen bereits vorhandenen Tag gestartet werden. Release-Version, Tag und die in `windows-makeover.ps1` deklarierte Tool-Version müssen übereinstimmen.

## Projektstruktur

```text
src/WindowsMakeover.psm1       # Testbare Diagnose-, Report- und Bereinigungslogik
windows-makeover.ps1           # Windows-Einstiegspunkt für Diagnose und Remediate
build/New-WMReleaseAssets.ps1  # Erstellt Standalone-Skript, ZIP und SHA-256-Datei
tests/WindowsMakeover.Tests.ps1
.github/workflows/test.yml      # Pester unter Windows PowerShell 5.1 und PowerShell 7
.github/workflows/release.yml   # Testet Tags, baut Assets und erstellt GitHub Releases
.editorconfig                   # UTF-8-BOM für PowerShell-Quelldateien
reports/                       # Lokal erzeugte, nicht versionierte Berichte
```
