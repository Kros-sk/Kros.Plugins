# Distribúcia katalógu — analýza

Prečo dizajn v [catalog-distribution.md](catalog-distribution.md) vyzerá tak, ako vyzerá: ako to má
fungovať, v akom poradí to má prichádzať a ktoré alternatívy boli zamietnuté a na akom základe.

Design dokument hovorí *čo postaviť*. Tento hovorí *prečo* a je to dokument, ktorý si treba prečítať
znova skôr, než sa čokoľvek z toho prehodí.

## Ako to má fungovať

**Kód sa distribuuje s pluginom. Obsah nie.** Verzia pluginu sa mení vtedy, keď sa mení logika hookov,
čo je zriedka. Tipy sa k ľuďom dostanú bez toho, aby ktokoľvek niečo spúšťal.

Z pohľadu vývojára vyzerá jedna session takto. Pri štarte hook prečíta z lokálneho disku tri veci —
čo má nainštalované na stroji, čo nesie aktuálne repo v `.dev-tips/` a nacachovaný vzdialený katalóg —
zlúči ich a doručí najviac jeden tip. Na sieť sa nečaká. Počas session sa ďalej zaznamenáva ledger
príkazov a použitie skillov tak ako doteraz. Na konci turnu, ak je cache staršia než jej TTL, odpojený
proces ju obnoví pre nasledujúcu session a prebiehajúceho turnu sa to nijako nedotkne.

Z pohľadu autora to vyzerá takto. Niekto pridá skill alebo command do `Kros.AiDevTools` a v tom istom
pull requeste k nemu napíše `tip.json`; CI ho zvaliduje voči nástrojom, ktoré naozaj existujú, a PR sa
zmerguje. Niet čo publikovať — ten súbor **je** to, čo stroje čítajú. Do dňa je na každom stroji. Ak
sa tip ukáže ako nesprávny, opraví ho ďalší commit, alebo `enabled: false` umlčí všetko, kým sa to
nevyrieši.

Z ktorého z troch zdrojov tip pochádza, rozhoduje jedna otázka: **má už vývojár tú vec, o ktorej tip
hovorí?**

- Ak ju má, netreba publikovať vôbec nič. Skill je na jeho disku, jeho `description` hovorí, načo je,
  a `usage.json` hovorí, či ho niekedy spustil. Z toho vznikne *máš to a nikdy si to nepoužil*, čo je
  najsilnejšia forma tipu a nepotrebuje žiadny záznam v katalógu.
- Ak patrí repu, v ktorom práve pracuje, cestuje s tým repom a príde `git pull`-om.
- Objaviť sa nedá len nástroj, ktorý **nemá** — a len ten prípad potrebuje publikovaný katalóg.

## Prečo sa publikovanie musí zmeniť

Obsah tipov je zabalený v plugine, takže vydať jeden tip znamená bump verzie, update marketplacu,
update pluginu a reštart — a tri zo štyroch krokov patria vývojárovi, nie nám. Kto ich nikdy nespustí,
číta zastaraný katalóg donekonečna a ani jedna strana sa to nedozvie.

Tá istá väzba robí plugin neumlčateľným: tip, ktorý sa ukáže ako nesprávny, sa zobrazuje ďalej, kým sa
každý jeden človek individuálne neaktualizuje. Pri plugine, ktorého celou úlohou je oznamovať veci,
ktoré práve pribudli, je oboje naopak.

## V akom poradí to má prichádzať

| Etapa | Práca | Čo odomkne | Závisí od |
|---|---|---|---|
| 0 | Rozumné cooldowny v `catalog/config.json` | aby bol plugin vôbec znesiteľný | nič |
| 1 | Kanál A — lokálna detekcia | väčšina tipov prestane potrebovať záznam v katalógu | nič |
| 2 | Kanál B — `.dev-tips/` v produktových repách | ADR a konvencie per repo | nič |
| 3 | Kanál C — CI, fetch na pozadí | tipy na nástroje, ktoré vývojár nemá | prístup k CI v `Kros.AiDevTools` |
| 4 | Koniec ručného editovania `catalog/tips.json` | jediný zdroj pravdy | etapy 1–3 |
| 5 | **Návrh (D13)** — oznámenia o nových ADR ako druhá dráha | nové ADR dobehnú každého raz | etapy 1–3, rozhodnutie o D13 |

Poradie je podľa hodnoty na jednotku rizika. Kanál A nepotrebuje CI, sieť ani druhé repo a pokrýva
najväčšiu časť toho, čo by sa inak muselo písať ručne. Kanál C je posledný, lebo je jediný, ktorý
vyžaduje zmenu v repe, ktoré tento plugin nevlastní.

