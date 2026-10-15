#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# SCRIPT: sup1_c.sh
# VERSIONE: v1.1 (candidata al collaudo, 15 ott 2026)
# FUNZIONE: Setup ComfyUI su istanza GPU cloud (Thunder Compute / Lightning.AI)
#           con modelli scelti per fascia di VRAM e script di utilità.
#
# USO BASE (invariato):
#   curl -sSL https://raw.githubusercontent.com/Spairo83/sup1_c.sh/refs/heads/main/sup1_c.sh | bash && bash ~/start_comfy.sh
#
# VARIABILI (si passano davanti a bash, es.:  curl ... | VIDEO_MODELS=wan bash )
#   VIDEO_MODELS   auto (default) | none | all | lista separata da virgole di:
#                  wan_t2v, wan_i2v, wan (=entrambi), wan5b, ltx, hunyuan
#   SKIP_FLUX=1    non scarica FLUX.1-dev FP8 (17 GB)
#   MARGIN_GB=10   spazio libero da lasciare dopo ogni gruppo di modelli
#   UPDATE_COMFY=0 non aggiorna ComfyUI/custom nodes se già installati
#   COMFY_DIR      cartella di installazione (default ~/ComfyUI)
#   VERIFY_ONLY=1  NON installa: controlla solo che tutti gli URL rispondano
#   DRY_RUN=1      NON scarica: mostra cosa farebbe (fascia GPU, modelli, spazio)
#   HF_TOKEN       token Hugging Face (sola lettura), serve SOLO per LTX-2.5.
#                  Meglio: file ~/.hf_config con riga  HF_TOKEN=hf_xxx  (chmod 600);
#                  se manca, lo script lo chiede in modo nascosto da terminale.
# ═══════════════════════════════════════════════════════════════════════

# NIENTE "set -e": gli errori sono gestiti uno per uno e riepilogati alla fine.
# (v1.0C aveva "set -e" + un trap che lo disattivava al primo errore.)
set -uo pipefail

VERSION="1.1"
COMFY_DIR="${COMFY_DIR:-$HOME/ComfyUI}"
MARGIN_GB="${MARGIN_GB:-10}"
UPDATE_COMFY="${UPDATE_COMFY:-1}"
SKIP_FLUX="${SKIP_FLUX:-0}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
DRY_RUN="${DRY_RUN:-0}"
HF_BASE="${HF_BASE:-https://huggingface.co}"   # sovrascrivibile solo per i test
SIZE_UNIT="${SIZE_UNIT:-1000000000}"              # byte per "GB" nel controllo taglia (solo test)

FAILED_FILES=()
SKIPPED_COMPS=()
MANIFEST=()
TMP_FILES=()

# ───────────────────────────── utilità ─────────────────────────────────
log()  { echo "   $*"; }
warn() { echo "   ⚠️  $*"; }
err()  { echo "   ❌ $*"; }

cleanup() { for f in "${TMP_FILES[@]:-}"; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done; }
trap cleanup EXIT

# Tutti i comandi esterni leggono da /dev/null: con "curl ... | bash" lo script
# arriva da stdin e un comando che legge stdin ne mangerebbe una parte.
PYTHON_BIN="$(command -v python3 || command -v python || true)"

free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; }

read_secret() {  # read_secret "prompt" -> stampa il valore (da /dev/tty, nascosto)
    local v=""
    ( : < /dev/tty ) 2>/dev/null || return 1
    read -rs -t 120 -p "$1" v < /dev/tty > /dev/tty 2>&1 || true
    echo "" > /dev/tty
    [ -n "$v" ] && printf '%s' "$v"
}

# ───────────────────────── rilevamento GPU / fascia ────────────────────
detect_gpu() {
    GPU_NAME="sconosciuta"; GPU_MB=0
    if command -v nvidia-smi >/dev/null 2>&1; then
        local line
        line=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits </dev/null 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            GPU_NAME="${line%,*}"
            GPU_MB="${line##*, }"
            GPU_MB="${GPU_MB//[!0-9]/}"; GPU_MB="${GPU_MB:-0}"
        fi
    fi
    # Fasce [F1-VAR]: <=24 GB | 48 GB | 80 GB e oltre
    if   [ "$GPU_MB" -eq 0 ];     then TIER="24"; warn "GPU/VRAM non rilevata: uso la fascia prudente (24 GB)"
    elif [ "$GPU_MB" -le 26000 ]; then TIER="24"
    elif [ "$GPU_MB" -le 52000 ]; then TIER="48"
    else                               TIER="80"
    fi
}

# ───────────────────────── manifest dei modelli ────────────────────────
# add_file componente cartella nome dimensioneGB auth(0|1) "url1 url2 ..."
# Il primo URL è il principale, gli altri sono fallback con lo STESSO contenuto.
add_file() { MANIFEST+=("$1|$2|$3|$4|$5|$6"); }

