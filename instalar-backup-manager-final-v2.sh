#!/bin/bash

set -u

BASE="/etc/scripts"
MANAGER="$BASE/backup-manager.sh"
MK="$BASE/mkbkp.sh"
DUDE="$BASE/dudebkp.sh"
TG="$BASE/backup-telegram.conf"
DATA="$(date +%Y%m%d_%H%M%S)"

echo "======================================================================"
echo " BACKUP MANAGER - INSTALADOR FINAL COMPLETO"
echo " RouterOS + Dude DB + Telegram + CRON"
echo "======================================================================"
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Execute este instalador como root."
    exit 1
fi

mkdir -p "$BASE" /root/.ssh
chmod 700 /root/.ssh

echo "🔐 Criando backups de segurança..."
[ -f "$MANAGER" ] && cp -a "$MANAGER" "${MANAGER}.bak_${DATA}"
[ -f "$MK" ] && cp -a "$MK" "${MK}.bak_${DATA}"
[ -f "$DUDE" ] && cp -a "$DUDE" "${DUDE}.bak_${DATA}"
[ -f "$TG" ] && cp -a "$TG" "${TG}.bak_${DATA}"
crontab -l 2>/dev/null > "/root/backup-crontab-${DATA}.txt" || true
[ -f /etc/crontab ] && cp -a /etc/crontab "/root/etc-crontab-${DATA}.txt"
echo "✅ Backups concluídos."

echo
echo "⚠️ SEGURANÇA MK-AUTH:"
echo "   Este instalador NUNCA executa apt upgrade, apt-get upgrade,"
echo "   dist-upgrade ou full-upgrade."
echo "   O APT é usado somente para update e instalação pontual de dependências."
echo

corrigir_apt_buster_instalador(){
    local resp dataapt
    echo
    echo "======================================================================"
    echo " ⚠️ FALHA NO APT UPDATE"
    echo "======================================================================"
    echo
    echo "Este MK-AUTH pode estar usando repositórios antigos do Debian Buster."
    echo
    echo "A correção irá:"
    echo " - salvar backup do /etc/apt/sources.list"
    echo " - configurar archive.debian.org para Buster"
    echo " - desativar Check-Valid-Until"
    echo " - executar SOMENTE apt-get update novamente"
    echo
    echo "⚠️ NENHUM apt upgrade será executado."
    echo
    read -p "👉 Aplicar correção automática dos repositórios Buster? [S/n]: " resp
    case "$resp" in n|N) return 1 ;; esac

    dataapt="$(date +%Y%m%d-%H%M%S)"
    if [ -f /etc/apt/sources.list ]; then
        cp -a /etc/apt/sources.list "/etc/apt/sources.list.bkp-${dataapt}" || return 1
        echo "✅ Backup: /etc/apt/sources.list.bkp-${dataapt}"
    fi

    cat > /etc/apt/sources.list <<'EOF_APT_BUSTER'
deb [trusted=yes] http://archive.debian.org/debian buster main contrib non-free
deb [trusted=yes] http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF_APT_BUSTER

    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/99archive-buster <<'EOF_APT_CONF'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
EOF_APT_CONF

    echo "🔄 Tentando apt-get update novamente..."
    apt-get -o Acquire::Check-Valid-Until=false update
}

apt_update_seguro_instalador(){
    apt-get update && return 0
    corrigir_apt_buster_instalador
}

echo "📦 Verificando dependências..."
FALTANDO=""
for P in sshpass curl zip unzip jq python3 ssh scp ssh-keygen; do
    command -v "$P" >/dev/null 2>&1 || FALTANDO="$FALTANDO $P"
done

if [ -n "$FALTANDO" ]; then
    echo "Dependências ausentes:$FALTANDO"
    echo "Tentando instalar SOMENTE os pacotes necessários..."
    if ! apt_update_seguro_instalador; then
        echo "❌ Não foi possível atualizar a lista de pacotes."
        exit 1
    fi
    apt-get install -y sshpass curl zip unzip jq python3 openssh-client cron || {
        echo "❌ Não foi possível instalar todas as dependências."
        exit 1
    }
else
    echo "✅ Dependências principais OK."
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat <<'MK_EOF' > "$TMPDIR/mkbkp.sh"
#!/bin/bash

IP="${1:-}"
USERSSH="${2:-}"
PASS="${3:-}"
PORT="${4:-22}"

BASE="/etc/scripts"
TGCONF="$BASE/backup-telegram.conf"
TMPBASE="/tmp/mkbkp"
DATA="$(date +%Y%m%d-%H%M%S)"

[ -n "$IP" ] && [ -n "$USERSSH" ] && [ -n "$PASS" ] || {
    echo "Uso: $0 IP USUARIO SENHA [PORTA]"
    exit 1
}

[ -f "$TGCONF" ] || { echo "❌ Telegram não configurado: $TGCONF"; exit 1; }
. "$TGCONF"

mkdir -p "$TMPBASE"

SSH_OPTS=(-p "$PORT" -o ConnectTimeout=15 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-P "$PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

IDENTITY="$(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" ':put [/system identity get name]' </dev/null 2>/dev/null | tr -d '\r')"
[ -n "$IDENTITY" ] || { echo "❌ Falha ao obter Identity de $IP."; exit 1; }

SAFE_ID="$(echo "$IDENTITY" | tr ' /\\:' '____')"
REMOTE="routeros-${SAFE_ID}-${DATA}"
LOCAL_RSC="$TMPBASE/${REMOTE}.rsc"
ZIPFILE="$TMPBASE/${REMOTE}.zip"

echo "📡 Identity: $IDENTITY"
echo "💾 Gerando export RouterOS..."

if ! sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" \
    "/export hide-sensitive file=\"$REMOTE\"" </dev/null >/dev/null 2>&1; then
    echo "⚠️ Tentando export sem hide-sensitive..."
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" \
        "/export file=\"$REMOTE\"" </dev/null >/dev/null 2>&1 || {
        echo "❌ Falha ao gerar export."
        exit 1
    }
fi

sleep 2

echo "📥 Baixando export..."
sshpass -p "$PASS" scp "${SCP_OPTS[@]}" "$USERSSH@$IP:${REMOTE}.rsc" "$LOCAL_RSC" >/dev/null 2>&1 || {
    echo "❌ Falha no SCP do export."
    exit 1
}

sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" "/file remove \"$REMOTE.rsc\"" </dev/null >/dev/null 2>&1 || true

cd "$TMPBASE" || exit 1
zip -q "$(basename "$ZIPFILE")" "$(basename "$LOCAL_RSC")" || exit 1

TAM="$(du -h "$ZIPFILE" | awk '{print $1}')"
CAPTION="💾 ROUTEROS - $IDENTITY
📅 Backup: $(date +%d/%m/%Y)
🕐 Horário: $(date +%H:%M:%S)
📦 Arquivo: $(basename "$ZIPFILE")
📊 Tamanho: $TAM"

echo "📲 Enviando ao Telegram..."
RESP="$(curl -s --connect-timeout 15 \
    -F "chat_id=$CHATID" \
    -F "caption=$CAPTION" \
    -F "document=@$ZIPFILE" \
    "https://api.telegram.org/bot${TOKEN}/sendDocument")"

if echo "$RESP" | grep -q '"ok":true'; then
    echo "✅ Backup RouterOS enviado com sucesso."
    rm -f "$LOCAL_RSC" "$ZIPFILE"
    exit 0
fi