Meranie — či to vôbec mení správanie — zostáva mimo rozsahu. Zo stroja nič neodchádza.

## Register rozhodnutí

Každý záznam: čo bolo zvolené, voči čomu, a čo by oprávnilo prehodnotiť to.

### D1 — Obsah tipu žije vedľa nástroja, ktorý opisuje

**Zvolené:** `tip.json` vedľa skillu alebo commandu, vo vlastnom repe toho nástroja.

**Voči:**
- *Centrálnemu ručne udržiavanému katalógu.* Ten, kto premenuje command, nie je ten, kto si spomenie
  na tip, takže katalóg sa rozchádza a nikto si to nevšimne — jediní ľudia, ktorí tip čítajú, sú tí,
  čo ten nástroj nepoznajú, a tí nemajú ako rozpoznať, že je nesprávny.
- *`CLAUDE.md` alebo memory.* Oboje platí v každom turne, trvalo stojí kontext, nedá sa rate-limitovať,
  nedá sa zobraziť presne N-krát a nedá sa potlačiť pre niekoho, kto ten nástroj už používa. Tip je
  dočasné oznámenie, nie trvalá inštrukcia.

**Prehodnotiť, ak:** katalóg prestane rásť a nástroje sa prestanú premenúvať — vtedy je centrálna
kurácia menej mašinérie za ten istý výsledok.

### D2 — Tri kanály namiesto jedného

**Zvolené:** delenie podľa toho, či vývojár tú vec už má.

**Voči:** *jednému vzdialenému katalógu na všetko.* Jednoduchšie sa vysvetľuje, ale vyžaduje záznam
pre každý nástroj skôr, než sa o ňom dá čokoľvek povedať, a nevie vyjadriť najsilnejší dostupný tip —
že tento človek nástroj má a nikdy ho nespustil. Delenie zároveň znamená, že väčšina tipov nepotrebuje
publikačnú cestu vôbec.

**Prijatá cena:** tri vetvy kódu a krok zlúčenia namiesto jedného čítania.

### D3 — Detekcia používa `description` zo `SKILL.md`

**Zvolené:** keď `tip.json` neexistuje, text tipu sa vygeneruje z frontmatteru.

**Voči:** *vyžadovaniu `tip.json` pre všetko.* Lepší text, ale nový skill potom nemá tip, kým ho niekto
nenapíše — a to je presne to oneskorenie, kvôli ktorému tento dizajn vznikol.

**Známa slabina:** `description` je písaný preto, aby modelu povedal, kedy skill použiť, nie aby
presvedčil človeka vyskúšať ho. Niektoré budú čítať zle. Poistkou je, že `tip.json` ho prebíja, takže
zlý text sa dá opraviť bez zmeny mechanizmu.

**Prehodnotiť, ak:** sa v praxi ukáže, že väčšina vygenerovaných textov aj tak potrebuje prepísať.

### D4 — Vzdialený prenos je `git`

**Zvolené:** shallow fetch z bare repozitára v dátovom priečinku pluginu.

**Voči:**
- *Surovému HTTP s tokenom.* `Kros.AiDevTools` je privátne, takže by to znamenalo distribuovať
  credential vnútri pluginu nainštalovaného na stroji každého vývojára. Zamietnuté bez diskusie.
- *UNC file share.* Najjednoduchšie na firemnej LAN a bez credentials, ale zlyhá z domu aj cez VPN a
  nenesie históriu. Držané ako záloha, ak by `git` robil problémy.
- *Internej HTTP službe.* Hosting, nasadenie a monitoring kvôli jednému JSON súboru.

**Prečo to funguje:** `git` použije Git Credential Manager, ktorý vývojár musí mať nakonfigurovaný —
inak by mu nefungoval ani `plugin marketplace add`. Autentifikácia nestojí nič.

### D5 — Nepublikuje sa nič; klient číta zdroj

**Zvolené:** žiadny generovaný katalóg. Refresh fetchne `master` shallow a prečíta si autorské
`tip.json` priamo zo stromu; zvyšok si dopočíta sám.

**Voči:**
- *Orphan vetve s generovaným `tips.json`.* Funguje to, ale je to build artifact, ktorý treba držať v
  súlade so zdrojom, vyrába ho bot a nesie obsah, ktorý klient vie prečítať z toho zdroja rovnako
  lacno. Každý problém, ktorý priniesla — smyčka pri retriggeri, branch protection, artifact, ktorý
  môže zostarnúť — je problémom toho, že artifact vôbec existuje.
- *Generovanému súboru commitnutému do `master`.* Buď ho pushuje bot, s tými istými problémami so
  smyčkou a ochranou vetvy, alebo ho každý prispievateľ pregenerúva ručne — trenie umiestnené presne
  na ľudí, ktorí tipy píšu dobrovoľne.