define_models() {
    local HF="$HF_BASE"
    local WAN22="$HF/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files"
    local WAN21="$HF/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files"
    local LX2V="$HF/lightx2v/Wan2.2-Distill-Loras/resolve/main"
    local HY15="$HF/Comfy-Org/HunyuanVideo_1.5_repackaged/resolve/main/split_files"
    local QWEN="$HF/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files"
    local LTX="$HF/Lightricks/LTX-2.5/resolve/main"

    # ── [F6] FLUX.1-dev FP8 (immagini). Nessun mirror pubblico equivalente:
    #    il vecchio fallback black-forest-labs/.../flux1-dev-fp8.safetensors NON esiste.
    add_file flux checkpoints flux1-dev-fp8.safetensors 17.25 0 \
        "$HF/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors"

    # ── [F8-WAN] Wan 2.2 (Apache 2.0). Template ComfyUI: video_wan2_2_14B_t2v / _i2v
    add_file wan_common text_encoders umt5_xxl_fp8_e4m3fn_scaled.safetensors 6.74 0 \
        "$WAN22/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors $WAN21/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    add_file wan_common vae wan_2.1_vae.safetensors 0.25 0 \
        "$WAN22/vae/wan_2.1_vae.safetensors $WAN21/vae/wan_2.1_vae.safetensors"

    add_file wan_t2v diffusion_models wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors 14.29 0 "$WAN22/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
    add_file wan_t2v diffusion_models wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors  14.29 0 "$WAN22/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
    add_file wan_t2v loras wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors 1.23 0 \
        "$WAN22/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors $LX2V/wan2.2_t2v_A14b_high_noise_lora_rank64_lightx2v_4step_1217.safetensors"
    add_file wan_t2v loras wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors 1.23 0 \
        "$WAN22/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors $LX2V/wan2.2_t2v_A14b_low_noise_lora_rank64_lightx2v_4step_1217.safetensors"

    add_file wan_i2v diffusion_models wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors 14.29 0 "$WAN22/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    add_file wan_i2v diffusion_models wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors  14.29 0 "$WAN22/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
    add_file wan_i2v loras wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors 1.23 0 \
        "$WAN22/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors $LX2V/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors"
    add_file wan_i2v loras wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors 1.23 0 \
        "$WAN22/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors $LX2V/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"

    # variante leggera: Wan 2.2 TI2V 5B (template video_wan2_2_5B_ti2v)
    add_file wan5b diffusion_models wan2.2_ti2v_5B_fp16.safetensors 10.0 0 "$WAN22/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors"
    add_file wan5b vae wan2.2_vae.safetensors 1.41 0 "$WAN22/vae/wan2.2_vae.safetensors"

    # ── [F8-LTX] LTX-2.5 (Lightricks). Repo GATED: serve account HF + licenza accettata + token.
    #    INT8 convrot (la NVFP4 serve solo su GPU Blackwell: non è inclusa).
    #    Template ComfyUI: video_ltx2_5_t2v / video_ltx2_5_i2v
    add_file ltx diffusion_models ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors 21.5 1 "$LTX/diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"
    add_file ltx text_encoders gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors 15.37 1 "$LTX/text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"
    add_file ltx vae ltx-2.5-video-vae-bf16.safetensors 1.47 1 "$LTX/vae/ltx-2.5-video-vae-bf16.safetensors"
    add_file ltx vae ltx-2.5-audio-vae-bf16.safetensors 0.36 1 "$LTX/vae/ltx-2.5-audio-vae-bf16.safetensors"
    add_file ltx latent_upscale_models ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors 1.0 1 "$LTX/latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"

    # ── [F8-HUNYUAN] HunyuanVideo 1.5 (sostituisce HunyuanVideo 1.0 + FramePack).
    #    File uguali a quelli dei template ufficiali ComfyUI (video_hunyuan_video_1.5_720p_t2v / _i2v).
    add_file hunyuan diffusion_models hunyuanvideo1.5_720p_t2v_fp16.safetensors 16.65 0 "$HY15/diffusion_models/hunyuanvideo1.5_720p_t2v_fp16.safetensors"
    add_file hunyuan diffusion_models hunyuanvideo1.5_720p_i2v_fp16.safetensors 16.65 0 "$HY15/diffusion_models/hunyuanvideo1.5_720p_i2v_fp16.safetensors"
    add_file hunyuan text_encoders qwen_2.5_vl_7b_fp8_scaled.safetensors 9.38 0 \
        "$HY15/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors $QWEN/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
    add_file hunyuan text_encoders byt5_small_glyphxl_fp16.safetensors 0.44 0 "$HY15/text_encoders/byt5_small_glyphxl_fp16.safetensors"
    add_file hunyuan vae hunyuanvideo15_vae_fp16.safetensors 2.52 0 "$HY15/vae/hunyuanvideo15_vae_fp16.safetensors"
    add_file hunyuan clip_vision sigclip_vision_patch14_384.safetensors 0.86 0 "$HY15/clip_vision/sigclip_vision_patch14_384.safetensors"
}