echo "❌ Telegram recusou o envio."
echo "$RESP"
exit 1

MK_EOF

cat <<'DUDE_EOF' > "$TMPDIR/dudebkp.sh"
#!/bin/bash

IP="${1:-}"
USERSSH="${2:-}"
PASS="${3:-}"
PORT="${4:-22}"

BASE="/etc/scripts"
TGCONF="$BASE/backup-telegram.conf"
TMPBASE="/tmp/dudebkp"
DATA="$(date +%Y%m%d-%H%M%S)"

[ -n "$IP" ] && [ -n "$USERSSH" ] && [ -n "$PASS" ] || {
    echo "Uso: $0 IP USUARIO SENHA [PORTA]"
    exit 1
}

[ -f "$TGCONF" ] || { echo "❌ Telegram não configurado: $TGCONF"; exit 1; }
. "$TGCONF"

mkdir -p "$TMPBASE"

SSH_OPTS=(-p "$PORT" -o ConnectTimeout=20 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-P "$PORT" -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

IDENTITY="$(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" ':put [/system identity get name]' </dev/null 2>/dev/null | tr -d '\r')"
[ -n "$IDENTITY" ] || { echo "❌ Falha ao obter Identity de $IP."; exit 1; }

CHECK="$(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" \
    ':do {/dude print; :put "DUDE_OK"} on-error={:put "DUDE_ERROR"}' </dev/null 2>&1)"
echo "$CHECK" | grep -q "DUDE_OK" || {
    echo "❌ The Dude não está disponível ou usuário sem permissão."
    exit 1
}

SAFE_ID="$(echo "$IDENTITY" | tr ' /\\:' '____')"
REMOTE="dude-db-${SAFE_ID}-${DATA}.db"
LOCAL_DB="$TMPBASE/$REMOTE"
ZIPFILE="$TMPBASE/${REMOTE}.zip"

echo "📡 Identity: $IDENTITY"
echo "💾 Exportando banco do Dude..."

sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" \
    "/dude export-db backup-file=\"$REMOTE\"" </dev/null >/dev/null 2>&1 || {
    echo "❌ Falha ao exportar banco do Dude."
    exit 1
}

sleep 3

echo "📥 Baixando banco..."
sshpass -p "$PASS" scp "${SCP_OPTS[@]}" "$USERSSH@$IP:$REMOTE" "$LOCAL_DB" >/dev/null 2>&1 || {
    echo "❌ Falha no SCP do banco Dude."
    exit 1
}

sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USERSSH@$IP" "/file remove \"$REMOTE\"" </dev/null >/dev/null 2>&1 || true

cd "$TMPBASE" || exit 1
zip -q "$(basename "$ZIPFILE")" "$(basename "$LOCAL_DB")" || exit 1

TAM="$(du -h "$ZIPFILE" | awk '{print $1}')"
CAPTION="💾 DUDE DB - $IDENTITY
📅 Backup: $(date +%d/%m/%Y)
🕐 Horário: $(date +%H:%M:%S)
📦 Arquivo: $(basename "$ZIPFILE")
📊 Tamanho: $TAM"

echo "📲 Enviando ao Telegram..."
RESP="$(curl -s --connect-timeout 20 \
    -F "chat_id=$CHATID" \
    -F "caption=$CAPTION" \
    -F "document=@$ZIPFILE" \
    "https://api.telegram.org/bot${TOKEN}/sendDocument")"

if echo "$RESP" | grep -q '"ok":true'; then
    echo "✅ Backup Dude DB enviado com sucesso."
    rm -f "$LOCAL_DB" "$ZIPFILE"
    exit 0
fi

echo "❌ Telegram recusou o envio."
echo "$RESP"
exit 1

DUDE_EOF

cat <<'MANAGER_EOF' > "$TMPDIR/backup-manager.sh"
#!/bin/bash

BASE="/etc/scripts"
TGCONF="$BASE/backup-telegram.conf"
MK_SCRIPT="$BASE/mkbkp.sh"
DUDE_SCRIPT="$BASE/dudebkp.sh"

mkdir -p "$BASE" /root/.ssh

pause(){ echo; read -p "Pressione ENTER para continuar..."; }

cabecalho(){
    clear 2>/dev/null || true
    echo "======================================================================"
    echo " 💾 BACKUP MANAGER - MIKROTIK ROUTEROS + THE DUDE"
    echo "======================================================================"
}

backup_cron(){
    local d
    d="$(date +%Y%m%d_%H%M%S)"
    crontab -l 2>/dev/null > "/root/backup-crontab-${d}.txt" || true
    [ -f /etc/crontab ] && cp -a /etc/crontab "/root/etc-crontab-${d}.txt"
    echo "✅ Backup da CRON criado em /root."
}

aplicar_cron(){
    echo
    echo "🔄 Aplicando/reiniciando CRON..."
    if command -v service >/dev/null 2>&1; then
        service cron restart >/dev/null 2>&1 || \
        service cron reload >/dev/null 2>&1 || \
        service cron start >/dev/null 2>&1 || true
    elif [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron restart >/dev/null 2>&1 || \
        /etc/init.d/cron start >/dev/null 2>&1 || true
    fi
    sleep 1
    if pgrep -x cron >/dev/null 2>&1; then
        echo "✅ CRON funcionando."
        return 0
    fi
    echo "❌ CRON não foi detectada em execução."
    return 1
}

extrair_valor(){
    local arq="$1" var="$2" linha val
    [ -f "$arq" ] || return
    linha="$(grep -m1 -E "^[[:space:]]*${var}=" "$arq" 2>/dev/null)"
    [ -n "$linha" ] || return
    val="${linha#*=}"
    val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    case "$val" in \$*) return ;; esac
    echo "$val"
}

procurar_telegram_existente(){
    FOUND_TOKEN=""
    FOUND_CHAT=""
    FOUND_FILE=""

    if [ -f "$TGCONF" ]; then
        unset TOKEN CHATID
        . "$TGCONF"
        if [ -n "${TOKEN:-}" ] && [ -n "${CHATID:-}" ]; then
            FOUND_TOKEN="$TOKEN"; FOUND_CHAT="$CHATID"; FOUND_FILE="$TGCONF"; return
        fi
    fi

    local t c
    for f in "$MK_SCRIPT" "$DUDE_SCRIPT"; do
        [ -f "$f" ] || continue
        t="$(extrair_valor "$f" TOKEN)"
        c="$(extrair_valor "$f" CHATID)"
        if [ -n "$t" ] && [ -n "$c" ]; then
            FOUND_TOKEN="$t"; FOUND_CHAT="$c"; FOUND_FILE="$f"; return
        fi
    done

    local antigo="/opt/mk-auth/scripts/enviaBkp"
    if [ -f "$antigo" ]; then
        t="$(extrair_valor "$antigo" TOKEN)"
        c="$(extrair_valor "$antigo" USER)"
        if [ -n "$t" ] && [ -n "$c" ]; then
            FOUND_TOKEN="$t"; FOUND_CHAT="$c"; FOUND_FILE="$antigo"
        fi
    fi
}

