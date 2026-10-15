# Piano di collaudo v1.1 — istanza Thunder Compute RTX A6000 (48 GB, $0.35/h)

Obiettivo: verificare che lo script scarichi tutto, che i modelli video partano, e misurare **tempo per una clip da 5 s** e **spazio disco** per ogni modello.
Tutto quello che non è ancora stato misurato è scritto come `____` da compilare.

## 0. Prima di accendere l'istanza (una tantum, ~5 min, dal browser)

1. **LTX-2.5 è un repository ad accesso su richiesta** su Hugging Face: senza token i suoi download danno 401.
   - accedi a huggingface.co → apri <https://huggingface.co/Lightricks/LTX-2.5> → *Agree and Access* (l'approvazione è automatica, secondo il campo `gated: auto` del repo)
   - Settings → Access Tokens → nuovo token di tipo **Read**
   - Tienilo nel password manager. Lo script te lo chiederà **sull'istanza, in modo nascosto**, e lo salverà in `~/.hf_config` (chmod 600). Non va incollato in chat.
2. **Disco**: l'istanza Thunder ha 100 GB di default (da documentazione Thunder, non l'ho verificato dal pannello). Il collaudo completo scarica ~170 GB:
   FLUX 17 + Wan 2.2 (T2V+I2V) 69 + LTX-2.5 40 + HunyuanVideo 1.5 47. Crea l'istanza con **almeno 200 GB** (o ridimensiona il disco; a quanto leggo i dischi si possono solo ingrandire).
3. GPU: **RTX A6000 48 GB**. Se vedi un'altra GPU nel listino dimmelo: la fascia VRAM cambia.

## 1. Pre-controllo (2 minuti, non installa nulla)

```bash
curl -sSL https://raw.githubusercontent.com/Spairo83/sup1_c.sh/refs/heads/v1.1/sup1_c.sh -o ~/sup1_c.sh
df -h ~                                  # annota lo spazio libero
VERIFY_ONLY=1 bash ~/sup1_c.sh           # controlla che tutti gli URL rispondano
DRY_RUN=1 bash ~/sup1_c.sh               # mostra fascia GPU, modelli scelti, GB da scaricare
```

Controlla:
- `GPU: NVIDIA RTX A6000 — 49140 MB → fascia 48 GB`
- nel `VERIFY_ONLY` tutte le righe ✅ tranne LTX (❌ 401 senza token: normale, lo risolvi al passo 2c)
- se un URL che non è LTX è ❌ **fermati e mandami l'output**

## 2. Installazione, un modello alla volta (così misuri il disco di ciascuno)

Per ogni passo: lancia con `time`, poi `bash ~/report_setup.sh` e annota "TOTALE modelli".

```bash
# 2a — Wan 2.2 (+ FLUX, ComfyUI, nodi)
time VIDEO_MODELS=wan bash ~/sup1_c.sh
bash ~/report_setup.sh

# 2b — rilancio identico: deve finire in pochi secondi e dire "già presente" per ogni file (test di idempotenza)
time VIDEO_MODELS=wan bash ~/sup1_c.sh

# 2c — LTX-2.5 (ti chiede il token HF, nascosto)
time VIDEO_MODELS=ltx bash ~/sup1_c.sh
bash ~/report_setup.sh

# 2d — HunyuanVideo 1.5
time VIDEO_MODELS=hunyuan bash ~/sup1_c.sh
bash ~/report_setup.sh

bash ~/check_setup.sh                    # tutto ✅?
```

Controlla:
- alla fine di ogni run: `✅ Nessun errore` e nessun gruppo in "Gruppi saltati"
- 2b: nessuna riga `⬇️`, solo `già presente`
- il totale disco di 2a/2c/2d rispetto alle stime (Wan ~69 GB + FLUX 17 = ~86 GB; LTX ~40; Hunyuan ~47)

| Passo | Tempo setup | Disco aggiunto |
|---|---|---|
| 2a Wan 2.2 + FLUX + ComfyUI | ____ | ____ GB |
| 2c LTX-2.5 | ____ | ____ GB |
| 2d HunyuanVideo 1.5 | ____ | ____ GB |

## 3. Avvio ComfyUI

```bash
# in un secondo terminale: registra il picco di VRAM
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -l 2 > ~/vram.csv &

bash ~/start_comfy.sh                    # log in ~/comfy.log
```

Apri ComfyUI come fai di solito (porta 8188). Menu **Workflow → Browse Templates → Video**. Se un template non c'è, aggiorna ComfyUI (`UPDATE_COMFY=1` è già il default: rilancia lo script) e riavvia.

## 4. Prove di generazione (6 prove: T2V e I2V per ogni modello)