- *GitHub release assetu.* Potrebuje API token proti privátnemu repu, čo je znova zamietnutá možnosť
  z D4.
- *Samostatnému repu.* Ďalšie repo na založenie, oprávnenia a udržiavanie v súlade, kvôli jednému
  súboru.

**Prijatá cena:** odvodzovanie `id`, `ref` a `install` sa presúva do klienta, takže zmena týchto
pravidiel si vyžiada vydanie pluginu. Menia sa ale rádovo zriedkavejšie než obsah, a to bolo celé
kritérium.

**Prehodnotiť, ak:** odvodzovanie prerastie to, čo je rozumné robiť v hooku, alebo repo narastie
natoľko, že shallow fetch jeho stromu prestane byť lacný.

### D6 — Refresh beží zo `Stop`, odpojene, na TTL

**Zvolené:** `Stop` skontroluje vek cache a keď je stará, spustí odpojený proces a skončí.

**Voči:**
- *Fetchu v `SessionStart`.* Dáva sieť na cestu k prvému promptu. Odmietnuté: sekunda pri štarte
  odinštaluje plugin rýchlejšie než akýkoľvek zlý tip.
- *`SessionStart` odpojene.* Pokrylo by aj session, v ktorých sa nedokončí žiadny turn, za cenu
  spustenia procesu pri každom štarte. Rozdiel je zanedbateľný; `Stop` vyhráva preto, že tam už
  bežia iné evidenčné veci.
- *Naplánovanej úlohe v OS.* Najspoľahlivejšia možnosť a zároveň najinvazívnejšia: plugin, ktorý
  zakladá Windows scheduled task, sa ťažko odinštaluje a ťažko obhajuje.

### D7 — Tipy sa doručujú len pri štarte session

**Zvolené:** prijať, že čerstvo stiahnutý katalóg použije až *nasledujúca* session.

**Voči:** *doručeniu uprostred session cez `UserPromptSubmit`*, na ktoré mašinéria existuje v
`Show-Candidate.ps1`. Zamietnuté preto, že plánovaný tip prerušujúci prácu je rušivejší než tip pri
štarte — retrospektívne oznámenie si to prerušenie zaslúži tým, že reaguje na to, čo vývojár práve
urobil, plánovaný tip nie. A nič sa tým nezíska: obsah s 24-hodinovým TTL nemá dôvod doraziť o
deväťdesiat sekúnd skôr.

### D8 — Politika cestuje v stiahnutom súbore a verí sa jej

**Zvolené:** `ttlHours`, `cooldownDays` a `enabled` žijú v katalógu; hodnoty v plugine slúžia len ako
bootstrap pre prvý fetch. Čo povie ten súbor, to hook urobí.

**Voči:**
- *Politike v plugine.* Každá zmena kadencie by si vyžiadala vydanie a — rozhodujúci bod — neexistoval
  by spôsob, ako umlčať zlý tip u všetkých bez toho, aby sa každý jeden človek aktualizoval.
- *Orezávaniu stiahnutých hodnôt na medze v hooku.* Zamietnuté. Medza je hádanie, ktorá hodnota je
  zlá, urobené skôr, než ktokoľvek videl plugin zlyhávať v prevádzke. Odpoveďou na zlý push je
  opravený push, alebo `enabled: false`, kým sa neopraví — oboje dorazí do jedného TTL, čo je
  rýchlejšie, než vydať nového klienta s inými medzami. Ak reálna prevádzka ukáže, že kadencia
  potrebuje spodnú hranicu, vtedy je čas zistiť, aká tá hranica je.

**Prijatý dôsledok:** zlý push rozkonfiguruje všetky stroje naraz, až kým to ďalší neopraví.

### D9 — `published` sa ruší v prospech lokálneho `firstSeen`

**Zvolené:** hook si do `shown.json` zapíše, kedy dané `id` videl prvý raz. Pole `published` neexistuje.

**Voči:**
- *Odvodeniu z git histórie.* Shallow fetch žiadnu nenesie a držať históriu kvôli datovaniu jedného
  poľa je veľká cena za malú vec.
- *Ručne písanému dátumu.* Rozchádza sa, zabúda sa naň a nikto ho v review nekontroluje.

**Prečo je lokálne lepšie, nielen lacnejšie:** to pole má povedať, aká nová je daná vec, a novosť je
relatívna voči čitateľovi. Pre niekoho, kto nastúpil minulý týždeň, je dva roky starý skill, o ktorom
nikdy nepočul, nový. `expires` zostáva autorským poľom — to, že obsah zastaral, je vlastnosťou obsahu,
nie čitateľa.

### D10 — Repo-lokálne tipy nikdy nevstupujú do centrálneho katalógu