testar_telegram_dados(){
    local tok="$1" chatid="$2" enviar="${3:-nao}"
    local bot chat grupo tipo r

    echo
    echo "🔎 Testando Telegram..."
    bot="$(curl -s --connect-timeout 10 "https://api.telegram.org/bot${tok}/getMe")"
    if ! echo "$bot" | jq -e '.ok==true' >/dev/null 2>&1; then
        echo "❌ Token inválido ou Telegram inacessível."
        return 1
    fi
    echo "✅ Bot: $(echo "$bot" | jq -r '.result.username // .result.first_name // "SEM NOME"')"

    chat="$(curl -s --connect-timeout 10 -d "chat_id=$chatid" "https://api.telegram.org/bot${tok}/getChat")"
    if ! echo "$chat" | jq -e '.ok==true' >/dev/null 2>&1; then
        echo "❌ Chat ID inválido ou BOT sem acesso."
        return 1
    fi

    grupo="$(echo "$chat" | jq -r '.result.title // .result.username // .result.first_name // "SEM NOME"')"
    tipo="$(echo "$chat" | jq -r '.result.type // "desconhecido"')"
    echo "✅ Grupo/Chat: $grupo"
    echo "📂 Tipo: $tipo"
    echo "🆔 Chat ID: $chatid"

    if [ "$enviar" = "sim" ]; then
        r="$(curl -s \
            --data-urlencode "chat_id=$chatid" \
            --data-urlencode "text=✅ Backup Manager - Telegram funcionando corretamente." \
            "https://api.telegram.org/bot${tok}/sendMessage")"
        if echo "$r" | jq -e '.ok==true' >/dev/null 2>&1; then
            echo "✅ Mensagem de teste enviada."
        else
            echo "❌ Falha ao enviar mensagem de teste."
            return 1
        fi
    fi
    return 0
}

salvar_telegram(){
    local tok="$1" chatid="$2"
    [ -f "$TGCONF" ] && cp -a "$TGCONF" "${TGCONF}.bak_$(date +%Y%m%d_%H%M%S)"
    {
        printf 'TOKEN=%q\n' "$tok"
        printf 'CHATID=%q\n' "$chatid"
    } > "$TGCONF"
    chmod 600 "$TGCONF"
    echo "✅ Telegram salvo em $TGCONF"
}

configurar_telegram(){
    local nt nc op
    while true; do
        echo
        read -p "👉 Token do Bot Telegram: " nt
        read -p "👉 Chat ID / ID do grupo: " nc
        if testar_telegram_dados "$nt" "$nc" sim; then
            salvar_telegram "$nt" "$nc"
            return 0
        fi
        read -p "👉 Digitar novamente? [S/n]: " op
        case "$op" in n|N) return 1 ;; esac
    done
}

inicializar_telegram(){
    procurar_telegram_existente
    if [ -z "$FOUND_TOKEN" ] || [ -z "$FOUND_CHAT" ]; then
        echo "ℹ️ Nenhuma configuração Telegram encontrada."
        configurar_telegram
        return
    fi

    echo
    echo "📲 Telegram existente encontrado em: $FOUND_FILE"
    echo "Token : $FOUND_TOKEN"
    echo "ChatID: $FOUND_CHAT"
    echo
    if testar_telegram_dados "$FOUND_TOKEN" "$FOUND_CHAT" nao; then
        echo
        echo "[1] Manter configuração"
        echo "[2] Alterar Token / Chat ID"
        echo "[3] Enviar mensagem de teste"
        read -p "👉 Opção [1]: " op
        [ -z "$op" ] && op=1
        case "$op" in
            2) configurar_telegram ;;
            3) testar_telegram_dados "$FOUND_TOKEN" "$FOUND_CHAT" sim && salvar_telegram "$FOUND_TOKEN" "$FOUND_CHAT" ;;
            *) salvar_telegram "$FOUND_TOKEN" "$FOUND_CHAT" ;;
        esac
    else
        configurar_telegram
    fi
}

preparar_chave_ssh(){
    local ip="$1" user="$2" pass="$3" port="${4:-22}"
    local saida resposta

    echo
    echo "🔐 Verificando chave SSH de $ip:$port..."

    saida="$(sshpass -p "$pass" ssh \
        -p "$port" \
        -o ConnectTimeout=8 \
        -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=accept-new \
        "$user@$ip" ':put "SSH_KEY_OK"' </dev/null 2>&1)"

    if echo "$saida" | grep -q "SSH_KEY_OK"; then
        if echo "$saida" | grep -qi "Permanently added"; then
            echo "✅ Nova chave SSH registrada no Linux."
        else
            echo "✅ Chave SSH conhecida e válida."
        fi
        return 0
    fi

    if echo "$saida" | grep -Eqi \
        "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|Offending .* key"; then

        echo
        echo "======================================================================"
        echo " ⚠️ CHAVE SSH DO EQUIPAMENTO FOI ALTERADA"
        echo "======================================================================"
        echo
        echo "IP      : $ip"
        echo "Usuário : $user"
        echo "Porta   : $port"
        echo
        echo "O Linux possui uma chave SSH antiga salva para este equipamento."
        echo
        echo "Isso pode acontecer quando:"
        echo " - MikroTik foi reinstalado"
        echo " - RouterOS foi reinstalado/atualizado"
        echo " - equipamento foi substituído"
        echo " - chave SSH foi regenerada"
        echo " - o mesmo IP passou a ser usado por outro equipamento"
        echo
        echo "⚠️ Confirme que este é realmente o equipamento correto."
        echo
        read -p "👉 Remover SOMENTE a chave antiga deste IP/porta e tentar novamente? [S/n]: " resposta
        case "$resposta" in
            n|N) echo "❌ Chave antiga mantida."; return 1 ;;
        esac

        mkdir -p /root/.ssh
        touch /root/.ssh/known_hosts
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/known_hosts

        echo
        echo "🧹 Removendo chave SSH antiga..."
        ssh-keygen -f /root/.ssh/known_hosts -R "$ip" >/dev/null 2>&1 || true
        ssh-keygen -f /root/.ssh/known_hosts -R "[$ip]:$port" >/dev/null 2>&1 || true
        echo "✅ Chave antiga removida."
        echo "🔄 Tentando registrar a nova chave..."

        saida="$(sshpass -p "$pass" ssh \
            -p "$port" \
            -o ConnectTimeout=8 \
            -o ConnectionAttempts=1 \
            -o StrictHostKeyChecking=accept-new \
            "$user@$ip" ':put "SSH_KEY_OK"' </dev/null 2>&1)"

        if echo "$saida" | grep -q "SSH_KEY_OK"; then
            echo "✅ Nova chave SSH registrada."
            echo "✅ Conexão SSH funcionando."
            return 0
        fi

        echo "❌ Não foi possível conectar após remover a chave antiga."
        echo "$saida"
        return 1
    fi

    if echo "$saida" | grep -Eqi "Permission denied|Authentication failed|Access denied"; then
        echo "❌ Falha de autenticação SSH."
        echo "   Verifique usuário, senha e permissões."
        return 1
    fi

    if echo "$saida" | grep -qi "Connection refused"; then
        echo "❌ Conexão SSH recusada em $ip:$port."
        return 1
    fi

    if echo "$saida" | grep -Eqi "Connection timed out|No route to host|Network is unreachable"; then
        echo "❌ Equipamento inacessível em $ip:$port."
        return 1
    fi

    echo "❌ Erro SSH:"
    echo "$saida"
    return 1
}