# ───────────────────────── selezione modelli ───────────────────────────
resolve_selection() {
    local sel="${VIDEO_MODELS:-}"
    if [ -z "$sel" ]; then
        if [ "$VERIFY_ONLY" = "1" ]; then sel="all"; else sel="auto"; fi
    fi
    sel="${sel// /}"
    if [ "$sel" = "auto" ]; then
        case "$TIER" in
            24) sel="wan_i2v,wan_t2v" ;;
            48) sel="wan_i2v,wan_t2v,ltx" ;;
            *)  sel="wan_i2v,wan_t2v,ltx,hunyuan" ;;
        esac
    fi
    sel=",${sel},"
    sel="${sel//,all,/,wan_i2v,wan_t2v,ltx,hunyuan,}"
    sel="${sel//,wan,/,wan_i2v,wan_t2v,}"
    sel="${sel//,none,/,}"
    SELECTED=()
    local c
    for c in wan_i2v wan_t2v wan5b ltx hunyuan; do
        case "$sel" in *",$c,"*) SELECTED+=("$c"); sel="${sel//,$c,/,}";; esac
    done
    sel="${sel#,}"; sel="${sel%,}"
    [ -n "$sel" ] && warn "Nomi in VIDEO_MODELS non riconosciuti (ignorati): $sel"
    return 0
}

in_selected() { local c; for c in "${SELECTED[@]:-}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

# componenti da installare, nell'ordine di priorità (flux → wan → ltx → hunyuan)
build_plan() {
    PLAN=()
    [ "$SKIP_FLUX" = "1" ] || PLAN+=(flux)
    if in_selected wan_t2v || in_selected wan_i2v || in_selected wan5b; then PLAN+=(wan_common); fi
    local c
    for c in wan_i2v wan_t2v wan5b ltx hunyuan; do in_selected "$c" && PLAN+=("$c"); done
    return 0
}

# GB ancora da scaricare per un componente (arrotondato per eccesso)
missing_gb() {
    local comp=$1 e c folder name size auth urls total=0
    for e in "${MANIFEST[@]}"; do
        IFS='|' read -r c folder name size auth urls <<< "$e"
        [ "$c" = "$comp" ] || continue
        [ -s "$COMFY_DIR/models/$folder/$name" ] || total=$(awk -v t="$total" -v s="$size" 'BEGIN{print t+s}')
    done
    awk -v t="$total" 'BEGIN{printf "%d", (t==int(t))?t:int(t)+1}'
}

# ───────────────────────── download robusto ────────────────────────────
HF_TOKEN="${HF_TOKEN:-}"
CURL_AUTH_FILE=""

load_hf_token() {
    [ -z "$HF_TOKEN" ] && [ -f "$HOME/.hf_config" ] && . "$HOME/.hf_config" 2>/dev/null
    if [ -z "$HF_TOKEN" ] && [ "$DRY_RUN" != "1" ] && [ "$VERIFY_ONLY" != "1" ]; then
        echo ""
        log "LTX-2.5 è un repository con accesso su richiesta. Prima volta? Serve:"
        log "  1) account su huggingface.co → apri https://huggingface.co/Lightricks/LTX-2.5 e accetta la licenza"
        log "  2) Settings → Access Tokens → crea un token di sola lettura (Read)"
        log "  Incollalo qui sotto (non viene mostrato). Invio vuoto = salta LTX-2.5."
        HF_TOKEN="$(read_secret '   Token HF (hf_...): ')" || HF_TOKEN=""
        if [ -n "$HF_TOKEN" ]; then
            ( umask 077; printf 'HF_TOKEN=%s\n' "$HF_TOKEN" > "$HOME/.hf_config" )
            chmod 600 "$HOME/.hf_config"
            log "Token salvato in ~/.hf_config (chmod 600)."
        fi
    fi
    if [ -n "$HF_TOKEN" ]; then
        CURL_AUTH_FILE="$(mktemp)"; TMP_FILES+=("$CURL_AUTH_FILE"); chmod 600 "$CURL_AUTH_FILE"
        printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN" > "$CURL_AUTH_FILE"
    fi
}

# download_file destinazione auth "url1 url2 ..."  → 0 se il file è presente e completo
download_file() {
    local dest=$1 auth=$2 urls=$3 url attempt rc
    local part="$dest.part" name; name="$(basename "$dest")"
    local auth_args=()
    [ "$auth" = "1" ] && [ -n "$CURL_AUTH_FILE" ] && auth_args=(-K "$CURL_AUTH_FILE")

    if [ -s "$dest" ]; then log "✅ già presente: $name"; return 0; fi
    for url in $urls; do
        for attempt in 1 2 3; do
            log "⬇️  $name (tentativo $attempt/3) ← ${url#https://}"
            curl -fL -# --connect-timeout 30 --retry 3 --retry-delay 5 --retry-connrefused \
                 --speed-limit 1024 --speed-time 120 -C - ${auth_args[@]+"${auth_args[@]}"} -o "$part" "$url" </dev/null
            rc=$?
            if [ $rc -eq 0 ] && [ -s "$part" ]; then mv -f "$part" "$dest"; log "✅ $name"; return 0; fi
            case $rc in
                22) warn "HTTP 4xx/5xx su questo URL (accesso negato o file assente)"; break ;;  # inutile riprovare: prossimo URL
                33) rm -f "$part" ;;                                                           # resume non valido: riparti da zero
            esac
            sleep 3
        done
    done
    rm -f "$part"
    return 1
}