**Zvolené:** `.dev-tips/` sa číta naživo z pracovného priečinka.

**Voči:** *ich zbieraniu do katalógu cez CI.* To potrebuje cross-repo token a druhú publikačnú cestu
pre obsah, ktorý už leží na disku, dá sa prečítať zadarmo a je správny pre každý worktree zvlášť.

### D11 — Použitie sa číta z transcriptov, nielen zaznamenáva dopredu

**Zvolené:** refresh na pozadí prejde `~/.claude/projects/**/*.jsonl`, nájde volania skillov a doplní
nimi `usage.json`, takže nástroj, ktorý niekto už používa, sa mu nikdy neponúkne.

**Voči:**
- *Zaznamenávaniu len od inštalácie ďalej*, čo sa deje dnes. Robí to z čerstvej inštalácie maximálne
  otravný zážitok: vývojárovi sa ponúkajú commandy, ktoré používa mesiace. To je jediná skúsenosť,
  po ktorej si plugin najpravdepodobnejšie vypne, a každého zasiahne presne raz — hneď v prvý deň.
- *Opýtaniu sa vývojára, čo už pozná.* Dotazník pri prvom spustení je trenie na najhoršom možnom
  mieste a ľudia aj tak podhodnocujú.

**Prijaté limity:** transcripty sa uchovávajú len obmedzený čas, takže *nikdy nepoužil* v skutočnosti
znamená *nepoužil v poslednom čase* — čo je na tento účel lepšia otázka. Skill zavolaný subagentom sa
počíta ako použitie. Platí to per stroj, ako každý iný signál tu.

### D12 — Detekcia ponúka len pluginy z našich marketplaceov

**Zvolené:** allow-list marketplaceov, defaultne `kros-ai-dev-tools` a `kros-plugins`, prepisateľný
cez `discoverMarketplaces` v stiahnutej konfigurácii.

**Voči:**
- *Ponúkaniu všetkého, čo je na stroji nainštalované.* Pôvodné správanie. Stroj bežne nesie aj
  cudzie nástroje — `superpowers`, `anthropic-skills` — ku ktorým sme nepísali text, nemáme pod
  kontrolou, kedy sa zmenia, a tip na ne minú to jedno oznámenie za cooldown na niečo, čo nám
  neprináleží odporúčať.
- *Filtrovaniu podľa prefixu názvu pluginu (`kros-*`).* Vyzerá jednoduchšie a je nesprávne: `teapie`
  ani `push` sa tak nevolajú, hoci naše sú. Vlastníctvo vyjadruje marketplace, nie názov.

**Prijatý dôsledok:** ak sa nájde cudzí nástroj, ktorý stále za propagáciu, treba ho do zoznamu
pridat vedome — alebo mu napísať vlastný `tip.json` a nespoliehať sa na jeho `description`.

### D13 — Nové ADR ako oznámenia, nie ako tipy

**Status: návrh, nerozhodnuté.** Na rozdiel od D1 až D12 to nie je prijaté rozhodnutie. Zapísané je
preto, aby sa nestratilo, a preto, že mení jednu z úvah v D3.

**Návrh:** nové prijaté ADR z `Kros-sk/Kros.ADR` doručovať **druhou dráhou** s vlastným rozpočtom —
titulok a odkaz, automaticky, práve raz na vývojára.

**Prečo nie tou istou dráhou ako tipy.** Tip a oznámenie o ADR majú opačnú ekonomiku. Tip hovorí
*keď budeš mať čas, toto existuje*: je preskočiteľný navždy, načasovanie nehrá rolu a platí naň
limit jeden za cooldown. Nové prijaté ADR hovorí *odteraz to platí*: týka sa kódu, ktorý niekto
napíše zajtra, a musí dobehnúť raz. Ak pôjdu jednou rúrou, oznámenia zjedia rozpočet tipov a ADR
zároveň čaká v poradí, kým naň príde rad. Prehrajú obe.

**Prečo oznámenie nepotrebuje ručne písaný text.** Titulok z frontmatteru a odkaz stačia. Tým padá
výhrada z D3, kvôli ktorej pri ADR trváme na opt-in poli `tip:` — to zostáva pre druhú rolu,
**opakované** pripomenutie ADR, ktoré ľudia porušujú. Oznámenie je jednorazové a ide samo.

**Spúšťačom musí byť lokálny stav, nie dátum v ADR.** `accept-draft.ps1` prepisuje `📝 Draft` na
`✅ Accepted` a pole `date` nechá tak, takže dátum vo frontmatteri je dátum vzniku, nie prijatia. A
klient fetchuje `--depth 1`, čiže ten prechod nikdy neuvidí. *Nový* preto znamená **prvý raz, čo
tento stroj vidí dané ADR so statusom Accepted** — čo je `firstSeen` z D9 a nepotrebuje históriu.