testar_equipamento(){
    local tipo="$1" ip="$2" user="$3" pass="$4" port="${5:-22}"
    local r id

    echo
    echo "======================================================================"
    echo " 🔎 TESTE DE CONEXÃO"
    echo "======================================================================"
    echo "Tipo    : $tipo"
    echo "IP      : $ip"
    echo "Usuário : $user"
    echo "Senha   : $pass"
    echo "Porta   : $port"

    preparar_chave_ssh "$ip" "$user" "$pass" "$port" || return 1

    r="$(sshpass -p "$pass" ssh \
        -p "$port" -o ConnectTimeout=10 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=accept-new \
        "$user@$ip" ':put "SSH_OK"' </dev/null 2>&1)"
    if ! echo "$r" | grep -q "SSH_OK"; then
        echo "❌ Falha no teste SSH."
        echo "$r"
        return 1
    fi

    id="$(sshpass -p "$pass" ssh \
        -p "$port" -o ConnectTimeout=10 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=accept-new \
        "$user@$ip" ':put [/system identity get name]' </dev/null 2>/dev/null | tr -d '\r')"

    [ -n "$id" ] || { echo "❌ Não foi possível obter o Identity."; return 1; }

    echo "✅ SSH conectado."
    echo "✅ Autenticação funcionando."
    echo "✅ Identity: $id"

    if [ "$tipo" = "DUDE" ]; then
        r="$(sshpass -p "$pass" ssh \
            -p "$port" -o ConnectTimeout=10 -o ConnectionAttempts=1 \
            -o StrictHostKeyChecking=accept-new \
            "$user@$ip" ':do {/dude print; :put "DUDE_OK"} on-error={:put "DUDE_ERROR"}' </dev/null 2>&1)"
        if ! echo "$r" | grep -q "DUDE_OK"; then
            echo "❌ SSH funciona, porém The Dude não está disponível para esse usuário/equipamento."
            return 1
        fi
        echo "✅ The Dude acessível."
    fi

    EQUIP_IDENTITY="$id"
    echo
    echo "======================================================================"
    echo " ✅ ACESSO FUNCIONANDO CORRETAMENTE"
    echo "======================================================================"
    return 0
}

listar_crons_backup(){
    CRON_TMP="$(mktemp)"
    crontab -l 2>/dev/null | grep -E '/etc/scripts/(mkbkp\.sh|dudebkp\.sh)' | \
        while IFS= read -r l; do echo "ROOT|$l"; done >> "$CRON_TMP"
    if [ -f /etc/crontab ]; then
        grep -E '/etc/scripts/(mkbkp\.sh|dudebkp\.sh)' /etc/crontab | \
            while IFS= read -r l; do echo "ETC|$l"; done >> "$CRON_TMP"
    fi
}

parse_regra(){
    local linha="$1" parte rest

    if echo "$linha" | grep -q 'dudebkp.sh'; then
        P_TYPE="DUDE"; P_SCRIPT="$DUDE_SCRIPT"
    else
        P_TYPE="ROUTEROS"; P_SCRIPT="$MK_SCRIPT"
    fi

    parte="${linha#*${P_SCRIPT}}"
    P_IP="$(echo "$parte" | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p')"
    rest="$(echo "$parte" | sed 's/^[[:space:]]*"[^"]*"[[:space:]]*//')"
    P_USER="$(echo "$rest" | sed -n 's/^"\([^"]*\)".*/\1/p')"
    rest="$(echo "$rest" | sed 's/^"[^"]*"[[:space:]]*//')"
    P_PASS="$(echo "$rest" | sed -n 's/^"\([^"]*\)".*/\1/p')"
    rest="$(echo "$rest" | sed 's/^"[^"]*"[[:space:]]*//')"
    P_PORT="$(echo "$rest" | sed -n 's/^"\([^"]*\)".*/\1/p')"
    [ -n "$P_PORT" ] || P_PORT=22
}

obter_horario_regra(){
    local l="$1" m h
    m="$(echo "$l" | awk '{print $1}')"
    h="$(echo "$l" | awk '{print $2}')"
    if echo "$m" | grep -Eq '^[0-9]+$' && echo "$h" | grep -Eq '^[0-9]+$'; then
        printf '%02d:%02d' "$h" "$m"
    else
        echo "$h:$m"
    fi
}

obter_identity_regra(){
    local ip="$1" user="$2" pass="$3" port="${4:-22}" id
    id="$(sshpass -p "$pass" ssh \
        -p "$port" -o ConnectTimeout=4 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=accept-new \
        "$user@$ip" ':put [/system identity get name]' </dev/null 2>/dev/null | tr -d '\r')"
    [ -n "$id" ] || id="⚠️ OFFLINE / NÃO IDENTIFICADO"
    echo "$id"
}

proximo_horario(){
    local tipo="$1" padrao intervalo total min_total

    if [ "$tipo" = "DUDE" ]; then
        intervalo=10; padrao="dudebkp.sh"
    else
        intervalo=2; padrao="mkbkp.sh"
    fi

    total="$({
        crontab -l 2>/dev/null
        cat /etc/crontab 2>/dev/null
    } | grep -E "/etc/scripts/$padrao" | grep -v '^[[:space:]]*#' | wc -l)"

    min_total=$((300 + total * intervalo))
    AUTO_HORA=$((min_total / 60))
    AUTO_MINUTO=$((min_total % 60))

    if [ "$AUTO_HORA" -ge 24 ]; then
        echo "❌ Não há mais horários disponíveis no mesmo dia."
        return 1
    fi

    printf -v AUTO_HORA '%02d' "$AUTO_HORA"
    printf -v AUTO_MINUTO '%02d' "$AUTO_MINUTO"
}

adicionar_cron_automatico(){
    local tipo="$1" script="$2" ip="$3" user="$4" pass="$5" port="$6"
    local existente nova tmp

    existente="$({
        crontab -l 2>/dev/null
        cat /etc/crontab 2>/dev/null
    } | grep -F "$script \"$ip\"" | head -1)"

    if [ -n "$existente" ]; then
        echo "⚠️ Já existe uma regra deste tipo para esse IP:"
        echo "$existente"
        return 2
    fi

    proximo_horario "$tipo" || return 1
    nova="$AUTO_MINUTO $AUTO_HORA * * * $script \"$ip\" \"$user\" \"$pass\" \"$port\" &>/dev/null"

    echo
    echo "⏰ Cadastrando automaticamente às $AUTO_HORA:$AUTO_MINUTO"
    backup_cron

    tmp="$(mktemp)"
    crontab -l 2>/dev/null > "$tmp" || true
    echo "$nova" >> "$tmp"

    if ! crontab "$tmp"; then
        rm -f "$tmp"
        echo "❌ Falha ao instalar a nova regra."
        return 1
    fi
    rm -f "$tmp"

    echo "✅ Regra adicionada automaticamente à CRON."
    aplicar_cron
}

substituir_linha_arquivo(){
    local arquivo="$1" antiga="$2" nova="$3"
    OLD_LINE="$antiga" NEW_LINE="$nova" TARGET_FILE="$arquivo" python3 <<'PY'
import os
from pathlib import Path

p = Path(os.environ["TARGET_FILE"])
old = os.environ["OLD_LINE"]
new = os.environ["NEW_LINE"]

txt = p.read_text()
lines = txt.splitlines(True)
feito = False
out = []
for line in lines:
    raw = line.rstrip("\r\n")
    eol = line[len(raw):]
    if not feito and raw == old:
        out.append(new + (eol or "\n"))
        feito = True
    else:
        out.append(line)

if not feito:
    raise SystemExit(2)

p.write_text("".join(out))
PY
}

substituir_regra(){
    local origem="$1" antiga="$2" nova="$3"
    local tmp

    backup_cron

    if [ "$origem" = "ROOT" ]; then
        tmp="$(mktemp)"
        crontab -l 2>/dev/null > "$tmp" || true
        if ! substituir_linha_arquivo "$tmp" "$antiga" "$nova"; then
            rm -f "$tmp"
            echo "❌ Regra antiga não encontrada."
            return 1
        fi
        crontab "$tmp" || { rm -f "$tmp"; echo "❌ Falha ao aplicar crontab."; return 1; }
        rm -f "$tmp"
    else
        substituir_linha_arquivo /etc/crontab "$antiga" "$nova" || {
            echo "❌ Regra antiga não encontrada em /etc/crontab."
            return 1
        }
    fi

    aplicar_cron
}

remover_regra(){
    local origem="$1" antiga="$2" tmp

    backup_cron

    if [ "$origem" = "ROOT" ]; then
        tmp="$(mktemp)"
        crontab -l 2>/dev/null > "$tmp" || true
        OLD_LINE="$antiga" TARGET_FILE="$tmp" python3 <<'PY'
import os
from pathlib import Path
p = Path(os.environ["TARGET_FILE"])
old = os.environ["OLD_LINE"]
p.write_text("".join(x for x in p.read_text().splitlines(True) if x.rstrip("\r\n") != old))
PY
        crontab "$tmp" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    else
        OLD_LINE="$antiga" TARGET_FILE="/etc/crontab" python3 <<'PY'
import os
from pathlib import Path
p = Path(os.environ["TARGET_FILE"])
old = os.environ["OLD_LINE"]
p.write_text("".join(x for x in p.read_text().splitlines(True) if x.rstrip("\r\n") != old))
PY
    fi

    aplicar_cron
    echo "✅ Backup removido da CRON."
}

montar_regra_com_dados(){
    local origem="$1" linha="$2" ip="$3" user="$4" pass="$5" port="$6"
    local m h resto usuario_etc

    m="$(echo "$linha" | awk '{print $1}')"
    h="$(echo "$linha" | awk '{print $2}')"

    if [ "$origem" = "ROOT" ]; then
        NOVA_REGRA="$m $h * * * $P_SCRIPT \"$ip\" \"$user\" \"$pass\" \"$port\" &>/dev/null"
    else
        usuario_etc="$(echo "$linha" | awk '{print $6}')"
        [ -n "$usuario_etc" ] || usuario_etc="root"
        NOVA_REGRA="$m $h * * * $usuario_etc $P_SCRIPT \"$ip\" \"$user\" \"$pass\" \"$port\" &>/dev/null"
    fi
}

alterar_dados(){
    local origem="$1" linha="$2" modo="$3"
    local ip user pass port v

    parse_regra "$linha"
    ip="$P_IP"; user="$P_USER"; pass="$P_PASS"; port="$P_PORT"

    case "$modo" in
        IP) read -p "👉 Novo IP [$ip]: " v; [ -n "$v" ] && ip="$v" ;;
        USER) read -p "👉 Novo usuário [$user]: " v; [ -n "$v" ] && user="$v" ;;
        PASS) read -p "👉 Nova senha [$pass]: " v; [ -n "$v" ] && pass="$v" ;;
        PORT) read -p "👉 Nova porta [$port]: " v; [ -n "$v" ] && port="$v" ;;
        TODOS)
            read -p "👉 IP [$ip]: " v; [ -n "$v" ] && ip="$v"
            read -p "👉 Usuário [$user]: " v; [ -n "$v" ] && user="$v"
            read -p "👉 Senha [$pass]: " v; [ -n "$v" ] && pass="$v"
            read -p "👉 Porta [$port]: " v; [ -n "$v" ] && port="$v"
            ;;
    esac

    echo
    echo "🔎 Testando a NOVA configuração antes de salvar..."
    if ! testar_equipamento "$P_TYPE" "$ip" "$user" "$pass" "$port"; then
        echo
        echo "❌ A nova configuração NÃO foi gravada."
        echo "✅ A configuração antiga continua intacta."
        return 1
    fi

    montar_regra_com_dados "$origem" "$linha" "$ip" "$user" "$pass" "$port"

    echo
    echo "Atual: $linha"
    echo "Nova : $NOVA_REGRA"
    read -p "👉 Confirma salvar? [S/n]: " v
    case "$v" in n|N) return 1 ;; esac

    substituir_regra "$origem" "$linha" "$NOVA_REGRA" || return 1
    REGRA_ATUALIZADA="$NOVA_REGRA"
    echo "✅ Dados atualizados e CRON aplicada."
}