Regole uguali per tutte, per confrontare i tempi:
- **Clip da 5 secondi**: frame = 5 × fps + 1. Wan 2.2: 16 fps → **81 frame**. LTX-2.5 e HunyuanVideo 1.5: se il template usa 24 fps → **121 frame**. Se un template propone un altro fps usa 5 × fps + 1 e rispetta il vincolo del modello (Wan 4n+1; LTX 8n+1; Hunyuan 4n+1: 81 e 121 vanno bene). Annota fps e frame effettivi.
- Risoluzione: quella di default del template (annotala). Poi, se vuoi, una seconda prova a 720p.
- Prompt semplice e SFW per il collaudo tecnico (es. «una donna cammina su una spiaggia al tramonto, camera che la segue»). Per l'I2V usa un'immagine FLUX generata da te nello stesso ComfyUI (così provi anche FLUX).
- **Ogni prova due volte** cambiando solo il seed: la prima include il caricamento del modello (**freddo**), la seconda è il tempo di regime (**caldo**). Per i costi uso il caldo.
- Il tempo lo legge ComfyUI da solo: riga `Prompt executed in N seconds` (lo trovi nella console e in `~/comfy.log`).

| # | Template (nome interno) | Cosa carica |
|---|---|---|
| 1 | Wan 2.2 14B T2V (`video_wan2_2_14B_t2v`) | `wan2.2_t2v_*_fp8_scaled` |
| 2 | Wan 2.2 14B I2V (`video_wan2_2_14B_i2v`) | `wan2.2_i2v_*_fp8_scaled` |
| 3 | LTX-2.5 T2V (`video_ltx2_5_t2v`) | LTX-2.5 distilled int8 |
| 4 | LTX-2.5 I2V (`video_ltx2_5_i2v`) | idem |
| 5 | HunyuanVideo 1.5 720p T2V (`video_hunyuan_video_1.5_720p_t2v`) | `hunyuanvideo1.5_720p_t2v_fp16` |
| 6 | HunyuanVideo 1.5 720p I2V (`video_hunyuan_video_1.5_720p_i2v`) | `hunyuanvideo1.5_720p_i2v_fp16` |

**Nota sui template Wan e i 4 step (lightx2v).** I template ufficiali Wan 2.2 usano 20 step senza LoRA: fai prima la prova **di base** (tempo di riferimento). Poi la prova **veloce** con i LoRA già scaricati: aggiungi un `LoraLoaderModelOnly` prima di ciascuno dei due campionatori (LoRA `*_high_noise` sul modello high-noise, `*_low_noise` su quello low-noise), `cfg = 1`, **4 step totali** (2 sul campionatore high-noise, 2 sul low-noise). È la ricetta comune della community: non l'ho potuta provare io, se non funziona dimmelo e la sistemiamo guardando il tuo workflow.

Compila (una riga per prova):

| # | Risoluzione | Frame @ fps | Step | Freddo (s) | Caldo (s) | Picco VRAM | Esito / qualità |
|---|---|---|---|---|---|---|---|
| 1 base | | | 20 | | | | |
| 1 lightx2v | | | 4 | | | | |
| 2 base | | | 20 | | | | |
| 2 lightx2v | | | 4 | | | | |
| 3 | | | | | | | |
| 4 | | | | | | | |
| 5 | | | | | | | |
| 6 | | | | | | | |

Picco VRAM dopo ogni prova: `sort -n -r ~/vram.csv | head -1` (poi `: > ~/vram.csv` per azzerare).

**Se una prova va in errore** (out of memory, modello non trovato, nodo mancante): copia l'errore dalla console e il nome del template; non cambiare altro. Nota: LTX-2.5 int8 su A6000 (Ampere) non è stato verificato da nessuna fonte che ho trovato, quindi è la prova più a rischio.

## 5. Costo per clip

`costo = tempo caldo (s) / 3600 × 0.35 $`   — esempio: 300 s → 0,029 $ per clip.
Aggiungi una quota per setup/idle se vuoi il costo reale per sessione. Con i tuoi numeri aggiorno il Doc 5.

## 6. Salva/carica workflow su GitHub privato

1. In ComfyUI salva un workflow (Ctrl+S) con un nome qualsiasi.
2. `bash ~/save_workflows.sh` — la prima volta chiede utente, repo e token (**nascosto**) e crea `~/.github_config` con chmod 600. Il token non finisce né nell'URL del remote né negli script.
3. Controlla su GitHub che il file sia nel repo privato.
4. `rm -rf ~/ComfyUI/user/default/workflows/*` poi `bash ~/load_workflows.sh` → il workflow deve tornare.
5. Verifica permessi: `ls -l ~/.github_config` deve mostrare `-rw-------`.

## 7. Chiusura

- `bash ~/report_setup.sh` e `bash ~/check_setup.sh`: copia l'output nel messaggio con le tabelle compilate.
- **Elimina l'istanza** quando hai finito (una istanza ferma tiene comunque il disco, che viene fatturato).
- Dimmi l'esito: sistemiamo ciò che non va, poi merge su `main` e aggiornamento di Doc 6 / Doc 2 / Doc 3 / Doc 5.

## Criteri di superamento

- [ ] `VERIFY_ONLY` tutto ✅ (LTX ✅ con token)
- [ ] Installazione senza errori, rilancio identico senza riscaricare nulla
- [ ] Almeno una prova T2V e una I2V funzionanti per **Wan 2.2**; per LTX-2.5 e HunyuanVideo 1.5 funzionanti oppure motivo del fallimento annotato
- [ ] Tempi caldi e disco misurati per ogni modello
- [ ] Save/load workflow funzionante, token solo in `~/.github_config` (600)