**Čo to zabije, ak sa to zanedbá.** Pri prvej inštalácii vidí klient všetkých 22 prijatých ADR ako
nevidené. Bez poistky pošle 22 oznámení a plugin si každý vypne v prvej minúte. Prvý beh preto musí
stav **len naočkovať** — zapísať existujúce ADR ako videné, bez oznámenia — a oznamovať len to, čo
pribudne potom. To isté platí pre niekoho po mesiaci dovolenky: dohnať treba, ale po jednom za
session, od najstaršieho.

**Lacnejšia alternatíva, ktorú treba zvážiť skôr.** Ak je cieľ len *nech sa o novom ADR dozvedia
všetci*, webhook z GitHubu do Teams kanála je zlomok tejto mašinérie a dorazí aj k ľuďom, ktorí ten
týždeň Claude Code neotvoria. Nie sú to konkurenti: webhook na povedomie, plugin na moment práce.
Keby sa malo vybrať len jedno, webhook je lacnejší a spoľahlivejší.

**Nezačínať pred** dokončením etáp 1 až 3. Pridávať štvrtý kanál do práce, ktorá ešte nedosedla, je
stavanie druhého podlažia na nedokončenom prvom.

### D14 — Tipy kreslí mod, nie `systemMessage`

**Zvolené:** oznámenie vykreslí **pás nad promptom** (`ui.render` na `AbovePrompt`) z modu —
pluginu funkčných hookov. Výber tipu zostáva v PowerShelli; mod je len zobrazovadlo a vstup.