alterar_horario(){
    local origem="$1" linha="$2" atual ah am nh nm resto usuario_etc nova c

    atual="$(obter_horario_regra "$linha")"
    ah="${atual%%:*}"
    am="${atual##*:}"

    echo
    echo "Horário atual: $atual"

    while true; do
        read -p "👉 Nova hora [$ah]: " nh
        [ -n "$nh" ] || nh="$ah"
        read -p "👉 Novo minuto [$am]: " nm
        [ -n "$nm" ] || nm="$am"

        if echo "$nh" | grep -Eq '^[0-9]{1,2}$' &&
           echo "$nm" | grep -Eq '^[0-9]{1,2}$' &&
           [ "$nh" -ge 0 ] && [ "$nh" -le 23 ] &&
           [ "$nm" -ge 0 ] && [ "$nm" -le 59 ]; then
            break
        fi
        echo "❌ Horário inválido. Hora 00-23 e minuto 00-59."
    done

    printf -v nh '%02d' "$nh"
    printf -v nm '%02d' "$nm"

    if [ "$origem" = "ROOT" ]; then
        resto="$(echo "$linha" | awk '{for(i=6;i<=NF;i++) printf "%s%s",$i,(i<NF?OFS:ORS)}')"
        nova="$nm $nh * * * $resto"
    else
        resto="$(echo "$linha" | awk '{for(i=7;i<=NF;i++) printf "%s%s",$i,(i<NF?OFS:ORS)}')"
        usuario_etc="$(echo "$linha" | awk '{print $6}')"
        nova="$nm $nh * * * $usuario_etc $resto"
    fi

    echo
    echo "Atual: $linha"
    echo "Nova : $nova"
    read -p "👉 Confirma alteração? [S/n]: " c
    case "$c" in n|N) return 1 ;; esac

    substituir_regra "$origem" "$linha" "$nova" || return 1
    REGRA_ATUALIZADA="$nova"
    echo "✅ Horário alterado e CRON aplicada."
}

adicionar(){
    local tipo="$1" script ip user pass port primeiro op

    if [ "$tipo" = "ROUTEROS" ]; then script="$MK_SCRIPT"; else script="$DUDE_SCRIPT"; fi
    [ -x "$script" ] || { echo "❌ Script não encontrado: $script"; return; }

    while true; do
        cabecalho
        echo
        echo "➕ NOVO BACKUP $tipo"
        echo
        read -p "👉 IP do RouterOS: " ip
        read -p "👉 Usuário SSH: " user
        read -p "👉 Senha SSH: " pass
        read -p "👉 Porta SSH [22]: " port
        [ -n "$port" ] || port=22

        if testar_equipamento "$tipo" "$ip" "$user" "$pass" "$port"; then
            break
        fi

        echo
        read -p "👉 Corrigir os dados e tentar novamente? [S/n]: " op
        case "$op" in n|N) return ;; esac
    done

    echo
    echo "✅ Equipamento validado: $EQUIP_IDENTITY"
    read -p "👉 Fazer o primeiro backup AGORA? [S/n]: " primeiro
    case "$primeiro" in
        n|N) ;;
        *)
            if ! "$script" "$ip" "$user" "$pass" "$port"; then
                echo "❌ Primeiro backup falhou. A CRON não será cadastrada."
                return
            fi
            ;;
    esac

    if adicionar_cron_automatico "$tipo" "$script" "$ip" "$user" "$pass" "$port"; then
        echo
        echo "======================================================================"
        echo " ✅ BACKUP CADASTRADO E FUNCIONANDO"
        echo "======================================================================"
    fi
}