# verifica la taglia: scarta file troncati o pagine di errore salvate come .safetensors
check_size() {
    local f=$1 expected_gb=$2 actual
    actual=$(stat -c %s "$f" 2>/dev/null || echo 0)
    awk -v a="$actual" -v e="$expected_gb" -v u="$SIZE_UNIT" 'BEGIN{exit !(a >= e*u*0.93)}'
}

install_component() {
    local comp=$1 need free e c folder name size auth urls dest ok=true
    need=$(missing_gb "$comp")
    free=$(free_gb "$COMFY_DIR")
    if [ "$need" -gt 0 ] && [ "${free:-0}" -lt $((need + MARGIN_GB)) ]; then
        err "[$comp] servono ~${need} GB (+${MARGIN_GB} di margine) ma ne restano ${free} GB: SALTO."
        SKIPPED_COMPS+=("$comp (spazio: servono ${need} GB, liberi ${free} GB)")
        return 1
    fi
    if [ "$need" -gt 0 ] && [ -z "$HF_TOKEN" ]; then
        for e in "${MANIFEST[@]}"; do
            IFS='|' read -r c folder name size auth urls <<< "$e"
            if [ "$c" = "$comp" ] && [ "$auth" = "1" ] && [ ! -s "$COMFY_DIR/models/$folder/$name" ]; then
                err "[$comp] richiede un token Hugging Face (repo ad accesso su richiesta): SALTO."
                SKIPPED_COMPS+=("$comp (manca HF_TOKEN / ~/.hf_config)")
                return 1
            fi
        done
    fi
    log "📦 [$comp] da scaricare ~${need} GB (spazio libero: ${free} GB)"
    for e in "${MANIFEST[@]}"; do
        IFS='|' read -r c folder name size auth urls <<< "$e"
        [ "$c" = "$comp" ] || continue
        dest="$COMFY_DIR/models/$folder/$name"
        if [ -s "$dest" ] && ! check_size "$dest" "$size"; then
            warn "$name ha una taglia anomala (atteso ~${size} GB): lo riscarico"; rm -f "$dest"
        fi
        if download_file "$dest" "$auth" "$urls" && check_size "$dest" "$size"; then :; else
            if [ -s "$dest" ]; then warn "$name è più piccolo del previsto (${size} GB): lo elimino"; rm -f "$dest"; fi
            FAILED_FILES+=("$comp: $folder/$name"); ok=false
        fi
    done
    $ok
}

# ───────────────────────── git helper ──────────────────────────────────
# clone se assente, altrimenti aggiorna (idempotente). Mai rm -rf di cartelle esistenti.
git_sync() {
    local url=$1 dir=$2 depth=${3:-1} attempt
    local depth_args=(); [ "$depth" != "full" ] && depth_args=(--depth "$depth")
    if [ -d "$dir/.git" ]; then
        if [ "$UPDATE_COMFY" = "1" ]; then
            git -C "$dir" pull --ff-only --quiet </dev/null 2>/dev/null && return 0
            warn "aggiornamento di $(basename "$dir") non riuscito (modifiche locali?): lo lascio com'è"
        fi
        return 0
    fi
    for attempt in 1 2 3; do
        rm -rf "$dir"
        git clone --quiet ${depth_args[@]+"${depth_args[@]}"} "$url" "$dir" </dev/null 2>/dev/null && return 0
        sleep 2
    done
    rm -rf "$dir"
    return 1
}

