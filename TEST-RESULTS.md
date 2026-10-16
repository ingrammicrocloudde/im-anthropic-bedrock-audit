# Testresultaten: v0.22 vergeleken met v0.21

**Datum:** 16 oktober 2026
**Uitkomst:** in elke geteste situatie doet v0.22 minder AWS-calls dan v0.21, is het tot ruim 5 keer zo snel, en meldt het problemen die v0.21 niet meldt.

Dit document vergelijkt `im-anthropic-bedrock-audit.sh` v0.22 (inQdo) met v0.21, het originele script van Ingram Micro.

## Vergeleken bestanden

| Versie | Regels | SHA-256 |
| --- | --- | --- |
| v0.21 (Ingram Micro, origineel) | 914 | `350cb13462e8d376b52bd3206159f89aeacdbe1d7bf8a1c23f9122992c9f0ad2` |
| v0.22 (inQdo) | 1430 | `2bc1352b725bb28d658be574879f765781461672d8cb35159a3533c533003bfb` |

## Methode

- **Omgeving:** Linux 6.18 met GNU bash 5.2.21.
- **AWS:** beide versies draaien tegen dezelfde nagebootste AWS CLI (mock). Die geeft vaste antwoorden en logt elke aanroep. Er is geen echt AWS-account, netwerk of kosten bij betrokken.
- **Alleen lezen:** v0.21 kan alleen lezen. De vergelijking gaat daarom over de audit zelf. De aanvraagfuncties van v0.22 (use case, agreements, quota's) hebben geen tegenhanger in v0.21.
- **Looptijd:** de mock wacht 0,3 seconde per AWS-call, om de vertraging van echte AWS na te bootsen.
- **Mock-account:** vijf Claude-modellen in verschillende situaties: met en zonder agreement, één LEGACY-model, één model dat data retention vereist. Daarnaast een groter account met 10 extra modellen en 30 extra quota's.

## Snelheid en aantal AWS-calls

| Scenario (read-only) | v0.21 | v0.22 `--parallel 1` | v0.22 (standaard, 6 parallel) |
| --- | --- | --- | --- |
| 5 modellen, 7 quota's: AWS-calls | 26 | 12 | 12 |
| 5 modellen, 7 quota's: looptijd | 8,2 s | 4,0 s | 2,8 s |
| 15 modellen, 37 quota's: AWS-calls | 66 | 22 | 22 |
| 15 modellen, 37 quota's: looptijd | 20,8 s | 7,6 s | 3,9 s |

Bij het grotere account is v0.22 ruim 5 keer zo snel en doet het een derde van het aantal calls. Het verschil groeit mee met het aantal quota's, omdat v0.21 per quota een aparte call doet voor de standaardwaarde.

Uitsplitsing van de calls bij het grotere account:

| AWS-call | v0.21 | v0.22 |
| --- | --- | --- |
| `sts get-caller-identity` | 4 | 1 |
| `bedrock list-foundation-models` | 2 | 1 |
| `bedrock list-inference-profiles` | 2 | 1 |
| `bedrock get-use-case-for-model-access` | 1 | 1 |
| `bedrock get-foundation-model-availability` | 15 | 15 (parallel) |
| `service-quotas list-service-quotas` | 2 | 1 |
| `service-quotas list-aws-default-service-quotas` | 1 | 1 |
| `service-quotas get-aws-default-service-quota` | 37 | 0 |
| `service-quotas list-requested-service-quota-change-history` | 2 | 1 |
| **Totaal** | **66** | **22** |

## Gedrag in dezelfde situatie

| Situatie | v0.21 | v0.22 |
| --- | --- | --- |
| Modellen zonder agreement | Exitcode 0; geen samenvatting van wat ontbreekt | Exitcode 2; eindoverzicht met `ISSUE (AGREEMENT)` per model |
| Alles in orde | Exitcode 0 | Exitcode 0, `ALL ACTIVE MODELS USABLE` |
| Modellijst niet leesbaar (AccessDenied) | Lege tabellen zonder foutmelding, daarna nog 20 zinloze calls; exitcode 0 | `[FAIL]` met de AWS-foutmelding; regio overgeslagen na 2 calls; exitcode 3 |
| Model mist agreement én autorisatie | `RESULT`: alleen `AUTH` (het agreement-probleem blijft onzichtbaar) | `RESULT`: `AGREEMENT+AUTH` |
| `--invoke`, een model vereist data retention | `RETENTION-REQ` in de tabel; exitcode 0 | `ISSUE (TEST)` in het eindoverzicht; exitcode 2 |
| Meerdere regio's | Niet ondersteund | `--region eu-central-1,eu-west-1` in één run |
| Rapportbestand | Compleet in alle runs | Compleet in alle runs |

v0.21 eindigde in alle scenario's met exitcode 0, ook als er iets mis was. v0.22 eindigt met 0 (alles bruikbaar), 2 (problemen gevonden) of 3 (AWS-calls mislukt). Daardoor is v0.22 ook bruikbaar in automatisering.

Het rapport was in deze runs bij beide versies compleet. In v0.21 kan het einde van het rapport soms ontbreken; dat hangt af van timing en trad hier niet op. v0.22 sluit dat uit doordat het wacht tot alles is weggeschreven.

## Functionaliteit

| Functie | v0.21 | v0.22 |
| --- | --- | --- |
| Audit van modellen, profielen, use case, beschikbaarheid en quota's | Ja | Ja |
| Runtime-test (`--invoke`, `--global`) | Ja | Ja, nu na de aanvragen |
| Use case indienen | Nee | `--submit-use-case`, `--use-case-file` |
| Agreements aanvragen | Nee | `--request-agreement`, met voorkeur voor de private offer (Ingram Micro); `--private-only` |
| Quota-verhoging aanvragen | Nee | `--request-quota`: vraagt de AWS-default aan (lager weigert AWS); `--quota-value`, `--quota-scope` |
| LEGACY-modellen apart behandeld | Nee | Standaard overgeslagen bij aanvragen; `--include-legacy` |
| Meerdere regio's | Nee | Ja |
| Parallelle AWS-calls | Nee | Ja, `--parallel N` |
| Eindoverzicht per model | Nee | `OK`, `ISSUE`, `CHECK` of `LEGACY` |
| Betekenisvolle exitcodes | Nee (altijd 0) | 0, 1, 2 en 3 |
| Bevestiging bij wijzigingen | Niet van toepassing | Per keuze, of één keer vooraf met `--yes` |

## Beperkingen

- **Geen echte AWS:** beide versies zijn alleen tegen de mock gedraaid. Echte AWS-latency en throttling geven andere absolute tijden. De verhouding tussen de versies blijft naar verwachting vergelijkbaar, omdat die vooral komt door het aantal calls.
- **Bash-versie:** alleen getest met Bash 5.2, niet met de Bash 3.2 van macOS.