listar_backups_detalhado(){
    listar_crons_backup
    local i=0 item origem linha id hor

    while IFS='|' read -r origem linha; do
        [ -n "$linha" ] || continue
        i=$((i+1))
        parse_regra "$linha"
        hor="$(obter_horario_regra "$linha")"
        id="$(obter_identity_regra "$P_IP" "$P_USER" "$P_PASS" "$P_PORT")"

        echo
        echo "----------------------------------------------------------------------"
        echo "[$i] $P_TYPE"
        echo "    Identity : $id"
        echo "    IP       : $P_IP"
        echo "    Usuário  : $P_USER"
        echo "    Senha    : $P_PASS"
        echo "    Porta    : $P_PORT"
        echo "    Horário  : $hor"
        [ "$origem" = "ROOT" ] && echo "    Origem   : crontab root" || echo "    Origem   : /etc/crontab"
    done < "$CRON_TMP"

    rm -f "$CRON_TMP"
    [ "$i" -gt 0 ] || echo "Nenhuma regra encontrada."
}

gerenciar_regra(){
    local i item origem linha id hor esc idx x sc c
    while true; do
        cabecalho
        listar_crons_backup
        mapfile -t REGRAS < "$CRON_TMP"
        rm -f "$CRON_TMP"

        if [ "${#REGRAS[@]}" -eq 0 ]; then
            echo
            echo "Nenhum backup cadastrado."
            return
        fi

        echo
        echo "======================================================================"
        echo " 🔐 BACKUPS CADASTRADOS"
        echo "======================================================================"

        i=1
        for item in "${REGRAS[@]}"; do
            origem="${item%%|*}"
            linha="${item#*|}"
            parse_regra "$linha"
            hor="$(obter_horario_regra "$linha")"
            id="$(obter_identity_regra "$P_IP" "$P_USER" "$P_PASS" "$P_PORT")"

            echo
            echo "----------------------------------------------------------------------"
            echo "[$i] $P_TYPE"
            echo "    Identity : $id"
            echo "    IP       : $P_IP"
            echo "    Usuário  : $P_USER"
            echo "    Senha    : $P_PASS"
            echo "    Porta    : $P_PORT"
            echo "    Horário  : $hor"
            [ "$origem" = "ROOT" ] && echo "    Origem   : crontab root" || echo "    Origem   : /etc/crontab"
            i=$((i+1))
        done

        echo
        echo "[0] ↩️ Voltar"
        read -p "👉 Escolha o backup: " esc
        [ "$esc" = "0" ] && return
        echo "$esc" | grep -Eq '^[0-9]+$' || continue
        idx=$((esc-1))
        [ "$idx" -ge 0 ] && [ "$idx" -lt "${#REGRAS[@]}" ] || continue

        item="${REGRAS[$idx]}"
        origem="${item%%|*}"
        linha="${item#*|}"

        while true; do
            parse_regra "$linha"
            hor="$(obter_horario_regra "$linha")"
            id="$(obter_identity_regra "$P_IP" "$P_USER" "$P_PASS" "$P_PORT")"

            cabecalho
            echo
            echo "======================================================================"
            echo " CONFIGURAÇÃO SELECIONADA"
            echo "======================================================================"
            echo "Tipo     : $P_TYPE"
            echo "Identity : $id"
            echo "IP       : $P_IP"
            echo "Usuário  : $P_USER"
            echo "Senha    : $P_PASS"
            echo "Porta    : $P_PORT"
            echo "Horário  : $hor"
            [ "$origem" = "ROOT" ] && echo "Origem   : crontab root" || echo "Origem   : /etc/crontab"
            echo
            echo " [1] 🔎 TESTAR CONEXÃO / CREDENCIAIS"
            echo
            echo " [2] 🌐 Alterar IP"
            echo " [3] 👤 Alterar usuário"
            echo " [4] 🔑 Alterar senha"
            echo " [5] 🔌 Alterar porta SSH"
            echo " [6] ✏️ Alterar TODOS os dados de acesso"
            echo " [7] ⏰ Alterar horário"
            echo
            echo " [8] 💾 Executar backup AGORA"
            echo " [9] 🗑️ Remover este backup"
            echo
            echo " [0] ↩️ Voltar"
            echo
            read -p "👉 Opção: " x

            case "$x" in
                1) testar_equipamento "$P_TYPE" "$P_IP" "$P_USER" "$P_PASS" "$P_PORT"; pause ;;
                2) alterar_dados "$origem" "$linha" IP && linha="$REGRA_ATUALIZADA"; pause ;;
                3) alterar_dados "$origem" "$linha" USER && linha="$REGRA_ATUALIZADA"; pause ;;
                4) alterar_dados "$origem" "$linha" PASS && linha="$REGRA_ATUALIZADA"; pause ;;
                5) alterar_dados "$origem" "$linha" PORT && linha="$REGRA_ATUALIZADA"; pause ;;
                6) alterar_dados "$origem" "$linha" TODOS && linha="$REGRA_ATUALIZADA"; pause ;;
                7) alterar_horario "$origem" "$linha" && linha="$REGRA_ATUALIZADA"; pause ;;
                8)
                    [ "$P_TYPE" = "DUDE" ] && sc="$DUDE_SCRIPT" || sc="$MK_SCRIPT"
                    "$sc" "$P_IP" "$P_USER" "$P_PASS" "$P_PORT"
                    pause
                    ;;
                9)
                    read -p "👉 Confirma REMOVER $id ($P_IP)? [s/N]: " c
                    case "$c" in
                        s|S) remover_regra "$origem" "$linha"; pause; break ;;
                    esac
                    ;;
                0) break ;;
            esac
        done
    done
}

testar_todos_conexao(){
    listar_crons_backup
    local t=0 ok=0 er=0 origem linha
    while IFS='|' read -r origem linha; do
        [ -n "$linha" ] || continue
        t=$((t+1))
        parse_regra "$linha"
        echo
        echo "[$t] $P_TYPE - $P_IP"
        if testar_equipamento "$P_TYPE" "$P_IP" "$P_USER" "$P_PASS" "$P_PORT"; then
            ok=$((ok+1))
        else
            er=$((er+1))
        fi
    done < "$CRON_TMP"
    rm -f "$CRON_TMP"

    echo
    echo "======================================================================"
    echo " Total: $t | ✅ OK: $ok | ❌ ERRO: $er"
    echo "======================================================================"
}

executar_todos(){
    listar_crons_backup
    local t=0 ok=0 er=0 origem linha sc
    while IFS='|' read -r origem linha; do
        [ -n "$linha" ] || continue
        t=$((t+1))
        parse_regra "$linha"
        [ "$P_TYPE" = "DUDE" ] && sc="$DUDE_SCRIPT" || sc="$MK_SCRIPT"

        echo
        echo "[$t] Executando $P_TYPE - $P_IP"
        if "$sc" "$P_IP" "$P_USER" "$P_PASS" "$P_PORT"; then
            ok=$((ok+1))
        else
            er=$((er+1))
        fi
    done < "$CRON_TMP"
    rm -f "$CRON_TMP"

    echo
    echo "======================================================================"
    echo " Total: $t | ✅ OK: $ok | ❌ ERRO: $er"
    echo "======================================================================"
}