pip_install() {  # pip_install <args...>
    [ -n "$PYTHON_BIN" ] || return 1
    "$PYTHON_BIN" -m pip install --quiet "$@" </dev/null 2>/dev/null && return 0
    # distribuzioni con Python "externally managed" (PEP 668)
    "$PYTHON_BIN" -m pip install --quiet --break-system-packages "$@" </dev/null 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════
# INIZIO
# ═══════════════════════════════════════════════════════════════════════
main() {
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SUP1_C — ComfyUI Setup v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
START_TIME=$(date +%s)

command -v curl >/dev/null 2>&1 || { err "curl non trovato"; exit 1; }
command -v git  >/dev/null 2>&1 || { err "git non trovato";  exit 1; }
[ -n "$PYTHON_BIN" ] || { err "python non trovato"; exit 1; }

define_models

# ── [1/9] Ambiente ─────────────────────────────────────────────────────
echo "[1/9] 🔍 Verifica ambiente..."
detect_gpu
mkdir -p "$(dirname "$COMFY_DIR")"
FREE0=$(free_gb "$(dirname "$COMFY_DIR")")
log "GPU: $GPU_NAME — ${GPU_MB} MB → fascia ${TIER} GB"
log "Spazio libero: ${FREE0} GB"
resolve_selection
build_plan
log "Modelli video scelti (VIDEO_MODELS=${VIDEO_MODELS:-auto}): ${SELECTED[*]:-nessuno}"
log "Piano download: ${PLAN[*]:-nessuno}"

if [ "$VERIFY_ONLY" = "1" ]; then verify_urls; exit $?; fi

if [ "$DRY_RUN" = "1" ]; then
    local comp tot=0 n
    for comp in "${PLAN[@]:-}"; do
        [ -n "$comp" ] || continue
        n=$(missing_gb "$comp"); tot=$((tot + n)); log "  [$comp] ~${n} GB da scaricare"
    done
    log "Totale ~${tot} GB (liberi: ${FREE0} GB, margine ${MARGIN_GB} GB). DRY_RUN: esco senza installare."
    exit 0
fi

in_selected ltx && load_hf_token

# ── [2/9] ComfyUI (clone o aggiornamento, MAI cancellazione) ───────────
echo "[2/9] 📦 ComfyUI..."
if git_sync "https://github.com/Comfy-Org/ComfyUI.git" "$COMFY_DIR" full; then
    log "✅ ComfyUI pronto in $COMFY_DIR"
else
    err "ERRORE CRITICO: impossibile clonare ComfyUI"; exit 1
fi
cd "$COMFY_DIR" || exit 1

# ── [3/9] Dipendenze Python ────────────────────────────────────────────
echo "[3/9] 🐍 Dipendenze Python..."
pip_install --upgrade pip setuptools wheel || warn "pip upgrade non riuscito (non critico)"
if ! pip_install -r requirements.txt; then err "pip install -r requirements.txt fallito"; FAILED_FILES+=("pip: requirements.txt di ComfyUI"); fi
"$PYTHON_BIN" - <<'PYEOF' 2>/dev/null || warn "PyTorch con CUDA non disponibile: ComfyUI girerà su CPU (controlla l'immagine dell'istanza)"
import torch, sys
sys.exit(0 if torch.cuda.is_available() else 1)
PYEOF

# ── [4/9] Custom nodes ─────────────────────────────────────────────────
# formato:  URL|cartella|componente che li richiede ("-" = sempre)
echo "[4/9] 🔌 Custom nodes..."
declare -a NODES=(
    "https://github.com/Comfy-Org/ComfyUI-Manager.git|ComfyUI-Manager|-"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git|ComfyUI-VideoHelperSuite|-"
    "https://github.com/Kosinkadink/ComfyUI-Advanced-ControlNet.git|ComfyUI-Advanced-ControlNet|-"
    "https://github.com/kijai/ComfyUI-WanVideoWrapper.git|ComfyUI-WanVideoWrapper|wan"
    "https://github.com/Lightricks/ComfyUI-LTXVideo.git|ComfyUI-LTXVideo|ltx"
)
mkdir -p custom_nodes
for node in "${NODES[@]}"; do
    IFS='|' read -r repo_url dir_name need <<< "$node"
    case "$need" in
        -) ;;
        wan) in_selected wan_t2v || in_selected wan_i2v || in_selected wan5b || continue ;;
        *)   in_selected "$need" || continue ;;
    esac
    echo "   → $dir_name"
    if git_sync "$repo_url" "custom_nodes/$dir_name"; then
        [ -f "custom_nodes/$dir_name/requirements.txt" ] && { pip_install -r "custom_nodes/$dir_name/requirements.txt" || warn "requirements di $dir_name non installati del tutto"; }
        log "✅ ok"
    else
        warn "saltato (non critico): $dir_name"
        FAILED_FILES+=("custom node: $dir_name")
    fi
done

# ── [5/9] Cartelle modelli ─────────────────────────────────────────────
echo "[5/9] 📁 Struttura modelli..."
mkdir -p models/{checkpoints,clip_vision,text_encoders,vae,diffusion_models,loras,controlnet,upscale_models,latent_upscale_models}

# ── [6-8/9] Download modelli ───────────────────────────────────────────
echo "[6/9] 🎨 Download modelli (flux, video)... (può richiedere parecchio tempo)"
INSTALLED_COMPS=()
for comp in "${PLAN[@]:-}"; do
    [ -n "$comp" ] || continue
    echo "[7/9] ── gruppo: $comp"
    install_component "$comp" && INSTALLED_COMPS+=("$comp")
done

# manifest dei soli componenti pianificati: lo legge check_setup.sh
: > "$COMFY_DIR/.sup1_manifest"
for e in "${MANIFEST[@]}"; do
    c="${e%%|*}"
    for comp in "${PLAN[@]:-}"; do [ "$c" = "$comp" ] && { echo "$e" >> "$COMFY_DIR/.sup1_manifest"; break; }; done
done

# ── [9/9] Script di utilità ────────────────────────────────────────────
echo "[9/9] 📋 Script di utilità..."
write_helper_scripts
cd "$HOME" || true