**Voči:**
- *`systemMessage` z `SessionStart` hooku.* Jediný deterministický kanál k človeku, a na desktope
  ho appka zahodí (#75534). Dnešná obchádzka — poslať text modelu v `additionalContext` s pokynom
  vypísať ho doslova — doručí tip o turn neskôr a robí z neho odporúčanie: model ho môže
  preformulovať, zahodiť alebo podľa neho začať konať.
- *Toastu.* `$.ui.toast` je jeden riadok na štyri sekundy; jediná voľba je `timeoutMs`. Na oznámenie
  s telom a otázkou je to zlá nádoba.
- *Panelu (`Pane`).* Na jeden tip neprimerane veľké, a otvorený nevyžiadane sa usadí až od 144
  stĺpcov.

**Čo tým pribudlo nad rámec opravy rozbitého kanála.** Pás vie **prijať odpoveď**. Otázka tipu
prestáva byť vetou, na ktorú človek odpovedá prózou a model ju interpretuje, a stáva sa tlačidlami:
*Ukáž ako*, *Už to používam*, zahodenie. Stlačenie je jednoznačné a **spočítateľné** — čo je prvá
reálna odpoveď na otvorenú otázku 4, teda ako by sme vôbec zistili, že plugin funguje. `systemMessage`
toto nevedel nikdy, takže mod nie je len náhradou za rozbitú cestu.

**Overené sondou**, nie úvahou: pás sa vykreslí na desktope aj v termináli, `Link` s `href` funguje na
oboch, a strom je platný pod pravidlami oboch povrchov.

**Prijatá cena, a tá je vyššia, než sa zdalo.** API je označené *early access* a mení sa medzi
vydaniami bez varovania. Pri sonde sa to prejavilo dvakrát za jedno popoludnie:

- na builde 2.1.284 kreslil terminál pás tak, že znaky z tela textu pretlačili riadok s titulkom
  (`WebApplicationBuilder` vyšlo ako `WebApplicationBuglder`); o build neskôr bolo rovnaké správne,
- v tom istom kroku sa zmenila práca s fokusom: predtým sa na tlačidlo dalo kliknúť priamo, potom až
  po `tab`.

Ani jedna z tých zmien nebola v našom kóde. To je údržba, ktorú si beriem na seba vedome.

**Preto musí ostať únik.** Klasický `SessionStart` hook sa neruší. Mod po načítaní zapíše značku a
hook pri jej nájdení mlčí; kde sa mod nenačíta — starý build, vypnuté hot reloading, prostredie bez
podpory — značka nie je a tip sa doručí tak ako dnes. Degradácia tým nie je tichá polovičná, ale
návrat k správaniu, ktoré funguje.

### D15 — Odpovede sa zaznamenávajú lokálne; agregácia je nerozhodnutá

**Zvolené:** každé stlačenie v páse sa zapíše do `answers.log` v dátovom priečinku — čas, `id`
tipu a jedna z troch odpovedí:

| Odpoveď | Čo hovorí | Čo urobí |
|---|---|---|
| `known` | tento nástroj už používam | zapíše sa aj do `usage.json`, tip sa viac neponúkne |
| `show` | vysvetli mi to | model dostane prompt (D14) |
| `dropped` | nezaujíma ma to | tip videl a odmietol ho, čo je vlastný signál |

**Prečo na tom záleží.** Otvorená otázka 4 — *ako by sme vôbec zistili, že to funguje* — stála od
začiatku bez odpovede, lebo odpoveď na tip bola veta, ktorú interpretoval model. Vetu nešlo
spočítať a `known` nešlo odlíšiť od `dropped`. Stlačenie je jednoznačné, a `known` je navyše viac
než záznam: je to to isté potlačenie, ktoré D11 dovtedy **odhadoval** z transcriptov. Z odhadu sa
stalo tvrdenie.

**Zo stroja to ale neodchádza.** To nie je opomenutie, je to dôsledok vety, ktorá je v tomto dizajne
napísaná ako vlastnosť. Agregácia naprieč tímom ju ruší, a dá sa to dvoma spôsobmi:

- *Opt-in export.* Jeden príkaz vypíše anonymný súhrn, človek ho pošle sám. Nula infraštruktúry a
  nula tichého zberu, za cenu nízkej návratnosti a vzorky skreslenej smerom k ľuďom, ktorých
  plugin baví — teda k tým, ktorých odpoveď potrebujeme najmenej.
- *Centrálny endpoint.* Reálne čísla za cenu súhlasu, prevádzky a dôvery. Pri plugine, ktorý ľuďom
  hovorí, že niečo robia neefektívne, je tichý zber dát najrýchlejšia cesta k tomu, aby si ho
  vypli.

**Status agregácie: nerozhodnuté.** Zámerne. Rozdiel oproti stavu pred D14 je, že dáta už existujú a
sú jednoznačné; chýba len rozhodnutie, či a ako opustia stroj. To rozhodnutie je o dôvere, nie o
technike, a nepatrí do kódu.

### D16 — Pás je zdieľané miesto; kto ho vezme, musí skladať

**Zvolené:** `dev-tips` volá `next(e)` vždy — aj keď tip má — a tip kladie **nad** to, čo prišlo
zdola. Oprava kolízie patrí do pluginu, ktorý to miesto zaberie — nie do toho, ktorý je pod ním.

**Prečo to vzniklo.** Nad promptom je **jedno miesto a viac záujemcov**. Hook, ktorý vráti vlastný
strom a `next(e)` nezavolá, skryje všetko pod sebou — a urobí to **ticho**: žiadna chyba, žiadny
riadok v logu, nikto sa o tom nedozvie. `pr-watch` to robil práve takto a `dev-tips` tým zmizol
úplne okrem tých chvíľ, keď mal `pr-watch` otvorený vlastný panel a preto sa uhol.

**Oprava v `pr-watch`:** najprv `const beneath = await next(e)`, potom svoj riadok **nad** to, čo
prišlo zdola, namiesto **namiesto** neho. Test `a band beneath this one is drawn too, not replaced`
to drží na oboch povrchoch; bez neho by to niekto nevedomky vrátil, lebo pôvodný tvar vyzerá
nevinne.

**To isté pravidlo porušoval `dev-tips` sám.** `next(e)` volal len vtedy, keď nemal čo kresliť;
s tipom vracal iba vlastný strom. Kým bol v reťazi pod `pr-watch`, nebolo to vidieť. Po
premenovaní na `pr-list` sa poradie otočilo, `dev-tips` sa dostal navrch a tlačidlo
*Pull requesty* zmizlo vždy, keď bol tip na obrazovke. Test `a band beneath this one is drawn too
while a tip is shown, not replaced` to teraz drží. Poradie v reťazi si plugin nevyberá, takže
skladať musí každý, kto pás zaberá — nielen ten, ktorý je práve navrchu.

**Prijatý dôsledok:** `dev-tips` sa dá stále prekryť akýmkoľvek ďalším pluginom, ktorý neskladá.
Zvnútra sa to zariadiť nedá — kto nevolá `next(e)`, tomu sa niet ako uhnúť. A keďže zlyhanie je
tiché, prejaví sa ako *„plugin nič nerobí“*, nie ako chyba. Ak sa to zopakuje, hľadať najskôr tu.

**Pri tom sa opravilo aj tvrdenie o balení.** Chvíľu to vyzeralo, že `modules` vedľa klasických
`hooks` v jednom `hooks.json` sa za behu nenačítajú, a smerovalo to k rozdeleniu na dva pluginy.
Nie je to pravda: modul sa načítaval celý čas, len sa nedostal ku kresleniu. **Jeden plugin stačí**
— potvrdené behom, nie validátorom, ktorý o klasických hookoch nehovorí nič.

### D17 — Kedy sa pás kreslí, určuje povrch; v novom chate sa to obísť nedá

**Zvolené:** tip v novozaloženom chate príde až s prvou správou a tak to ostáva. Neobchádza sa to
ani notifikáciou OS, ani procesom na pozadí.

**Prečo to vzniklo.** Pás sa javil ako nespoľahlivý: raz tam bol hneď, inokedy až po prvej správe.
Príčina nie je v `dev-tips` ani v mode, ale v tom, **kedy vôbec vzniká proces**, ktorý modul načíta.

| Ako sa otvorí | Proces | Pás |
|---|---|---|
| Nový chat (desktop) | až pri prvej správe | až s prvou správou |
| Existujúca konverzácia (desktop) | pri otvorení | hneď, bez písania |
| Terminál (`claude`) | pri spustení | pri prompte (podľa kontraktu, nemerané) |

**Zmerané, nie odvodené.** Nový chat `d9627a26`: hook bežal 11:39:12.394, súbor konverzácie vznikol
11:39:12.785, prvý riadok používateľa 11:39:12.846 — **450 ms**, čiže session vzniká spolu s prvou
správou, nie pri otvorení okna. Obnovená konverzácia `c6eceef0` (Framework): hook bežal 11:49:51.796,
pás vykreslil tip, súboru sa zmenil čas na 11:49:52 — a **posledný riadok konverzácie ostal z
28. 9.** Proces nabehol a tip sa zobrazil bez jediného nového riadku.

**Prečo sa to nedá obísť.** Kým proces nebeží, nie je čo načítať modul, a plugin nemá do čoho
zabrať — nie je to medzera v API, ale poradie štartu. Jediné obchádzky vedú mimo Claude Code
(notifikácia OS, naplánovaná úloha). To je iný a dotieravejší kanál než pás nad promptom a ide proti
D7 aj proti tomu, že nič neopúšťa stroj; zamietnuté.

**Prijatý dôsledok, a je to skôr dobre.** V novom chate tip príde presne vtedy, keď človek naozaj
píše. Pás na prázdnom okne, ktoré niekto otvorí a hneď zavrie, by sa počítal ako zobrazený a
cooldown by ho zjedol nadarmo.

**Vedľajší nález, ktorý mení čítanie dát.** Keďže otvorenie konverzácie štartuje proces, `SessionStart`
sa spúšťa aj pri obyčajnom klikaní po bočnom paneli — 12. 10. nabehli v Invoicingu štyri behy za
devätnásť sekúnd bez jediného napísaného znaku. **Počet behov hooku teda nie je počet sedení pri
práci** a na meranie dosahu (D11, D15) sa použiť nedá; zmysel má až cooldown, ktorý z toho spraví
najviac jeden tip za `cooldownDays`.

### D18 — Autorský súbor sa ruší; text nesie sám dokument

**Zvolené:** `*.tip.json` sa nepíše. Text tipu je `description` zo `SKILL.md`, text pravidla je
`title` a prvý odsek `## Rozhodnutie` z ADR alebo `# H1` a prvý odsek z guideline. Jedinou
povolenou autorskou kópiou je nepovinný riadok `tip:` vo front matter **toho istého dokumentu** —
vedľa veci, ktorú opisuje, nikdy v samostatnom súbore. **Ruší D1, D2 a D10.**

**Prečo to vzniklo.** Kanál autorských súborov stál prácu a nedoručil nič. Katalóg vyexpedoval
osem autorských tipov a **ani jeden `*.tip.json` nikdy nikto nenapísal**; všetky tipy, ktoré sa
reálne zobrazili, vznikli z popisu objaveného skillu. Druhá, ručne písaná kópia vety, ktorú už
autor nástroja napísal, je práca navyše s dvoma miestami pravdy.

**Vypína sa, nemaže.** `authoredTips: false` obchádza zabalený katalóg, stiahnuté tipy aj
repozitárové `.dev-tips`. Čítačky zostávajú na mieste, takže zapnutie späť je zmena configu, nie
revert. Zmerané pri zavedení: katalóg spadol zo 16 položiek na 8, odišlo presne tých 8 autorských.

**Pravidlá sú oznámenia, nie tipy.** ADR a guideline dostávajú `maxShows = 1` a nijaké potlačenie
podľa použitia — pravidlo sa nespúšťa a nikto ho „už nepoužíva". V páse preto nestoja tlačidlá
*„Ukáž ako"* a *„Už to používam"*, ale *„Vysvetli mi to"* a *„Poznám"*; stlačenia sú tie isté dve,
takže odpovede ostávajú porovnateľné naprieč druhmi.

**Čo sa stane so starým obsahom.** Všetko, čo existuje pri zapnutí kanála, sa raz zapíše do
`shown.json` ako už oznámené — inak by sa fronta dvadsiatich šiestich oznámení žrala jedno
oznámenie za cooldown celé mesiace a skilly by sa nedostali na rad. Výnimky menuje
`announceAnyway`: `0018-CompanyId-vs-TenantId` a `0021-Nepouzivame-ApplicationType-v-novych-castiach`,
teda ADR zmerané ako najporušovanejšie, ktoré vznikli pred zapnutím a oznámiť sa raz oplatí.
Baseline beží **raz** a cooldown nechá na pokoji: je to účtovníctvo, nie zobrazenie.

**Čím je podložené, že sa to dá čítať.** Na 22 ADR v `Kros.ADR` a 4 guidelines v Invoicingu: 20 ADR
má `## Rozhodnutie` (2 nemajú a preskočia sa), prvý odsek má medián 150 znakov a 14 z 20 sa zmestí
pod strop 240 bez zásahu; zvyšok oreže `ConvertTo-TipBody` na vete. Po zapojení dal reťazec 24
dokumentov a baseline zapísal 22 záznamov. Dve veci sa ukázali až na ostrých dátach a fixtures ich
nezachytili: dokumenty majú **CRLF**, na ktorom pôvodná kotva regexu našla 20 nadpisov vo fixtures
a 0 v repozitári, a nesú **markdown**, ktorý by pás — kreslí `Text`, nie markdown — ukázal ako
doslovné hviezdičky; oboje má odvtedy vlastný test.

**Prijatý dôsledok.** Objavovanie vidí len nainštalované skilly z našich marketplaceov a dokumenty
z ADR repa a `docs/guidelines`. Čokoľvek iné, čo by sa oplatilo oznámiť a nemá ani popis, ani jednu
z týchto dvoch podôb, sa cez `dev-tips` nedoručí, kým preň nevznikne vlastná čítačka. To je cena za
to, že nikto nepíše text dvakrát.

**Čo tým padá.** `tools/Test-TipFiles.ps1` a workflow `dev-tips-validate.yml` validovali kanál,
ktorý je vypnutý; odchádzajú spolu s ním aj z PR na Kros.AiDevTools.

## Riziká

| Riziko | Závažnosť | Odpoveď |
|---|---|---|
| Zlý push do `dev-tips/config.json` rozkonfiguruje všetkých | vysoká | opravený push, alebo `enabled: false`, do jedného TTL — zámerne bez poistky na strane klienta (D8) |
| Nikto nenapíše `tip.json`, takže cesta nič neprinesie | stredná | kanál A vyrába tipy bez akéhokoľvek písania |
| Vygenerovaný text číta zle | stredná | `tip.json` ho prebíja, tip po tipe |
| Retrospektívne oznámenia vyskočia na falošnú zhodu | stredná | formulácia zostáva *nabudúce môžeš*, nikdy *mal si* |
| Na desktope ide tip cez model, ktorý ho môže preformulovať | nízka | zdokumentované v `desktop-systemmessage-not-rendered.md`, issue nahlásené |
| Odpojený fetch zamrzne na výzve na credentials | nízka | promptovanie vypnuté, tvrdý timeout, lock so stale timeoutom |
| Vydanie Claude Code zmení vykresľovanie alebo vstup pásu | stredná | klasický hook ako únik (D14); pozorované už medzi 2.1.284 a nasledujúcim buildom |
| Iný plugin vezme pás a nezavolá `next(e)` | stredná | zvnútra sa brániť nedá (D16); zlyhanie je tiché, takže pri *„nerobí nič“* hľadať najskôr tu |

## Otvorené otázky

1. **Kto vie pridať validačný workflow do `Kros.AiDevTools`?** Etapa 3 už nepotrebuje vetvu ani bota,
   ale stále potrebuje niekoho, kto tam vie pridať CI. Vlastníctvo nie je určené.
2. **Kde je `655507-dev-tips-plugin.md`?** README ho uvádza ako dizajn, o ktorý sa opiera; na tomto
   stroji nie je v žiadnom repe. Buď ho prelinkovať, alebo tú zmienku zrušiť.
3. **Stačí vypnutie promptovania GCM v praxi?** Spôsob zlyhania — skrytý proces visiaci navždy — je
   dosť závažný na to, aby si zaslúžil zámerný test s vymazaným credentialom, nie predpoklad.
4. **Ako by sme vôbec zistili, že to funguje?** Meranie neexistuje a neplánuje sa. Prijaté, ale
   znamená to, že každé rozhodnutie tu stojí na úvahe, nie na dôkaze, a jediný spôsob, ako ich
   opraviť, je dať tú vec pred ľudí a sledovať, čo si vypnú.
