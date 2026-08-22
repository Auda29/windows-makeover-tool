# Windows Makeover — 0.1.0-alpha

Ein vorsichtiges PowerShell-Tool für die erste Hilfe bei langsamen Windows-PCs. Es ist für Besuche bei Familie und Freunden ausgelegt: zuerst transparent diagnostizieren, danach nur klar begrenzte Maßnahmen anbieten.

> **Alpha-Status:** Die Kernlogik, JSON-Berichte und der geführte Ablauf sind implementiert und getestet. Vor einem breiten Einsatz sollte die Alpha auf mehreren echten Windows-10/11-PCs ausprobiert werden. Sie ersetzt keine Datensicherung und keine professionelle Fehlerdiagnose bei Hardwaredefekten, Malware oder Laufwerksfehlern.

## Was das Tool macht

### Phase 1: Nur Diagnose

`Diagnose` verändert **nichts**. Sie sammelt und speichert einen JSON-Bericht mit:

- Windows-Version, Rechnername und Admin-Status
- freiem Platz auf dem Systemlaufwerk
- Größe und Anzahl der Dateien im Temp-Ordner des aktuellen Benutzers
- Größe des Papierkorbs des aktuellen Benutzers
- Anzahl der Autostart-Einträge
- ausstehendem Windows-Neustart und Laufzeit seit dem letzten Start
- verfügbarem Arbeitsspeicher sowie den fünf aktuell größten Speicherverbrauchern

Die Konsole zeigt eine verständliche Kurzbewertung; der vollständige Bericht liegt anschließend als Datei vor.

### Phase 2: Geführte Maßnahmen

`Remediate` akzeptiert nur einen **aktuellen Bericht vom selben PC** (maximal 30 Tage alt). Für jede Aktion zeigt das Tool Umfang und Speichergewinn an und fordert eine eigene Bestätigung an.

| Aktion | Wann angeboten | Tatsächlicher Umfang |
|---|---|---|
| `CleanTempFiles` | Mehr als 500 MB im Benutzer-Temp-Ordner | Löscht nur Dateien im aktuellen Benutzer-Temp-Ordner. Gesperrte Dateien werden übersprungen und als Fehler gezählt. |
| `CleanRecycleBin` | Mehr als 500 MB im Papierkorb | Leert den Papierkorb des aktuellen Benutzers auf lokalen Laufwerken. Dateien sind danach nicht mehr über den Papierkorb wiederherstellbar. |

Autostart, ausstehende Neustarts, sehr lange Laufzeit und knapper Speicher werden als **Hinweise** ausgegeben. Das Tool ändert sie nicht automatisch.

## Voraussetzungen

- Windows 10 oder Windows 11
- Windows PowerShell 5.1 oder PowerShell 7+
- kein Administratorzugang für die vorgesehenen Maßnahmen erforderlich

## Schnellstart

1. Repository auf den betroffenen PC kopieren oder klonen.
2. PowerShell im Projektordner öffnen.
3. Diagnose starten:

```powershell
.\windows-makeover.ps1 -Mode Diagnose
```

Der Report wird standardmäßig nach `reports\diagnosis-YYYYMMDD-HHMMSS.json` geschrieben.

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

## Sicherheitsgrenzen — bewusst nicht enthalten

Windows Makeover macht **keinen** aggressiven „Debloat“ und führt insbesondere Folgendes nicht aus:

- keine automatisierte Entfernung vorinstallierter Apps,
- keine Registry-Cleaner oder pauschalen Registry-Änderungen,
- kein Abschalten von Windows-Diensten, Defender, Updates oder Telemetrie,
- kein Löschen von Downloads, Dokumenten oder Desktop-Dateien,
- keine DISM-/Component-Store-Bereinigung,
- keine Treiber- oder BIOS-Änderungen.

Diese Eingriffe können Wiederherstellung, Updates oder Programme beschädigen. Für ein späteres, optionales Expertenprofil sollten Maßnahmen nur einzeln, nachvollziehbar, reversibel und mit vorherigem Restore-Point umgesetzt werden.

## Fehlersuche außerhalb des Tools

Das Tool erkennt keine defekte SSD/HDD, Überhitzung, Malware oder instabile Treiber. Bei dauerhaft langsamen PCs nach der Bereinigung sind gute nächste Schritte:

1. Windows Update abschließen und neu starten.
2. Im Task-Manager nach dauerhaft hoher CPU-, RAM-, Datenträger- oder Netzwerkauslastung schauen.
3. SMART-Werte des Laufwerks prüfen und bei Auffälligkeiten sichern/tauschen.
4. Defender-Scan ausführen.
5. Bei mechanischen Festplatten oder nur 4 GB RAM eher Hardware-Upgrade statt weiterer „Tweaks“ erwägen.

## Entwicklung und Tests

Die Pester-Suite prüft Diagnose- und Empfehlungslogik, Umfang und Sicherheitsmarkierungen der Maßnahmen, Bericht-Gültigkeit, `-WhatIf`, JSON-Speicherung und die Syntax des Einstiegsskripts:

```powershell
Invoke-Pester .\tests\WindowsMakeover.Tests.ps1 -Output Detailed
```

## Projektstruktur

```text
src/WindowsMakeover.psm1       # Testbare Diagnose-, Report- und Bereinigungslogik
windows-makeover.ps1           # Windows-Einstiegspunkt für Diagnose und Remediate
tests/WindowsMakeover.Tests.ps1
reports/                       # Lokal erzeugte, nicht versionierte Berichte
```