reorganizar_horarios(){
    listar_crons_backup
    mapfile -t ITENS < "$CRON_TMP"
    rm -f "$CRON_TMP"

    [ "${#ITENS[@]}" -gt 0 ] || { echo "Nenhuma regra encontrada."; return; }

    local item origem linha tipo cont_mk=0 cont_dude=0 min_total nh nm resto usuario nova
    local -a ORIGINAIS NOVAS ORIGENS

    echo
    echo "======================================================================"
    echo " ⏰ REORGANIZAÇÃO DOS HORÁRIOS"
    echo "======================================================================"
    echo "RouterOS: 05:00, 05:02, 05:04..."
    echo "Dude DB : 05:00, 05:10, 05:20..."
    echo

    for item in "${ITENS[@]}"; do
        origem="${item%%|*}"
        linha="${item#*|}"
        parse_regra "$linha"
        tipo="$P_TYPE"

        if [ "$tipo" = "DUDE" ]; then
            min_total=$((300 + cont_dude * 10))
            cont_dude=$((cont_dude+1))
        else
            min_total=$((300 + cont_mk * 2))
            cont_mk=$((cont_mk+1))
        fi

        nh=$((min_total / 60))
        nm=$((min_total % 60))
        printf -v nh '%02d' "$nh"
        printf -v nm '%02d' "$nm"

        if [ "$origem" = "ROOT" ]; then
            resto="$(echo "$linha" | awk '{for(i=6;i<=NF;i++) printf "%s%s",$i,(i<NF?OFS:ORS)}')"
            nova="$nm $nh * * * $resto"
        else
            usuario="$(echo "$linha" | awk '{print $6}')"
            resto="$(echo "$linha" | awk '{for(i=7;i<=NF;i++) printf "%s%s",$i,(i<NF?OFS:ORS)}')"
            nova="$nm $nh * * * $usuario $resto"
        fi

        ORIGENS+=("$origem")
        ORIGINAIS+=("$linha")
        NOVAS+=("$nova")

        echo "$tipo | $(obter_horario_regra "$linha") → $(obter_horario_regra "$nova") | $P_IP"
    done

    echo
    read -p "👉 Aplicar essa reorganização? [s/N]: " c
    case "$c" in s|S) ;; *) echo "Cancelado."; return ;; esac

    backup_cron

    local i
    for ((i=0; i<${#ORIGINAIS[@]}; i++)); do
        if [ "${ORIGENS[$i]}" = "ROOT" ]; then
            tmp="$(mktemp)"
            crontab -l 2>/dev/null > "$tmp" || true
            substituir_linha_arquivo "$tmp" "${ORIGINAIS[$i]}" "${NOVAS[$i]}" || { rm -f "$tmp"; continue; }
            crontab "$tmp"
            rm -f "$tmp"
        else
            substituir_linha_arquivo /etc/crontab "${ORIGINAIS[$i]}" "${NOVAS[$i]}" || true
        fi
    done

    aplicar_cron
    echo "✅ Horários reorganizados."
}

status_resumido(){
    [ -x "$MK_SCRIPT" ] && MKSTATUS="✅ instalado" || MKSTATUS="❌ ausente"
    [ -x "$DUDE_SCRIPT" ] && DUDESTATUS="✅ instalado" || DUDESTATUS="❌ ausente"

    CRON_MK="$({
        crontab -l 2>/dev/null
        cat /etc/crontab 2>/dev/null
    } | grep -c '/etc/scripts/mkbkp.sh')"

    CRON_DUDE="$({
        crontab -l 2>/dev/null
        cat /etc/crontab 2>/dev/null
    } | grep -c '/etc/scripts/dudebkp.sh')"

    TGSTATUS="❌ não configurado"
    if [ -f "$TGCONF" ]; then
        unset TOKEN CHATID
        . "$TGCONF"
        if [ -n "${TOKEN:-}" ] && [ -n "${CHATID:-}" ]; then
            local c
            c="$(curl -s --connect-timeout 3 -d "chat_id=$CHATID" "https://api.telegram.org/bot${TOKEN}/getChat")"
            if echo "$c" | jq -e '.ok==true' >/dev/null 2>&1; then
                TGSTATUS="✅ $(echo "$c" | jq -r '.result.title // .result.username // .result.first_name // "SEM NOME"')"
            else
                TGSTATUS="⚠️ configurado com erro"
            fi
        fi
    fi
}

apt_buster_fallback(){
    local resp dataapt
    echo
    echo "======================================================================"
    echo " ⚠️ APT UPDATE FALHOU"
    echo "======================================================================"
    echo
    echo "Este MK-AUTH pode estar usando Debian Buster com repositórios expirados."
    echo "Será criado backup do sources.list antes de qualquer alteração."
    echo
    echo "⚠️ SEGURANÇA MK-AUTH:"
    echo "   NUNCA será executado apt upgrade, apt-get upgrade,"
    echo "   dist-upgrade ou full-upgrade."
    echo
    read -p "👉 Aplicar archive.debian.org para Buster? [S/n]: " resp
    case "$resp" in n|N) return 1 ;; esac

    dataapt="$(date +%Y%m%d-%H%M%S)"
    if [ -f /etc/apt/sources.list ]; then
        cp -a /etc/apt/sources.list "/etc/apt/sources.list.bkp-${dataapt}" || return 1
        echo "✅ Backup: /etc/apt/sources.list.bkp-${dataapt}"
    fi

    cat > /etc/apt/sources.list <<'EOF_APT_BUSTER_MANAGER'
deb [trusted=yes] http://archive.debian.org/debian buster main contrib non-free
deb [trusted=yes] http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF_APT_BUSTER_MANAGER

    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/99archive-buster <<'EOF_APT_CONF_MANAGER'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
EOF_APT_CONF_MANAGER

    apt-get -o Acquire::Check-Valid-Until=false update
}

apt_update_seguro(){
    apt-get update && return 0
    apt_buster_fallback
}

auditoria_mostrar(){
    local problemas=0
    cabecalho
    echo
    for p in sshpass ssh scp curl zip jq python3; do
        if command -v "$p" >/dev/null 2>&1; then
            echo "✅ $p"
        else
            echo "❌ $p"
            problemas=$((problemas+1))
        fi
    done
    [ -x "$MK_SCRIPT" ] && echo "✅ $MK_SCRIPT" || { echo "❌ $MK_SCRIPT"; problemas=$((problemas+1)); }
    [ -x "$DUDE_SCRIPT" ] && echo "✅ $DUDE_SCRIPT" || { echo "❌ $DUDE_SCRIPT"; problemas=$((problemas+1)); }
    [ -x "$MANAGER" ] && echo "✅ $MANAGER" || { echo "❌ $MANAGER"; problemas=$((problemas+1)); }
    [ -L /usr/local/bin/bkp ] && echo "✅ /usr/local/bin/bkp" || { echo "❌ /usr/local/bin/bkp"; problemas=$((problemas+1)); }
    [ -L /usr/local/bin/backup-manager ] && echo "✅ /usr/local/bin/backup-manager" || { echo "❌ /usr/local/bin/backup-manager"; problemas=$((problemas+1)); }
    pgrep -x cron >/dev/null && echo "✅ cron em execução" || { echo "❌ cron parado"; problemas=$((problemas+1)); }

    status_resumido
    echo
    echo "Telegram : $TGSTATUS"
    echo "RouterOS : $CRON_MK regra(s)"
    echo "Dude DB  : $CRON_DUDE regra(s)"
    echo
    return "$problemas"
}