# ── Riepilogo ──────────────────────────────────────────────────────────
END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup terminato in $((DURATION / 60))m $((DURATION % 60))s — fascia GPU: ${TIER} GB (${GPU_NAME})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Spazio modelli: $(du -sh "$COMFY_DIR/models" 2>/dev/null | cut -f1) — liberi: $(free_gb "$COMFY_DIR") GB"
if [ ${#SKIPPED_COMPS[@]} -gt 0 ]; then echo "  ⏭️  Gruppi saltati:"; printf '     - %s\n' "${SKIPPED_COMPS[@]}"; fi
if [ ${#FAILED_FILES[@]} -gt 0 ]; then
    echo "  ❌ Problemi (rilancia lo stesso comando: i file già completi non vengono riscaricati):"
    printf '     - %s\n' "${FAILED_FILES[@]}"
else
    echo "  ✅ Nessun errore"
fi
echo ""
echo "  🚀 Avvia ComfyUI:        bash ~/start_comfy.sh"
echo "  🔍 Verifica modelli:     bash ~/check_setup.sh"
echo "  📊 Rapporto collaudo:    bash ~/report_setup.sh"
echo "  💾 Salva workflow:       bash ~/save_workflows.sh   (carica: bash ~/load_workflows.sh)"
echo ""
[ ${#FAILED_FILES[@]} -eq 0 ]
}

# ───────────────────────── VERIFY_ONLY ─────────────────────────────────
verify_urls() {
    echo "[verifica URL] (nessuna installazione)"
    load_hf_token
    local bad=0 comp e c folder name size auth urls url code len first args
    for comp in flux wan_common wan_i2v wan_t2v wan5b ltx hunyuan; do
        case "$comp" in
            flux) [ "$SKIP_FLUX" = "1" ] && continue ;;
            wan_common) in_selected wan_t2v || in_selected wan_i2v || in_selected wan5b || continue ;;
            *) in_selected "$comp" || continue ;;
        esac
        for e in "${MANIFEST[@]}"; do
            IFS='|' read -r c folder name size auth urls <<< "$e"
            [ "$c" = "$comp" ] || continue
            first=1
            for url in $urls; do
                args=(); [ "$auth" = "1" ] && [ -n "$CURL_AUTH_FILE" ] && args=(-K "$CURL_AUTH_FILE")
                code=$(curl -sIL -m 30 ${args[@]+"${args[@]}"} -o /dev/null -w '%{http_code}' "$url" </dev/null)
                len=$(curl -sIL -m 30 ${args[@]+"${args[@]}"} "$url" </dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{l=$2} END{printf "%.2f", l/1e9}')
                if [ "$code" = "200" ]; then
                    printf '   ✅ [%s] %s (%s GB, previsti %s) %s\n' "$comp" "$name" "$len" "$size" "$([ $first -eq 1 ] && echo principale || echo fallback)"
                else
                    printf '   ❌ [%s] %s HTTP %s %s\n' "$comp" "$name" "$code" "$([ $first -eq 1 ] && echo principale || echo fallback)"
                    [ $first -eq 1 ] && bad=$((bad + 1))
                fi
                first=0
            done
        done
    done
    [ $bad -eq 0 ] && echo "   Tutti gli URL principali rispondono." || echo "   ⚠️  $bad URL principali NON rispondono (LTX senza token = 401 è normale)."
    return $bad
}

# ═══════════════════════════════════════════════════════════════════════
# [F9] SCRIPT DI UTILITÀ
# ═══════════════════════════════════════════════════════════════════════
write_helper_scripts() {
cat > ~/start_comfy.sh << 'EOF'
#!/bin/bash
# Avvia ComfyUI. Log in ~/comfy.log (da lì report_setup.sh legge i tempi "Prompt executed in").
# Argomenti extra: COMFY_EXTRA_ARGS="--lowvram" bash ~/start_comfy.sh
echo "🔥 Avvio ComfyUI..."
cd ~/ComfyUI || exit 1
if pgrep -f "python.*main.py.*--port 8188" > /dev/null; then
    echo "⚠️  ComfyUI già in esecuzione, lo fermo..."
    pkill -f "python.*main.py.*--port 8188"
    sleep 3
fi
echo "🚀 Avvio in corso (log: ~/comfy.log)..."
# shellcheck disable=SC2086
python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header "*" ${COMFY_EXTRA_ARGS:-} 2>&1 | tee -a ~/comfy.log
EOF
chmod +x ~/start_comfy.sh

cat > ~/check_setup.sh << 'EOF'
#!/bin/bash
# Verifica i modelli elencati nel manifest scritto dallo script di installazione.
M=~/ComfyUI/.sup1_manifest
echo "══════════════════════════════════════════════"
echo "🔍 VERIFICA SETUP"
echo "══════════════════════════════════════════════"
if [ ! -s "$M" ]; then echo "❌ Manifest assente: rilancia sup1_c.sh"; exit 1; fi
missing=0
while IFS='|' read -r comp folder name size auth urls; do
    f=~/ComfyUI/models/$folder/$name
    if [ -s "$f" ]; then
        printf '✅ [%s] %s (%s)\n' "$comp" "$name" "$(du -h "$f" | cut -f1)"
    else
        printf '❌ [%s] %s — MANCANTE (~%s GB)\n' "$comp" "$name" "$size"; missing=$((missing+1))
    fi
done < "$M"
echo ""
echo "🔌 CUSTOM NODES:"
for node in ~/ComfyUI/custom_nodes/*/; do [ -d "$node" ] && echo "✅ $(basename "$node")"; done
echo ""
echo "💽 Spazio libero: $(df -h ~ | awk 'NR==2{print $4}')"
[ $missing -eq 0 ] && echo "✅ Tutti i modelli pianificati sono presenti" || echo "⚠️  $missing file mancanti: rilancia il comando di installazione"
EOF
chmod +x ~/check_setup.sh

cat > ~/fix_common_issues.sh << 'EOF'
#!/bin/bash
echo "🔧 RISOLUZIONE PROBLEMI AUTOMATICA"
echo "──────────────────────────────────────"
echo "1. Controllo processi ComfyUI..."
if pgrep -f "python.*main.py.*--port 8188" > /dev/null; then
    echo "   Processo trovato, lo fermo..."
    pkill -f "python.*main.py.*--port 8188"
    sleep 3
fi
echo "2. Verifica porta 8188..."
if command -v lsof >/dev/null 2>&1 && lsof -ti:8188 >/dev/null 2>&1; then
    echo "   Porta occupata, libero..."
    kill -9 $(lsof -ti:8188) 2>/dev/null || true
fi
echo "3. Fix permessi directory..."
chmod -R u+rwX ~/ComfyUI/models 2>/dev/null || true
echo "4. Pulizia cache Python..."
find ~/ComfyUI -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
echo "5. File .part (download interrotti)..."
find ~/ComfyUI/models -name "*.part" 2>/dev/null | while read -r p; do echo "   trovato: $p (rilancia sup1_c.sh per riprendere)"; done
echo "✅ Fix automatici completati — prova: bash ~/start_comfy.sh"
EOF
chmod +x ~/fix_common_issues.sh

cat > ~/backup_workflows.sh << 'EOF'
#!/bin/bash
# Copia locale dei workflow in ~/workflow_backup (alternativa offline a save_workflows.sh)
echo "💾 BACKUP LOCALE WORKFLOWS"
WORKFLOW_DIRS=(
    "$HOME/ComfyUI/user/default/workflows"
    "$HOME/ComfyUI/user/workflows"
)
found=false
for dir in "${WORKFLOW_DIRS[@]}"; do
    if [ -d "$dir" ] && find "$dir" -name '*.json' -print -quit | grep -q .; then
        echo "📋 Trovati workflow in: $dir"
        mkdir -p ~/workflow_backup
        cp -a "$dir"/. ~/workflow_backup/ && found=true
    fi
done
if [ "$found" = true ]; then
    echo "✅ Salvati in ~/workflow_backup"
    ls -la ~/workflow_backup/
else
    echo "ℹ️  Nessun workflow trovato"
fi
EOF
chmod +x ~/backup_workflows.sh

# ── libreria comune per il sistema GitHub [FGH]: il token sta SOLO in ~/.github_config (chmod 600)
cat > ~/.sup1_github_lib.sh << 'EOF'
#!/bin/bash
# Sorgente comune di save_workflows.sh / load_workflows.sh
GH_CFG="$HOME/.github_config"
GH_TMP=()
gh_cleanup() { for f in "${GH_TMP[@]:-}"; do [ -n "$f" ] && rm -rf "$f"; done; }
trap gh_cleanup EXIT

gh_ask() {  # gh_ask "prompt" [secret]
    local v=""
    ( : < /dev/tty ) 2>/dev/null || return 1
    if [ "${2:-}" = secret ]; then read -rs -t 180 -p "$1" v < /dev/tty > /dev/tty 2>&1; echo "" > /dev/tty
    else read -r -t 180 -p "$1" v < /dev/tty > /dev/tty 2>&1; fi
    printf '%s' "$v"
}

gh_load_config() {
    if [ ! -f "$GH_CFG" ]; then
        echo "ℹ️  ~/.github_config non esiste: lo creo ora (il token non viene mostrato né salvato altrove)."
        local u r t
        u="$(gh_ask 'Utente GitHub [Spairo83]: ')"; u="${u:-Spairo83}"
        r="$(gh_ask 'Repo privato [comfyui-workflows-private]: ')"; r="${r:-comfyui-workflows-private}"
        t="$(gh_ask 'Token GitHub (classic, scope repo): ' secret)"
        [ -n "$t" ] || { echo "❌ Nessun token: annullo."; return 1; }
        ( umask 077; printf 'GITHUB_USER=%s\nREPO_NAME=%s\nGITHUB_TOKEN=%s\n' "$u" "$r" "$t" > "$GH_CFG" )
    fi
    chmod 600 "$GH_CFG"
    # shellcheck disable=SC1090
    . "$GH_CFG"
    : "${GITHUB_USER:?manca GITHUB_USER in ~/.github_config}"
    : "${GITHUB_TOKEN:?manca GITHUB_TOKEN in ~/.github_config}"
    REPO_NAME="${REPO_NAME:-comfyui-workflows-private}"
    export GITHUB_USER GITHUB_TOKEN
    # Il token NON finisce né nell'URL del remote né nella riga di comando: git lo chiede a questo helper
    local ap; ap="$(mktemp)"; GH_TMP+=("$ap")
    printf '#!/bin/sh\ncase "$1" in Username*) printf "%%s" "$GITHUB_USER";; *) printf "%%s" "$GITHUB_TOKEN";; esac\n' > "$ap"
    chmod 700 "$ap"
    export GIT_ASKPASS="$ap" GIT_TERMINAL_PROMPT=0
    GH_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
}
EOF
chmod 600 ~/.sup1_github_lib.sh

cat > ~/save_workflows.sh << 'EOF'
#!/bin/bash
# Salva i workflow ComfyUI sul repo GitHub privato. NON cancella nulla dal repo e NON usa --force:
# aggiunge/aggiorna i file locali e fa un normale push.
. ~/.sup1_github_lib.sh || exit 1
gh_load_config || exit 1

WORK="$(mktemp -d)"; GH_TMP+=("$WORK")
echo "📥 Scarico lo stato attuale del repo..."
if ! git clone --quiet "$GH_URL" "$WORK/repo" </dev/null 2>"$WORK/err"; then
    echo "❌ Clone fallito: verifica token (scope repo), utente e nome repo in ~/.github_config"
    sed 's/^/   /' "$WORK/err" | head -3
    exit 1
fi
cd "$WORK/repo" || exit 1
git config user.name "$GITHUB_USER"
git config user.email "${GITHUB_USER}@users.noreply.github.com"
git rev-parse HEAD >/dev/null 2>&1 || git checkout -q -B main

copied=0
for src in "$HOME/ComfyUI/user/default/workflows" "$HOME/ComfyUI/user/workflows"; do
    [ -d "$src" ] || continue
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        mkdir -p "$(dirname "$rel")"
        cp -f "$f" "$rel" && copied=$((copied+1))
    done < <(find "$src" -type f -name '*.json' -print0)
done
[ -f README.md ] || printf '# ComfyUI Workflows Privati\n\nContenuto privato (anche NSFW).\n' > README.md

if [ "$copied" -eq 0 ]; then echo "ℹ️  Nessun workflow locale da salvare (cerco in ~/ComfyUI/user/default/workflows)"; fi
git add -A
if git diff --cached --quiet; then echo "✅ Nessuna modifica rispetto al repo"; exit 0; fi
git commit -q -m "Backup workflows $(date '+%Y-%m-%d %H:%M:%S')"
BR="$(git rev-parse --abbrev-ref HEAD)"
git pull --rebase --quiet origin "$BR" </dev/null 2>/dev/null || true
if git push --quiet -u origin "$BR" </dev/null; then echo "✅ Workflows salvati su GitHub ($copied file locali)"; else echo "❌ Push fallito"; exit 1; fi
EOF
chmod +x ~/save_workflows.sh

cat > ~/load_workflows.sh << 'EOF'
#!/bin/bash
# Scarica i workflow dal repo GitHub privato in ~/ComfyUI/user/default/workflows (non cancella nulla in locale)
. ~/.sup1_github_lib.sh || exit 1
gh_load_config || exit 1
DEST="$HOME/ComfyUI/user/default/workflows"
mkdir -p "$DEST"
WORK="$(mktemp -d)"; GH_TMP+=("$WORK")
if git clone --quiet --depth 1 "$GH_URL" "$WORK/repo" </dev/null 2>/dev/null; then
    n=0
    while IFS= read -r -d '' f; do
        rel="${f#"$WORK/repo"/}"
        mkdir -p "$DEST/$(dirname "$rel")"
        cp -f "$f" "$DEST/$rel" && n=$((n+1))
    done < <(find "$WORK/repo" -path "$WORK/repo/.git" -prune -o -type f -name '*.json' -print0)
    echo "✅ Workflows caricati: $n file in $DEST"
else
    echo "❌ Errore download — verifica token, utente e nome repo in ~/.github_config"
    exit 1
fi
EOF
chmod +x ~/load_workflows.sh

cat > ~/report_setup.sh << 'EOF'
#!/bin/bash
# Rapporto per il collaudo: GPU, disco, spazio per cartella modelli, ultimi tempi di generazione.
echo "══════════ RAPPORTO COLLAUDO ($(date '+%Y-%m-%d %H:%M')) ══════════"
echo "GPU:   $(nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader 2>/dev/null)"
echo "Disco: $(df -h ~ | awk 'NR==2{print "usato "$3" / "$2", liberi "$4}')"
echo ""
echo "Spazio per cartella modelli:"
du -sh ~/ComfyUI/models/* 2>/dev/null | sed 's/^/   /'
echo "   TOTALE modelli: $(du -sh ~/ComfyUI/models 2>/dev/null | cut -f1)"
echo ""
echo "Ultimi tempi di generazione (da ~/comfy.log):"
grep -E "Prompt executed in" ~/comfy.log 2>/dev/null | tail -10 | sed 's/^/   /' || true
[ -f ~/comfy.log ] || echo "   (nessun log: avvia ComfyUI con bash ~/start_comfy.sh)"
echo ""
echo "Picco VRAM (se hai lanciato il logger): $(sort -t, -k1 -n -r ~/vram.csv 2>/dev/null | head -1)"
EOF
chmod +x ~/report_setup.sh
}

main "$@"
exit $?