auditoria(){
    local rc resp faltando=""
    auditoria_mostrar
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "======================================================================"
        echo " ✅ AUDITORIA CONCLUÍDA - NENHUM PROBLEMA ENCONTRADO"
        echo "======================================================================"
        return 0
    fi

    echo "======================================================================"
    echo " ⚠️ AUDITORIA ENCONTROU $rc PROBLEMA(S)"
    echo "======================================================================"
    read -p "👉 Corrigir automaticamente o que for seguro corrigir? [S/n]: " resp
    case "$resp" in n|N) return 1 ;; esac

    backup_crons

    for p in sshpass curl zip unzip jq python3 ssh scp ssh-keygen; do
        command -v "$p" >/dev/null 2>&1 || faltando="$faltando $p"
    done
    if [ -n "$faltando" ]; then
        echo "📦 Dependências ausentes:$faltando"
        if apt_update_seguro; then
            echo "📦 Instalando SOMENTE dependências necessárias..."
            apt-get install -y sshpass curl zip unzip jq python3 openssh-client cron || true
        else
            echo "❌ APT não corrigido. Dependências não foram instaladas."
        fi
    fi

    chmod +x "$MK_SCRIPT" "$DUDE_SCRIPT" "$MANAGER" 2>/dev/null || true
    ln -sf "$MANAGER" /usr/local/bin/bkp 2>/dev/null || true
    ln -sf "$MANAGER" /usr/local/bin/backup-manager 2>/dev/null || true

    if ! pgrep -x cron >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || /etc/init.d/cron start >/dev/null 2>&1 || true
    else
        service cron restart >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi

    echo
    echo "🔎 Revalidando instalação..."
    echo
    auditoria_mostrar
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "======================================================================"
        echo " ✅ AUDITORIA / CORREÇÃO CONCLUÍDA"
        echo " Nenhum problema pendente."
        echo "======================================================================"
    else
        echo "======================================================================"
        echo " ⚠️ Ainda existem $rc problema(s) que exigem análise manual."
        echo " Telegram e regras de backup NÃO foram alterados automaticamente."
        echo "======================================================================"
    fi
}

if [ ! -f "$TGCONF" ]; then
    cabecalho
    inicializar_telegram
fi

while true; do
    status_resumido
    cabecalho
    echo
    echo " Telegram : $TGSTATUS"
    echo " MikroTik : $MKSTATUS | $CRON_MK regra(s)"
    echo " Dude DB  : $DUDESTATUS | $CRON_DUDE regra(s)"
    echo
    echo "----------------------------------------------------------------------"
    echo " [1] ➕ Adicionar novo MikroTik / RouterOS"
    echo " [2] ➕ Adicionar novo The Dude DB"
    echo
    echo " [3] 🔎 Testar CONEXÃO de todos os backups"
    echo " [4] 💾 Executar BACKUP COMPLETO de todos"
    echo
    echo " [5] 📲 Testar Telegram"
    echo " [6] 🔧 Alterar Token / Chat ID"
    echo
    echo " [7] 📋 Listar backups encontrados"
    echo " [8] 🔐 Gerenciar / alterar / remover backup"
    echo " [9] 🔍 Auditar instalação"
    echo
    echo "[10] ⏰ Reorganizar horários de TODOS os backups"
    echo
    echo " [0] 🚪 Sair"
    echo
    read -p "👉 Escolha uma opção: " op

    case "$op" in
        1) adicionar ROUTEROS; pause ;;
        2) adicionar DUDE; pause ;;
        3) testar_todos_conexao; pause ;;
        4) executar_todos; pause ;;
        5)
            if [ -f "$TGCONF" ]; then
                unset TOKEN CHATID
                . "$TGCONF"
                testar_telegram_dados "$TOKEN" "$CHATID" sim
            else
                echo "❌ Telegram não configurado."
            fi
            pause
            ;;
        6) configurar_telegram; pause ;;
        7) listar_backups_detalhado; pause ;;
        8) gerenciar_regra ;;
        9) auditoria; pause ;;
        10) reorganizar_horarios; pause ;;
        0) exit 0 ;;
    esac
done

MANAGER_EOF

echo
echo "🔎 Validando sintaxe dos três scripts..."
for F in "$TMPDIR/mkbkp.sh" "$TMPDIR/dudebkp.sh" "$TMPDIR/backup-manager.sh"; do
    if ! bash -n "$F"; then
        echo "❌ Erro de sintaxe em $F"
        exit 1
    fi
done
echo "✅ Sintaxe OK."

echo
echo "📜 Instalando scripts..."

# Para máquinas já em produção, preserva os backups anteriores, mas instala
# a versão final padronizada depois de criar cópia .bak_TIMESTAMP.
cp "$TMPDIR/mkbkp.sh" "$MK"
cp "$TMPDIR/dudebkp.sh" "$DUDE"
cp "$TMPDIR/backup-manager.sh" "$MANAGER"

chmod 700 "$MK" "$DUDE" "$MANAGER"

ln -sf "$MANAGER" /usr/local/bin/bkp
ln -sf "$MANAGER" /usr/local/bin/backup-manager

echo "✅ $MK"
echo "✅ $DUDE"
echo "✅ $MANAGER"
echo "✅ Comandos globais: bkp e backup-manager"

echo
echo "📲 Procurando configuração Telegram existente..."
if [ -f "$TG" ]; then
    echo "✅ Configuração central existente preservada: $TG"
    chmod 600 "$TG"
else
    echo "ℹ️ O gerenciador vai procurar credenciais nos scripts antigos/enviaBkp"
    echo "   e, se necessário, solicitar Token e Chat ID ao abrir pela primeira vez."
fi

echo
echo "🔄 Aplicando/reiniciando CRON..."
if command -v service >/dev/null 2>&1; then
    service cron restart >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
elif [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron start >/dev/null 2>&1 || true
fi

sleep 1

if pgrep -x cron >/dev/null 2>&1; then
    echo "✅ CRON funcionando."
else
    echo "⚠️ CRON não foi detectada. Tentando iniciar..."
    service cron start >/dev/null 2>&1 || /etc/init.d/cron start >/dev/null 2>&1 || true
fi

echo
echo "======================================================================"
echo " ✅ INSTALAÇÃO FINAL CONCLUÍDA"
echo "======================================================================"
echo
echo "Abra o gerenciador com:"
echo
echo "    bkp"
echo
echo "Recursos incluídos:"
echo " - RouterOS e Dude DB"
echo " - primeiro backup opcional"
echo " - registro automático na CRON"
echo " - RouterOS: 05:00, 05:02, 05:04..."
echo " - Dude DB : 05:00, 05:10, 05:20..."
echo " - alteração individual de horário"
echo " - reorganização geral de horários"
echo " - visualização de IP/usuário/senha/porta/Identity/horário"
echo " - teste de conexão individual e geral"
echo " - novas credenciais testadas ANTES de salvar"
echo " - tratamento de chave SSH alterada com confirmação"
echo " - backup de segurança antes de alterar CRON/scripts"
echo " - reinício e validação automática do serviço cron"
echo "======================================================================"
