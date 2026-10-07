#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BASE=/opt/backup-manager-v3
# V3 usa interface de terminal simples; dialog permanece desativado.
HAS_DIALOG=0
mkdir -p "$BASE"/{clientes,config,logs,backups,tmp}
chmod 700 "$BASE" "$BASE"/{clientes,config,logs,backups,tmp}
need(){ command -v "$1" >/dev/null || { echo "Dependencia ausente: $1"; exit 1; }; }
for x in ssh sshpass scp curl jq flock zip; do need "$x"; done
valid_id(){ [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }
read_key(){
 local __var="$1" __prompt="$2" __key
 printf '%s' "$__prompt"
 IFS= read -r -s -n1 __key || return 1
 printf '%s\n' "$__key"
 printf -v "$__var" '%s' "$__key"
}
read_secret(){ local var="$1"; read -r -s -p 'Senha (oculta): ' "$var"; echo; }
add_client(){
 local id token chat result tmp
 if (( HAS_DIALOG )); then
   tmp=$(mktemp "$BASE/tmp/client-form.XXXXXXXX") || return 1
   chmod 600 "$tmp"
   # O token fica mascarado durante a digitacao.
   if ! dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'CADASTRAR CLIENTE' \
     --ok-label 'Proximo' --cancel-label 'Cancelar' \
     --inputbox 'Identificador do cliente (letras, numeros, - ou _):' 10 70 2>"$tmp"; then rm -f "$tmp"; return 0; fi
   id=$(cat "$tmp")
   if ! valid_id "$id"; then rm -f "$tmp"; ui_message 'Identificador invalido. Use apenas letras, numeros, - ou _.'; return 0; fi
   if [[ -e "$BASE/clientes/$id" ]]; then rm -f "$tmp"; ui_message "O cliente $id ja existe."; return 0; fi
   if ! dialog --backtitle 'BACKUP MANAGER V3 BETA' --title "TELEGRAM - $id" \
     --ok-label 'Proximo' --cancel-label 'Cancelar' \
     --insecure --passwordbox 'Bot Token Telegram (pode deixar vazio):' 10 76 2>"$tmp"; then rm -f "$tmp"; return 0; fi
   token=$(cat "$tmp")
   if ! dialog --backtitle 'BACKUP MANAGER V3 BETA' --title "TELEGRAM - $id" \
     --ok-label 'Revisar' --cancel-label 'Cancelar' \
     --inputbox 'Chat ID Telegram (pode deixar vazio):' 10 76 2>"$tmp"; then rm -f "$tmp"; return 0; fi
   chat=$(cat "$tmp")
   rm -f "$tmp"
   if ! dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'CONFIRMAR CADASTRO' \
     --yes-label 'Salvar' --no-label 'Cancelar' \
     --yesno "Cliente: $id\nTelegram: $([[ -n "$token" && -n "$chat" ]] && echo 'Configurado' || echo 'Pendente')\n\nDeseja salvar o cadastro?" 12 70; then return 0; fi
 else
   echo
   echo '========== ADICIONAR CLIENTE =========='
   echo 'Digite 0 em qualquer campo para cancelar e voltar.'
   echo
   read -r -p 'Identificador do cliente (letras/numeros/-/_): ' id
   [[ "$id" == 0 ]] && { echo 'Cadastro cancelado.'; return; }
   valid_id "$id" || { echo 'Identificador invalido'; return; }
   [[ ! -e "$BASE/clientes/$id" ]] || { echo 'Cliente ja existe'; return; }
   read -r -s -p 'Bot Token Telegram (oculto; vazio para depois): ' token; echo
   [[ "$token" == 0 ]] && { echo 'Cadastro cancelado.'; return; }
   read -r -p 'Chat ID Telegram: ' chat
   [[ "$chat" == 0 ]] && { echo 'Cadastro cancelado.'; return; }
 fi
 mkdir -m 700 "$BASE/clientes/$id" || return 1
 if ! jq -n --arg token "$token" --arg chat "$chat" '{token:$token,chat:$chat}' > "$BASE/clientes/$id/telegram.json"; then
   rm -f "$BASE/clientes/$id/telegram.json"
   rmdir "$BASE/clientes/$id" || true
   ui_message 'Erro ao salvar configuracao Telegram.'
   return 1
 fi
 chmod 600 "$BASE/clientes/$id/telegram.json"
 ui_message "Cliente $id cadastrado com sucesso."
}
list_clients(){ find "$BASE/clientes" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }
show_clients(){
 local -a clients=()
 local i id count status token chat
 mapfile -t clients < <(list_clients)
 echo
 echo '=============================================================='
 echo '                  BACKUP MANAGER V3 - CLIENTES'
 echo '=============================================================='
 printf ' %-4s %-22s %-13s %s\n' 'N' 'CLIENTE' 'EQUIPAMENTOS' 'TELEGRAM'
 echo '--------------------------------------------------------------'
 if (( ${#clients[@]} == 0 )); then
   echo ' Nenhum cliente cadastrado.'
 else
   for i in "${!clients[@]}"; do
     id="${clients[i]}"
     count=$(find "$BASE/clientes/$id" -maxdepth 1 -type f -name '*.json' ! -name 'telegram.json' | wc -l)
     status='Nao configurado'
     if [[ -f "$BASE/clientes/$id/telegram.json" ]]; then
       token=$(jq -r '.token // ""' "$BASE/clientes/$id/telegram.json" 2>/dev/null || true)
       chat=$(jq -r '.chat // ""' "$BASE/clientes/$id/telegram.json" 2>/dev/null || true)
       if [[ -n "$token" && -n "$chat" ]]; then status='Configurado'; fi
     fi
     printf ' %-4d %-22.22s %-13s %s\n' "$((i+1))" "$id" "$count" "$status"
   done
 fi
 echo '--------------------------------------------------------------'
 printf ' Total de clientes: %d\n' "${#clients[@]}"
 echo '=============================================================='
 if (( ${#clients[@]} == 0 )); then
   echo '[ENTER] Voltar'
   read -r
   return
 fi
 echo
 echo 'Digite o numero do cliente para testar o Telegram.'
 echo '[0] Voltar'
 local choice selected
 while :; do
   read -r -p 'Cliente: ' choice
   [[ "$choice" == 0 ]] && return
   if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#clients[@]})); then
     selected="${clients[choice-1]}"
     echo
     echo "Testando Telegram do cliente $selected..."
     if notify "$selected" "TESTE BACKUP MANAGER V3 | Cliente: $selected | Telegram funcionando corretamente."; then
       echo "OK - Telegram do cliente $selected funcionando."
       echo
       echo '[ENTER] Voltar para a lista'
       read -r
       return
     else
       echo "FALHA - Telegram do cliente $selected nao respondeu corretamente."
       echo
       echo '[1] Corrigir Bot Token e Chat ID'
       echo '[2] Testar novamente'
       echo '[0] Voltar para a lista'
       local action newtoken newchat
       while :; do
         read_key action 'Opcao: '
         case "$action" in
           1)
             read -r -s -p 'Novo Bot Token (oculto) [0 cancela]: ' newtoken; echo
             [[ "$newtoken" == 0 ]] && continue
             read -r -p 'Novo Chat ID [0 cancela]: ' newchat
             [[ "$newchat" == 0 ]] && continue
             jq --arg token "$newtoken" --arg chat "$newchat" '.token=$token | .chat=$chat' "$BASE/clientes/$selected/telegram.json" > "$BASE/tmp/tg.$" &&
               mv "$BASE/tmp/tg.$" "$BASE/clientes/$selected/telegram.json"
             chmod 600 "$BASE/clientes/$selected/telegram.json"
             echo 'Dados atualizados. Testando novamente...'
             if notify "$selected" "TESTE BACKUP MANAGER V3 | Cliente: $selected | Telegram funcionando corretamente."; then
               echo "OK - Telegram do cliente $selected funcionando."
               echo '[ENTER] Voltar para a lista'; read -r; return
             fi
             echo 'FALHA - ainda nao foi possivel enviar ao Telegram.'
             ;;
           2)
             if notify "$selected" "TESTE BACKUP MANAGER V3 | Cliente: $selected | Telegram funcionando corretamente."; then
               echo "OK - Telegram do cliente $selected funcionando."
               echo '[ENTER] Voltar para a lista'; read -r; return
             fi
             echo 'FALHA - Telegram continua sem responder corretamente.'
             ;;
           0) return;;
           *) echo 'Opcao invalida.';;
         esac
       done
     fi
   fi
   echo 'Cliente invalido.'
 done
}
select_client(){
 local -a clients=()
 local i choice
 mapfile -t clients < <(list_clients)
 if (( ${#clients[@]} == 0 )); then echo 'Nenhum cliente cadastrado.'; return 1; fi
 if (( HAS_DIALOG )); then
   local -a choices=()
   for i in "${clients[@]}"; do choices+=("$i" 'Selecionar cliente'); done
   SELECTED_CLIENT=$(dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title 'SELECIONAR CLIENTE' --menu 'Escolha pelas setas e ENTER:' 18 75 12 "${choices[@]}") || return 1
   return 0
 fi
 echo
 echo '========== SELECIONAR CLIENTE =========='
 for i in "${!clients[@]}"; do printf '[%d] %s\n' "$((i+1))" "${clients[i]}"; done
 echo '[0] Voltar'
 echo '========================================'
 while :; do
   read_key choice 'Escolha o numero: '
   [[ "$choice" == 0 ]] && return 1
   if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#clients[@]} )); then
     SELECTED_CLIENT="${clients[10#$choice-1]}"
     return 0
   fi
   echo 'Opcao invalida. Selecione um numero da lista.'
 done
}
add_device(){
 local id name ip port username password file result rc opt tmp err shorterr
 select_client || return
 id="$SELECTED_CLIENT"

 if (( HAS_DIALOG )); then
   tmp=$(mktemp "$BASE/tmp/device-form.XXXXXXXX") || return 1
   err=$(mktemp "$BASE/tmp/device-error.XXXXXXXX") || { rm -f "$tmp"; return 1; }
   chmod 600 "$tmp" "$err"

   dialog --backtitle 'BACKUP MANAGER V3 BETA' --title "NOVO MIKROTIK - $id" --ok-label 'Proximo' --cancel-label 'Cancelar' --inputbox 'Nome do dispositivo:' 10 72 2>"$tmp" || { rm -f "$tmp" "$err"; return; }
   name=$(cat "$tmp")
   valid_id "$name" || { rm -f "$tmp" "$err"; ui_message 'Nome invalido. Use apenas letras, numeros, - ou _.'; return; }
   file="$BASE/clientes/$id/$name.json"
   [[ ! -e "$file" ]] || { rm -f "$tmp" "$err"; ui_message "O dispositivo $name ja esta cadastrado em $id."; return; }

   dialog --backtitle 'BACKUP MANAGER V3 BETA' --title "$name - ENDERECO" --ok-label 'Proximo' --cancel-label 'Cancelar' --inputbox 'IP ou hostname:' 10 72 2>"$tmp" || { rm -f "$tmp" "$err"; return; }
   ip=$(cat "$tmp")
   dialog --backtitle 'BACKUP MANAGER V3 BETA' --title "$name - SSH" --ok-label 'Proximo' --cancel-label 'Cancelar' --inputbox 'Porta SSH:' 10 60 '22' 2>"$tmp" || { rm -f "$tmp" "$err"; return; }
   port=$(cat "$tmp"); port=${port:-22}
   dialog --backtitle 'BACKUP MANAGER V3 BETA' --title "$name - SSH" --ok-label 'Proximo' --cancel-label 'Cancelar' --inputbox 'Usuario SSH:' 10 65 2>"$tmp" || { rm -f "$tmp" "$err"; return; }
   username=$(cat "$tmp")
   dialog --backtitle 'BACKUP MANAGER V3 BETA' --title "$name - SSH" --ok-label 'Testar conexao' --cancel-label 'Cancelar' --insecure --passwordbox 'Senha SSH:' 10 65 2>"$tmp" || { rm -f "$tmp" "$err"; return; }
   password=$(cat "$tmp")

   while :; do
     if ! [[ "$port" =~ ^[0-9]+$ ]] || ((10#$port<1 || 10#$port>65535)) || [[ -z "$ip" || -z "$username" ]]; then
       ui_message 'IP/hostname, usuario ou porta SSH invalidos.'
       opt=$(dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title 'CORRIGIR DADOS' --cancel-label 'Cancelar' --menu 'Selecione o campo para corrigir:' 17 72 8 2 'IP ou hostname' 3 'Usuario SSH' 4 'Senha SSH' 5 'Porta SSH') || { rm -f "$tmp" "$err"; return; }
     else
       dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'TESTANDO CONEXAO' --infobox "Conectando em $ip:$port...\nAguarde." 7 55
       : >"$err"
       result=$(SSHPASS="$password" sshpass -e ssh -o BatchMode=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$port" -- "$username@$ip" ':put "OK"' 2>"$err") && rc=0 || rc=$?
       if ((rc==0)) && [[ "$result" == *OK* ]]; then
         if dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'CONEXAO OK' --yes-label 'Salvar' --no-label 'Cancelar' --yesno "Conexao realizada com sucesso.\n\nCliente: $id\nDispositivo: $name\nIP: $ip\nPorta: $port\nUsuario: $username\n\nSalvar equipamento?" 15 68; then
           break
         else rm -f "$tmp" "$err"; return; fi
       fi
       shorterr=$(tail -n 3 "$err" | tr '\n' ' ' | cut -c1-220)
       opt=$(dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title "FALHA DE CONEXAO - CODIGO $rc" --cancel-label 'Cancelar' --menu "Nao foi possivel conectar.\n${shorterr:-Verifique os dados informados.}\n\nO que deseja fazer?" 21 86 8 1 'Tentar novamente' 2 'Alterar IP/hostname' 3 'Alterar usuario' 4 'Alterar senha' 5 'Alterar porta SSH') || { rm -f "$tmp" "$err"; return; }
       [[ "$opt" == 1 ]] && continue
     fi
     case "$opt" in
       2) dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title 'ALTERAR IP/HOSTNAME' --inputbox 'IP ou hostname:' 10 72 "$ip" >"$tmp" || continue; ip=$(cat "$tmp");;
       3) dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title 'ALTERAR USUARIO' --inputbox 'Usuario SSH:' 10 65 "$username" >"$tmp" || continue; username=$(cat "$tmp");;
       4) dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title 'ALTERAR SENHA' --insecure --passwordbox 'Nova senha SSH:' 10 65 >"$tmp" || continue; password=$(cat "$tmp");;
       5) dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title 'ALTERAR PORTA' --inputbox 'Porta SSH:' 10 60 "$port" >"$tmp" || continue; port=$(cat "$tmp");;
     esac
   done
   rm -f "$tmp" "$err"
 else
   read -r -p 'Nome do dispositivo: ' name
   valid_id "$name" || { echo 'Nome invalido'; return; }
   file="$BASE/clientes/$id/$name.json"
   [[ ! -e "$file" ]] || { echo 'Dispositivo ja cadastrado'; return; }
   read -r -p 'IP ou hostname: ' ip
   read -r -p 'Porta SSH [22]: ' port; port=${port:-22}
   read -r -p 'Usuario: ' username
   read_secret password
   result=$(SSHPASS="$password" sshpass -e ssh -o BatchMode=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$port" -- "$username@$ip" ':put "OK"' 2>&1) && rc=0 || rc=$?
   if ! { ((rc==0)) && [[ "$result" == *OK* ]]; }; then echo "Falha na conexao (codigo $rc): $result"; echo; echo "[1] Tentar novamente"; echo "[2] Corrigir dados da conexao"; echo "[0] Cancelar cadastro"; read_key opt "Opcao: "; case "$opt" in 1) add_device_skip_select "$id"; return;; 2) add_device_skip_select "$id"; return;; 0) return;; *) return;; esac; fi
 fi

 file="$BASE/clientes/$id/$name.json"
 jq -n --arg name "$name" --arg ip "$ip" --arg port "$port" --arg username "$username" --arg password "$password" '{name:$name,ip:$ip,port:$port,username:$username,password:$password,type:"mikrotik"}' > "$file" || return 1
 chmod 600 "$file"
 ui_message "MikroTik $name cadastrado com sucesso em $id.\n\nNenhum agendamento foi criado."
}
notify(){
 local client msg cfg token chat
 client="${1:-}"; msg="${2:-}"
 [[ -n "$client" ]] || return 1
 cfg="$BASE/clientes/$client/telegram.json"
 [[ -f "$cfg" ]] || return 1
 token=$(jq -r '.token // ""' "$cfg"); chat=$(jq -r '.chat // ""' "$cfg")
 [[ -n "$token" && -n "$chat" ]] || return 1
 curl -fsS --connect-timeout 10 --max-time 30 -X POST "https://api.telegram.org/bot${token}/sendMessage" --data-urlencode "chat_id=$chat" --data-urlencode "text=$msg" | jq -e '.ok==true' >/dev/null
}
notify_document(){
 local client file caption cfg token chat
 client="${1:-}"; file="${2:-}"; caption="${3:-}"
 cfg="$BASE/clientes/$client/telegram.json"
 [[ -f "$cfg" && -s "$file" ]] || return 1
 token=$(jq -r '.token // ""' "$cfg"); chat=$(jq -r '.chat // ""' "$cfg")
 [[ -n "$token" && -n "$chat" ]] || return 1
 curl -fsS --connect-timeout 10 --max-time 120 -X POST "https://api.telegram.org/bot${token}/sendDocument" -F "chat_id=$chat" -F "document=@$file" -F "caption=$caption" | jq -e '.ok==true' >/dev/null
}
retry_cmd(){
 local label="$1" errfile="$2"; shift 2
 local attempt rc=1 max_attempts=3 retry_delay=8
 for attempt in $(seq 1 "$max_attempts"); do
  : > "$errfile"
  if "$@" 2>"$errfile"; then return 0; else rc=$?; fi
  if ((attempt<max_attempts)); then status_info "$label falhou. Nova tentativa $((attempt+1))/$max_attempts em ${retry_delay}s..."; sleep "$retry_delay"; fi
 done
 return "$rc"
}
run_backup(){
 local client name file ip port username password lock temp stamp identity safe_id remote local_rsc local_backup zipfile dest err step reason size caption failed=0 attempt max_attempts=3 retry_delay=8 state_dir state_file previous_state
 client="${1:-}"; name="${2:-}"; file="$BASE/clientes/$client/$name.json"
 state_dir="$BASE/config/estado-backup"; state_file="$state_dir/$client--$name.state"; mkdir -p "$state_dir"; chmod 700 "$state_dir"; previous_state="OK"; [[ -f "$state_file" ]] && previous_state=$(cat "$state_file" 2>/dev/null || echo OK)
 valid_id "$client" && valid_id "$name" && [[ -f "$file" ]] || { echo 'Dispositivo nao encontrado'; return 1; }
 ip=$(jq -r '.ip' "$file"); port=$(jq -r '.port' "$file"); username=$(jq -r '.username' "$file"); password=$(jq -r '.password' "$file")
 [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) || { status_fail "Porta SSH invalida no cadastro de $client/$name: $port"; echo "Corrija em Gerenciar clientes > cliente > Alterar equipamento > Porta SSH."; return 1; }
 lock="$BASE/tmp/$client-$name.lock"; exec 9>"$lock"; flock -n 9 || { echo 'Backup ja em execucao'; return 1; }
 temp=$(mktemp -d "$BASE/tmp/run.XXXXXXXX"); stamp=$(date +%Y%m%d-%H%M%S); err="$temp/error"
 for attempt in $(seq 1 "$max_attempts"); do
  : > "$err"
  identity=$(SSHPASS="$password" sshpass -e ssh -p "$port" -o ConnectTimeout=15 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new "$username@$ip" ':put [/system identity get name]' </dev/null 2>"$err" | tr -d '\r') || true
  [[ -n "$identity" ]] && break
  if ((attempt<max_attempts)); then status_info "Falha ao conectar/obter Identity. Nova tentativa $((attempt+1))/$max_attempts em ${retry_delay}s..."; sleep "$retry_delay"; fi
 done
 if [[ -z "$identity" ]]; then reason="Falha ao obter Identity apos $max_attempts tentativas"; step='identity'; failed=1; fi
 if ((failed==0)); then safe_id=$(echo "$identity" | tr ' /\\:' '____'); remote="routeros-$safe_id-$stamp"; local_rsc="$temp/$remote.rsc"; local_backup="$temp/$remote.backup"; dest="$BASE/backups/$client/$name"; mkdir -p "$dest"; chmod 700 "$dest"; zipfile="$dest/$remote.zip"; fi
 if ((failed==0)); then
  echo "Identity: $identity"; echo 'Gerando export RouterOS...'
  if ! SSHPASS="$password" sshpass -e ssh -p "$port" -o ConnectTimeout=15 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new "$username@$ip" "/export show-sensitive file=\"$remote\"" </dev/null >/dev/null 2>"$err"; then
   echo 'Tentando export sem hide-sensitive...'
   SSHPASS="$password" sshpass -e ssh -p "$port" -o ConnectTimeout=15 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new "$username@$ip" "/export file=\"$remote\"" </dev/null >/dev/null 2>"$err" || { reason='Falha ao gerar export'; step='export'; failed=1; }
  fi
 fi
 if ((failed==0)); then
  echo 'Gerando backup binario RouterOS...'
  SSHPASS="$password" sshpass -e ssh -p "$port" -o ConnectTimeout=15 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new "$username@$ip" "/system backup save name=\"$remote\" dont-encrypt=yes" </dev/null >/dev/null 2>"$err" || { reason='Falha ao gerar backup binario'; step='binary-backup'; failed=1; }
 fi
 if ((failed==0)); then sleep 2; echo 'Baixando backup binario...'; retry_cmd 'SCP do backup binario' "$err" env SSHPASS="$password" sshpass -e scp -P "$port" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$username@$ip:$remote.backup" "$local_backup" >/dev/null || { reason='Falha no SCP do backup binario apos 3 tentativas'; step='binary-download'; failed=1; }; fi
 if ((failed==0)); then sleep 2; echo 'Baixando export...'; retry_cmd 'SCP do export' "$err" env SSHPASS="$password" sshpass -e scp -P "$port" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$username@$ip:$remote.rsc" "$local_rsc" >/dev/null || { reason='Falha no SCP do export apos 3 tentativas'; step='download'; failed=1; }; fi
 if ((failed==0)) && [[ ! -s "$local_backup" ]]; then reason='Arquivo .backup vazio'; step='binary-validation'; failed=1; fi
 if ((failed==0)) && [[ ! -s "$local_rsc" ]]; then reason='Arquivo de export vazio'; step='validacao'; failed=1; fi
 if ((failed==0)); then SSHPASS="$password" sshpass -e ssh -p "$port" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$username@$ip" "/file remove [find where name=\"$remote.rsc\" or name=\"$remote.backup\"]" </dev/null >/dev/null 2>&1 || true; (cd "$temp" && zip -q "$zipfile" "$(basename "$local_rsc")" "$(basename "$local_backup")") || { reason='Falha ao compactar ZIP'; step='compactacao'; failed=1; }; fi
 if ((failed==0)); then
  size=$(du -h "$zipfile" | awk '{print $1}')
  caption="💾 ROUTEROS - $identity
📅 Backup: $(date +%d/%m/%Y)
🕐 Horário: $(date +%H:%M:%S)
📦 Arquivo: $(basename "$zipfile")
📄 Conteudo: .rsc + .backup
📊 Tamanho: $size"
  echo "$(date -Is) OK $client/$name $zipfile" >> "$BASE/logs/execucoes.log"
  if notify_document "$client" "$zipfile" "$caption"; then echo "Backup RouterOS enviado: $(basename "$zipfile")"; else echo 'Backup salvo localmente, mas Telegram recusou o arquivo.'; echo "$(date -Is) AVISO Telegram $client/$name" >> "$BASE/logs/execucoes.log"; fi
  if [[ "$previous_state" == "FALHA" ]]; then notify "$client" "🟢 BACKUP NORMALIZADO\n\n👤 Cliente: $client\n📡 Equipamento: $name\n🌐 IP: $ip\n✅ Status: Backup voltou a funcionar\n📅 Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')" || true; echo "$(date -Is) RECUPERADO $client/$name" >> "$BASE/logs/execucoes.log"; fi
  printf 'OK\n' > "$state_file"; chmod 600 "$state_file"
  rm -rf -- "$temp"; return 0
 fi
 echo "$(date -Is) FALHA $client/$name etapa=$step motivo=$reason" >> "$BASE/logs/execucoes.log"; if [[ "$previous_state" != "FALHA" ]]; then notify "$client" "🔴 BACKUP FALHOU\n\n👤 Cliente: $client\n📡 Equipamento: $name\n🌐 IP: $ip\n⚠️ Etapa: $step\n❌ Motivo: $reason\n📅 Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')" || true; fi; printf 'FALHA\n' > "$state_file"; chmod 600 "$state_file"; echo "Falha: $reason (etapa $step)"; [[ -s "$err" ]] && tail -n 4 "$err"; rm -rf -- "$temp"; return 1
}

ui_message(){
 if (( HAS_DIALOG )); then dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'Aviso' --msgbox "$1" 9 65; else printf '%s\n' "$1"; fi
}
ui_select_device(){
 local client="$1" f id answer
 local -a items=()
 for f in "$BASE/clientes/$client/"*.json; do
   [[ -f "$f" && "${f##*/}" != 'telegram.json' ]] || continue
   id="${f##*/}"; id="${id%.json}"
   items+=("$id" "$(jq -r '.ip // "sem IP"' "$f" 2>/dev/null)")
 done
 if (( ${#items[@]} == 0 )); then ui_message 'Nenhum equipamento cadastrado neste cliente.'; return 1; fi
 if (( HAS_DIALOG )); then
   answer=$(dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title "Equipamentos - $client" --menu 'Selecione o equipamento:' 18 75 10 "${items[@]}") || return 1
 else
   local n=0 choice
   for ((n=0;n<${#items[@]};n+=2)); do printf '[%d] %s - %s\n' "$((n/2+1))" "${items[n]}" "${items[n+1]}"; done
   read -r -p 'Numero do equipamento (0 cancela): ' choice
   [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#items[@]}/2)) || return 1
   answer="${items[(choice-1)*2]}"
 fi
 SELECTED_DEVICE="$answer"
}
ui_remove_client(){
 local id file
 if ! select_client; then return; fi
 id="$SELECTED_CLIENT"
 if find "$BASE/clientes/$id" -maxdepth 1 -type f -name '*.json' ! -name telegram.json | grep -q .; then
   ui_message "O cliente $id possui equipamentos cadastrados. Remova os equipamentos antes de excluir o cliente. Nenhum dado foi alterado."
   return
 fi
 if ! dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'CONFIRMAR EXCLUSAO' --defaultno --yes-label 'Remover' --no-label 'Cancelar' --yesno "Deseja realmente remover o cadastro do cliente $id?\n\nOs backups armazenados NAO serao apagados." 12 72; then return; fi
 file="$BASE/clientes/$id/telegram.json"
 if [[ -f "$file" ]]; then rm -f -- "$file"; fi
 if rmdir -- "$BASE/clientes/$id" 2>/dev/null; then
   ui_message "Cliente $id removido. Backups preservados."
 else
   ui_message "Nao foi possivel remover $id: existem outros arquivos no diretorio. Nenhum outro arquivo foi apagado."
 fi
}
ui_manage_clients(){
 local choice
 while :; do
   choice=$(dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA' --title 'GERENCIAR CLIENTES' --cancel-label 'Voltar' --menu 'Escolha uma operacao:' 16 72 8 \
     1 'Visualizar clientes cadastrados' \
     2 'Adicionar cliente' \
     3 'Remover cliente' \
     0 'Voltar') || return
   case "$choice" in
     1) ui_client_list;;
     2) add_client;;
     3) ui_remove_client;;
     0) return;;
   esac
 done
}
ui_client_list(){
 local -a rows=()
 local id count status
 while IFS= read -r id; do
   [[ -n "$id" ]] || continue
   count=$(find "$BASE/clientes/$id" -maxdepth 1 -type f -name '*.json' ! -name telegram.json | wc -l)
   status='Telegram pendente'
   if [[ -f "$BASE/clientes/$id/telegram.json" ]] && jq -e '(.token // "") != "" and (.chat // "") != ""' "$BASE/clientes/$id/telegram.json" >/dev/null 2>&1; then status='Telegram OK'; fi
   rows+=("$id" "$count equipamento(s) - $status")
 done < <(list_clients)
 if (( ${#rows[@]} == 0 )); then ui_message 'Nenhum cliente cadastrado.'; else
   dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'CLIENTES CADASTRADOS' --ok-label 'Voltar' --menu 'Clientes e status:' 18 80 12 "${rows[@]}" || true
 fi
}
ui_test_client_telegram(){
 local id
 select_client || return
 id="$SELECTED_CLIENT"
 echo
 echo "Testando Telegram do cliente $id..."
 if notify "$id" "TESTE BACKUP MANAGER V3 | Cliente: $id | Telegram funcionando corretamente."; then
   echo "OK - Telegram do cliente $id funcionando."
 else
   echo "FALHA - Telegram do cliente $id nao respondeu corretamente."
 fi
 echo
 echo '[ENTER] Voltar'
 read -r
}
edit_client(){
 local id opt new token chat
 select_client || return; id="$SELECTED_CLIENT"
 while :; do
  echo; echo "========== ALTERAR CLIENTE: $id =========="
  echo '[1] Alterar nome'; echo '[2] Alterar Bot Token'; echo '[3] Alterar Chat ID'; echo '[4] Testar Telegram'; echo '[0] Voltar'
  read_key opt 'Opcao: '
  case "$opt" in
   1) read -r -p 'Novo nome: ' new; valid_id "$new" || { echo 'Nome invalido'; continue; }; [[ ! -e "$BASE/clientes/$new" ]] || { echo 'Cliente ja existe'; continue; }; mv -- "$BASE/clientes/$id" "$BASE/clientes/$new"; if [[ -d "$BASE/backups/$id" && ! -e "$BASE/backups/$new" ]]; then mv -- "$BASE/backups/$id" "$BASE/backups/$new"; fi; id="$new"; echo 'Nome alterado.';;
   2) read -r -s -p 'Novo Bot Token (oculto): ' token; echo; jq --arg v "$token" '.token=$v' "$BASE/clientes/$id/telegram.json" > "$BASE/tmp/tg.$$" && mv "$BASE/tmp/tg.$$" "$BASE/clientes/$id/telegram.json"; chmod 600 "$BASE/clientes/$id/telegram.json";;
   3) read -r -p 'Novo Chat ID: ' chat; jq --arg v "$chat" '.chat=$v' "$BASE/clientes/$id/telegram.json" > "$BASE/tmp/tg.$$" && mv "$BASE/tmp/tg.$$" "$BASE/clientes/$id/telegram.json"; chmod 600 "$BASE/clientes/$id/telegram.json";;
   4) notify "$id" "TESTE BACKUP MANAGER V3 | Cliente: $id | Telegram funcionando." && echo 'Telegram OK.' || echo 'Falha no Telegram.';;
   0) return;; *) echo 'Opcao invalida';;
  esac
 done
}
delete_client(){
 local id confirm n
 select_client || return; id="$SELECTED_CLIENT"; n=$(find "$BASE/clientes/$id" -maxdepth 1 -type f -name '*.json' ! -name telegram.json | wc -l)
 echo; echo '========== EXCLUIR CLIENTE =========='; echo "Cliente: $id"; echo "Equipamentos cadastrados: $n"
 ((n==0)) || { echo 'Remova primeiro os equipamentos deste cliente.'; return; }
 echo 'Backups historicos serao PRESERVADOS.'; read -r -p 'Digite EXCLUIR para confirmar: ' confirm
 [[ "$confirm" == EXCLUIR ]] || { echo 'Cancelado.'; return; }; rm -f -- "$BASE/clientes/$id/telegram.json"; rmdir -- "$BASE/clientes/$id" && echo 'Cliente removido. Backups preservados.' || echo 'Nao foi possivel remover o cadastro.'
}
list_devices_text(){
 local id f n=0 name ip port user
 select_client || return; id="$SELECTED_CLIENT"
 echo; echo '=========================================================================='
 echo "                 EQUIPAMENTOS - CLIENTE: $id"
 echo '=========================================================================='
 printf ' %-4s %-22s %-18s %-7s %s\n' 'N' 'EQUIPAMENTO' 'IP/HOST' 'PORTA' 'USUARIO'
 echo '--------------------------------------------------------------------------'
 for f in "$BASE/clientes/$id/"*.json; do
  [[ -f "$f" && "${f##*/}" != telegram.json ]] || continue; ((++n)); name="${f##*/}"; name="${name%.json}"
  ip=$(jq -r '.ip // "-"' "$f"); port=$(jq -r '.port // "-"' "$f"); user=$(jq -r '.username // "-"' "$f")
  printf ' %-4d %-22.22s %-18.18s %-7s %s\n' "$n" "$name" "$ip" "$port" "$user"
 done
 ((n)) || echo ' Nenhum equipamento cadastrado.'
 echo '--------------------------------------------------------------------------'; echo '[ENTER] Voltar'; read -r
}
select_device_text(){
 local id="$1" f choice i=0 total name; local -a devs=()
 for f in "$BASE/clientes/$id/"*.json; do [[ -f "$f" && "${f##*/}" != telegram.json ]] || continue; devs+=("${f##*/}"); done
 total=${#devs[@]}; ((total)) || { echo 'Nenhum equipamento cadastrado.'; return 1; }
 echo; echo '========== SELECIONAR EQUIPAMENTO =========='
 for f in "${devs[@]}"; do ((++i)); name="${f%.json}"; printf '[%d] %s\n' "$i" "$name"; done
 echo '[0] Voltar'
 while :; do read_key choice 'Opcao: '; [[ "$choice" == 0 ]] && return 1
  if [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice>=1 && 10#$choice<=total)); then name="${devs[10#$choice-1]}"; SELECTED_DEVICE="${name%.json}"; return 0; fi
  echo 'Opcao invalida.'
 done
}
test_device_connection(){
 local id="$1" name="$2" file="$BASE/clientes/$1/$2.json" ip port username password result rc
 ip=$(jq -r .ip "$file"); port=$(jq -r .port "$file"); username=$(jq -r .username "$file"); password=$(jq -r .password "$file")
 echo "Testando SSH $name em $ip:$port..."
 result=$(SSHPASS="$password" sshpass -e ssh -o BatchMode=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$port" -- "$username@$ip" ':put "OK"' 2>&1) && rc=0 || rc=$?
 if ((rc==0)) && [[ "$result" == *OK* ]]; then echo 'OK - conexao SSH funcionando.'; return 0; fi
 echo "FALHA SSH codigo $rc: $result"; return 1
}
edit_device(){
 local id name file opt v
 select_client || return; id="$SELECTED_CLIENT"; select_device_text "$id" || return; name="$SELECTED_DEVICE"; file="$BASE/clientes/$id/$name.json"
 while :; do
  echo; echo "========== ALTERAR EQUIPAMENTO: $name =========="
  echo '[1] Alterar IP/hostname'; echo '[2] Alterar porta SSH'; echo '[3] Alterar usuario'; echo '[4] Alterar senha'; echo '[5] Testar conexao'; echo '[0] Voltar'
  read_key opt 'Opcao: '
  case "$opt" in
   1) read -r -p 'Novo IP/hostname [0 cancela]: ' v; [[ "$v" == 0 ]] && continue; jq --arg v "$v" '.ip=$v' "$file" > "$BASE/tmp/dev.$$" && mv "$BASE/tmp/dev.$$" "$file";;
   2) read -r -p 'Nova porta [0 cancela]: ' v; [[ "$v" == 0 ]] && continue; [[ "$v" =~ ^[0-9]+$ ]] && ((10#$v>=1&&10#$v<=65535)) || { echo 'Porta invalida.'; continue; }; jq --arg v "$v" '.port=$v' "$file" > "$BASE/tmp/dev.$$" && mv "$BASE/tmp/dev.$$" "$file";;
   3) read -r -p 'Novo usuario [0 cancela]: ' v; [[ "$v" == 0 ]] && continue; jq --arg v "$v" '.username=$v' "$file" > "$BASE/tmp/dev.$$" && mv "$BASE/tmp/dev.$$" "$file";;
   4) read -r -s -p 'Nova senha [0 cancela]: ' v; echo; [[ "$v" == 0 ]] && continue; jq --arg v "$v" '.password=$v' "$file" > "$BASE/tmp/dev.$$" && mv "$BASE/tmp/dev.$$" "$file";;
   5) test_device_connection "$id" "$name" || true;; 0) chmod 600 "$file"; return;; *) echo 'Opcao invalida.';;
  esac
  chmod 600 "$file"
 done
}
delete_device(){
 local id name file confirm
 select_client || return; id="$SELECTED_CLIENT"; select_device_text "$id" || return; name="$SELECTED_DEVICE"; file="$BASE/clientes/$id/$name.json"
 echo; echo '========== EXCLUIR EQUIPAMENTO =========='; echo "Cliente: $id"; echo "Equipamento: $name"; echo 'Backups historicos serao PRESERVADOS.'
 read -r -p 'Digite EXCLUIR para confirmar: ' confirm; [[ "$confirm" == EXCLUIR ]] || { echo 'Cancelado.'; return; }
 rm -f -- "$file"; echo 'Equipamento removido. Backups preservados.'
}
devices_menu(){
 local opt cid
 while :; do
  echo; echo '========== GERENCIAR EQUIPAMENTOS =========='
  echo '[1] Listar equipamentos'; echo '[2] Adicionar MikroTik'; echo '[3] Alterar equipamento'; echo '[4] Excluir equipamento'; echo '[5] Testar conexao SSH'; echo '[0] Voltar'
  read_key opt 'Opcao: '
  case "$opt" in
   1) list_devices_text;; 2) add_device;; 3) edit_device;; 4) delete_device;;
   5) select_client || continue; cid="$SELECTED_CLIENT"; select_device_text "$cid" || continue; test_device_connection "$cid" "$SELECTED_DEVICE" || true;;
   0) return;; *) echo 'Opcao invalida.';;
  esac
 done
}
list_devices_for_client(){
 local id="$1" f n=0 name ip port user
 echo; echo "================ EQUIPAMENTOS - CLIENTE: $id ================"
 printf ' %-4s %-22s %-18s %-7s %s\n' 'N' 'EQUIPAMENTO' 'IP/HOST' 'PORTA' 'USUARIO'
 echo '--------------------------------------------------------------------------'
 for f in "$BASE/clientes/$id/"*.json; do [[ -f "$f" && "${f##*/}" != telegram.json ]] || continue; ((++n)); name="${f##*/}"; name="${name%.json}"; ip=$(jq -r '.ip // "-"' "$f"); port=$(jq -r '.port // "-"' "$f"); user=$(jq -r '.username // "-"' "$f"); printf ' %-4d %-22.22s %-18.18s %-7s %s\n' "$n" "$name" "$ip" "$port" "$user"; done
 ((n)) || echo ' Nenhum equipamento cadastrado.'; echo '--------------------------------------------------------------------------'; echo '[ENTER] Voltar'; read -r
}
add_device_for_client(){ local save="$SELECTED_CLIENT"; SELECTED_CLIENT="$1"; add_device_skip_select "$1"; SELECTED_CLIENT="$save"; }
add_device_skip_select(){
 local id="$1" name ip port username password file result rc opt v
 echo; echo "========== ADICIONAR MIKROTIK - $id =========="; echo "Digite 0 em qualquer campo para cancelar."
 read -r -p "Nome do dispositivo: " name; [[ "$name" == 0 ]] && return; valid_id "$name" || { echo "Nome invalido"; return; }
 file="$BASE/clientes/$id/$name.json"; [[ ! -e "$file" ]] || { echo "Dispositivo ja cadastrado"; return; }
 read -r -p "IP ou hostname: " ip; [[ "$ip" == 0 ]] && return
 read -r -p "Porta SSH [22]: " port; [[ "$port" == 0 ]] && return; [[ -n "$port" ]] || port=22
 read -r -p "Usuario: " username; [[ "$username" == 0 ]] && return
 read -r -s -p "Senha SSH [0 cancela]: " password; echo; [[ "$password" == 0 ]] && return
 while :; do
  result=$(SSHPASS="$password" sshpass -e ssh -o BatchMode=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$port" -- "$username@$ip" ':put "OK"' 2>&1) && rc=0 || rc=$?
  if ((rc==0)) && [[ "$result" == *OK* ]]; then jq -n --arg name "$name" --arg ip "$ip" --arg port "$port" --arg username "$username" --arg password "$password" '{name:$name,ip:$ip,port:$port,username:$username,password:$password,type:"mikrotik"}' > "$file"; chmod 600 "$file"; status_ok "MikroTik $name cadastrado com sucesso em $id."; schedule_ensure_device_auto "$id" "$name"; echo; status_info "Executando primeiro backup para validar o equipamento..."; if run_backup "$id" "$name"; then status_ok "Cadastro validado e primeiro backup concluido."; else status_fail "Equipamento cadastrado, mas o primeiro backup falhou. O cadastro foi mantido para correcao."; fi; return 0; fi
  echo; echo "Falha na conexao (codigo $rc):"; printf "%s\n" "$result"
  echo; echo "[1] Tentar novamente"; echo "[2] Alterar IP/hostname"; echo "[3] Alterar porta SSH"; echo "[4] Alterar usuario"; echo "[5] Alterar senha"; echo "[0] Cancelar cadastro"
  read_key opt "Opcao: "
  case "$opt" in
   1) ;;
   2) read -r -p "Novo IP/hostname [0 cancela]: " v; [[ "$v" == 0 ]] || ip="$v";;
   3) read -r -p "Nova porta SSH [0 cancela]: " v; [[ "$v" == 0 ]] || port="$v";;
   4) read -r -p "Novo usuario [0 cancela]: " v; [[ "$v" == 0 ]] || username="$v";;
   5) read -r -s -p "Nova senha [0 cancela]: " v; echo; [[ "$v" == 0 ]] || password="$v";;
   0) echo "Cadastro cancelado."; return 0;;
   *) echo "Opcao invalida.";;
  esac
 done
}
edit_device_for_client(){ local id="$1"; echo; select_device_text "$id" || return; local name="$SELECTED_DEVICE" file="$BASE/clientes/$id/$SELECTED_DEVICE.json" opt v; while :; do echo; echo "========== ALTERAR EQUIPAMENTO: $name =========="; echo '[1] IP/hostname'; echo '[2] Porta SSH'; echo '[3] Usuario'; echo '[4] Senha'; echo '[5] Testar conexao'; echo '[0] Voltar'; read_key opt 'Opcao: '; case "$opt" in 1) read -r -p 'Novo IP/hostname [0 cancela]: ' v; [[ "$v" == 0 ]] || jq --arg v "$v" '.ip=$v' "$file" > "$BASE/tmp/dev.$$" && mv "$BASE/tmp/dev.$$" "$file";; 2) read -r -p 'Nova porta [0 cancela]: ' v; if [[ "$v" == 0 ]]; then :; elif [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1 && v<=65535)); then jq --arg v "$v" '.port=$v' "$file" > "$BASE/tmp/dev.$" && mv "$BASE/tmp/dev.$" "$file"; status_ok "Porta SSH alterada para $v."; else status_fail 'Porta invalida. Use somente 1 a 65535.'; fi;; 3) read -r -p 'Novo usuario [0 cancela]: ' v; [[ "$v" == 0 ]] || { jq --arg v "$v" '.username=$v' "$file" > "$BASE/tmp/dev.$$" && mv "$BASE/tmp/dev.$$" "$file"; };; 4) read -r -s -p 'Nova senha [0 cancela]: ' v; echo; [[ "$v" == 0 ]] || { jq --arg v "$v" '.password=$v' "$file" > "$BASE/tmp/dev.$$" && mv "$BASE/tmp/dev.$$" "$file"; };; 5) test_device_connection "$id" "$name" || true;; 0) chmod 600 "$file"; return;; esac; chmod 600 "$file"; done; }
delete_device_for_client(){ local id="$1" name file confirm; select_device_text "$id" || return; name="$SELECTED_DEVICE"; file="$BASE/clientes/$id/$name.json"; echo "Equipamento: $name"; echo 'Backups historicos serao PRESERVADOS.'; read -r -p 'Digite EXCLUIR para confirmar: ' confirm; [[ "$confirm" == EXCLUIR ]] || return; rm -f -- "$file"; echo 'Equipamento removido.'; }
edit_client_direct(){ local id="$1"; SELECTED_CLIENT="$id"; echo "Use o menu principal de Alterar cliente nesta beta para nome/Telegram."; }
GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[1;36m'; RESET=$'\033[0m'
status_ok(){ printf "%s[SUCESSO]%s %s\n" "$GREEN" "$RESET" "$*"; }
status_fail(){ printf "%s[FALHA]%s %s\n" "$RED" "$RESET" "$*"; }
status_info(){ printf "%s[INFO]%s %s\n" "$CYAN" "$RESET" "$*"; }
test_all_devices(){
 local id="$1" f name ok=0 fail=0
 for f in "$BASE/clientes/$id/"*.json; do [[ -f "$f" && "${f##*/}" != telegram.json ]] || continue; name="${f##*/}"; name="${name%.json}"; if test_device_connection "$id" "$name"; then ((++ok)); else ((++fail)); fi; done
 echo; status_info "Resultado: $ok OK | $fail FALHA"
}
backup_all_devices(){
 local id="$1" f name ok=0 fail=0
 for f in "$BASE/clientes/$id/"*.json; do [[ -f "$f" && "${f##*/}" != telegram.json ]] || continue; name="${f##*/}"; name="${name%.json}"; status_info "Backup: $name"; if run_backup "$id" "$name"; then status_ok "$name"; ((++ok)); else status_fail "$name"; ((++fail)); fi; done
 echo; status_info "Backups finalizados: $ok sucesso | $fail falha"
}
backup_client_menu(){
 local id="$1" opt
 while :; do echo; echo "========== BACKUP - CLIENTE: $id =========="; echo "[1] Backup de TODOS os equipamentos"; echo "[2] Selecionar equipamento"; echo "[0] Voltar"; read_key opt "Opcao: "; case "$opt" in 1) backup_all_devices "$id"; return;; 2) select_device_text "$id" || continue; run_backup "$id" "$SELECTED_DEVICE" || true; return;; 0) return;; *) echo "Opcao invalida.";; esac; done
}
manage_selected_client(){
 local id="$1" opt cid
 while :; do
  echo; echo "========== CLIENTE: $id =========="
  echo '[1] Listar equipamentos'
  echo '[2] Adicionar MikroTik'
  echo '[3] Alterar equipamento'
  echo '[4] Excluir equipamento'
  echo '[5] Testar conexao SSH'
  echo '[6] Testar conexao de TODOS'
  echo '[7] Executar backup'
  echo '[8] Testar / corrigir Telegram'
  echo '[9] Alterar dados do cliente'
  echo '[0] Voltar'
  read_key opt 'Opcao: '
  case "$opt" in
   1)
    SELECTED_CLIENT="$id"; list_devices_for_client "$id";;
   2)
    SELECTED_CLIENT="$id"; add_device_for_client "$id";;
   3)
    edit_device_for_client "$id";;
   4)
    delete_device_for_client "$id";;
   5)
    select_device_text "$id" || continue; test_device_connection "$id" "$SELECTED_DEVICE" || true;;
   6)
    test_all_devices "$id";;
   7)
    backup_client_menu "$id";;
   8)
    if notify "$id" "TESTE BACKUP MANAGER V3 | Cliente: $id | Telegram funcionando corretamente."; then status_ok 'Telegram funcionando.'; else status_fail 'Telegram indisponivel. Corrija Bot Token/Chat ID.'; fi;;
   9)
    SELECTED_CLIENT="$id"; edit_client_direct "$id";;
   0) return;; *) echo 'Opcao invalida.';;
  esac
 done
}
clients_menu(){
 local opt id
 while :; do
  echo; echo '========== GERENCIAR CLIENTES =========='
  echo '[1] Selecionar cliente / Gerenciar'
  echo '[2] Listar clientes / Testar Telegram'
  echo '[3] Adicionar cliente'
  echo '[4] Alterar cliente'
  echo '[5] Excluir cliente'
  echo '[0] Voltar'
  read_key opt 'Opcao: '
  case "$opt" in
   1) select_client || continue; id="$SELECTED_CLIENT"; manage_selected_client "$id";;
   2) show_clients;; 3) add_client;; 4) edit_client;; 5) delete_client;; 0) return;; *) echo 'Opcao invalida';;
  esac
 done
}
manual_backup_menu(){
 local c
 select_client || return; c="$SELECTED_CLIENT"
 select_device_text "$c" || return
 echo; echo '========== BACKUP MANUAL =========='
 echo "Cliente: $c"; echo "Equipamento: $SELECTED_DEVICE"
 echo '[1] Executar backup agora'; echo '[0] Voltar'
 local opt; read_key opt 'Opcao: '
 [[ "$opt" == 1 ]] || return
 run_backup "$c" "$SELECTED_DEVICE" || true
 echo; echo '[ENTER] Voltar'; read -r
}
schedule_dir(){ mkdir -p "$BASE/config/agendamentos"; chmod 700 "$BASE/config/agendamentos"; }
schedule_install_cron(){
 local id="$1" client="$2" device="$3" hour="$4" minute="$5" cron="/etc/cron.d/backup-manager-v3-$id" cmd
 if [[ "$device" == "__ALL__" ]]; then cmd=$(printf "%q run-all %q" "$0" "$client"); else cmd=$(printf "%q run %q %q" "$0" "$client" "$device"); fi
 printf "# Backup Manager V3 - %s\n%s %s * * * root %s >> %q 2>&1\n" "$id" "$minute" "$hour" "$cmd" "$BASE/logs/cron-$id.log" > "$cron"; chmod 644 "$cron"
}
schedule_next_device_time(){
 local count=0 f total; schedule_dir
 # Sequencia GLOBAL: conta todos os agendamentos V3, independentemente do cliente.
 for f in "$BASE/config/agendamentos/"*.json; do [[ -f "$f" ]] || continue; ((++count)) || true; done
 total=$count; SCHEDULE_HOUR=$(printf "%02d" $((2 + total / 60))); SCHEDULE_MINUTE=$(printf "%02d" $((total % 60)))
}
schedule_ensure_device_auto(){
 local client="$1" device="$2" id cfg; schedule_dir; id="$client-$device"; cfg="$BASE/config/agendamentos/$id.json"; [[ -f "$cfg" ]] && return 0
 schedule_next_device_time; jq -n --arg id "$id" --arg client "$client" --arg device "$device" --arg hour "$SCHEDULE_HOUR" --arg minute "$SCHEDULE_MINUTE" '{id:$id,client:$client,device:$device,hour:$hour,minute:$minute,enabled:true,automatic:true}' > "$cfg"; chmod 600 "$cfg"; schedule_install_cron "$id" "$client" "$device" "$SCHEDULE_HOUR" "$SCHEDULE_MINUTE"; status_ok "Agendamento automatico: $device diariamente as $SCHEDULE_HOUR:$SCHEDULE_MINUTE."
}
schedule_files(){ SCHEDULE_FILES=(); local f; schedule_dir; for f in "$BASE/config/agendamentos/"*.json; do if [[ -f "$f" ]]; then SCHEDULE_FILES+=("$f"); fi; done; return 0; }
schedule_sync_missing(){
 local d client device created=0; schedule_dir
 for d in "$BASE/clientes/"*/*.json; do [[ -f "$d" ]] || continue; [[ "${d##*/}" == "telegram.json" ]] && continue; client=$(basename "$(dirname "$d")"); device=$(basename "$d" .json); if [[ ! -f "$BASE/config/agendamentos/$client-$device.json" ]]; then schedule_ensure_device_auto "$client" "$device"; ((++created)) || true; fi; done
 ((created==0)) && return 0; status_info "$created agendamento(s) faltante(s) criado(s) automaticamente."
}
schedule_build_plan(){
 PLAN_CLIENT=(); PLAN_DEVICE=(); PLAN_OLD=(); PLAN_NEW=(); local d client device old idx=0 hh mm cfg
 while IFS= read -r d; do [[ -f "$d" ]] || continue; client=$(basename "$(dirname "$d")"); device=$(basename "$d" .json); cfg="$BASE/config/agendamentos/$client-$device.json"; old="SEM"; [[ -f "$cfg" ]] && old="$(jq -r '.hour+":"+(.minute|tostring)' "$cfg")"; hh=$(printf "%02d" $((2 + idx / 60))); mm=$(printf "%02d" $((idx % 60))); PLAN_CLIENT+=("$client"); PLAN_DEVICE+=("$device"); PLAN_OLD+=("$old"); PLAN_NEW+=("$hh:$mm"); ((++idx)) || true; done < <(find "$BASE/clientes" -mindepth 2 -maxdepth 2 -type f -name "*.json" ! -name telegram.json | sort)
}
schedule_reorganize(){
 local i confirm client device old new hh mm id cfg total; schedule_build_plan; total=${#PLAN_DEVICE[@]}; ((total)) || { echo "Nenhum equipamento cadastrado."; return; }
 echo; echo "================ PREVIA DA REORGANIZACAO ================"; printf "%-16s %-22s %-12s %-12s\n" "CLIENTE" "EQUIPAMENTO" "ATUAL" "NOVO"
 for ((i=0;i<total;i++)); do client="${PLAN_CLIENT[i]}"; device="${PLAN_DEVICE[i]}"; old="${PLAN_OLD[i]}"; new="${PLAN_NEW[i]}"; if [[ "$old" == "$new" ]]; then printf "%s%-16s %-22s %-12s %-12s%s\n" "$GREEN" "$client" "$device" "$old" "$new" "$RESET"; else printf "%s%-16s %-22s %-12s -> %-9s%s\n" "$YELLOW" "$client" "$device" "$old" "$new" "$RESET"; fi; done
 echo "=========================================================="; echo "Verde = permanece igual | Amarelo = sera criado/alterado"; echo; read -r -p "Aplicar esta reorganizacao? [S/N]: " confirm; [[ "$confirm" =~ ^[Ss]$ ]] || { echo "Reorganizacao cancelada. Nenhuma alteracao aplicada."; return; }
 rm -f /etc/cron.d/backup-manager-v3-* "$BASE/config/agendamentos/"*.json 2>/dev/null || true
 for ((i=0;i<total;i++)); do client="${PLAN_CLIENT[i]}"; device="${PLAN_DEVICE[i]}"; IFS=: read -r hh mm <<< "${PLAN_NEW[i]}"; id="$client-$device"; cfg="$BASE/config/agendamentos/$id.json"; jq -n --arg id "$id" --arg client "$client" --arg device "$device" --arg hour "$hh" --arg minute "$mm" '{id:$id,client:$client,device:$device,hour:$hour,minute:$minute,enabled:true,automatic:true}' > "$cfg"; chmod 600 "$cfg"; schedule_install_cron "$id" "$client" "$device" "$hh" "$mm"; done; status_ok "$total equipamento(s) reorganizado(s), iniciando as 02:00 com intervalo de 1 minuto."
}
schedule_list(){
 local f n=0 dev; schedule_sync_missing; schedule_files; echo; echo "================ AGENDAMENTOS V3 ================"; printf "%-4s %-16s %-22s %-8s\n" "N" "CLIENTE" "EQUIPAMENTO" "HORARIO"; for f in "${SCHEDULE_FILES[@]}"; do ((++n)) || true; dev=$(jq -r .device "$f"); printf "%-4s %-16s %-22s %s:%s\n" "$n" "$(jq -r .client "$f")" "$dev" "$(jq -r .hour "$f")" "$(jq -r .minute "$f")"; done; ((n==0)) && echo "Nenhum agendamento V3 cadastrado."; echo "=================================================="
}
schedule_select_file(){ local f i=0 opt; schedule_files; ((${#SCHEDULE_FILES[@]})) || { echo "Nenhum agendamento V3 cadastrado."; return 1; }; echo; for f in "${SCHEDULE_FILES[@]}"; do ((++i)) || true; echo "[$i] $(jq -r .client "$f") / $(jq -r .device "$f") - $(jq -r .hour "$f"):$(jq -r .minute "$f")"; done; echo "[0] Voltar"; read -r -p "Numero: " opt; [[ "$opt" == 0 ]] && return 1; [[ "$opt" =~ ^[0-9]+$ ]] && ((opt>=1 && opt<=${#SCHEDULE_FILES[@]})) || { echo "Opcao invalida."; return 1; }; SELECTED_SCHEDULE="${SCHEDULE_FILES[opt-1]}"; }
schedule_edit(){ local f id client device tm hh minute tmp; schedule_select_file || return; f="$SELECTED_SCHEDULE"; id=$(jq -r .id "$f"); client=$(jq -r .client "$f"); device=$(jq -r .device "$f"); read -r -p "Novo horario HH:MM [0 cancela]: " tm; [[ "$tm" == 0 ]] && return; [[ "$tm" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { status_fail "Horario invalido."; return; }; hh="${BASH_REMATCH[1]}"; minute="${BASH_REMATCH[2]}"; tmp="$BASE/tmp/schedule.$$"; jq --arg hour "$hh" --arg minute "$minute" '.hour=$hour | .minute=$minute' "$f" > "$tmp" && mv "$tmp" "$f"; chmod 600 "$f"; schedule_install_cron "$id" "$client" "$device" "$hh" "$minute"; status_ok "Horario alterado para $hh:$minute."; }
schedule_delete(){ local f id; schedule_select_file || return; f="$SELECTED_SCHEDULE"; id=$(jq -r .id "$f"); rm -f "/etc/cron.d/backup-manager-v3-$id" "$f"; status_ok "Agendamento $id excluido."; }
schedules_menu(){ local opt; schedule_sync_missing; while :; do echo; echo "========== AGENDAMENTOS =========="; echo "[1] Listar agendamentos V3"; echo "[2] Reorganizar TODOS automaticamente"; echo "[3] Alterar horario individual"; echo "[4] Excluir agendamento"; echo "[5] Sincronizar equipamentos sem agendamento"; echo "[6] Informacoes"; echo "[0] Voltar"; read_key opt "Opcao: "; case "$opt" in 1) schedule_list;; 2) schedule_reorganize;; 3) schedule_edit;; 4) schedule_delete;; 5) schedule_sync_missing; schedule_list;; 6) echo; echo "Automatico: 02:00 em diante, 1 minuto entre equipamentos. V2 nao e alterado.";; 0) return;; *) echo "Opcao invalida.";; esac; done; }
logs_menu(){
 local opt
 while :; do
  echo; echo '========== LOGS =========='
  echo '[1] Ultimas 30 execucoes'; echo '[2] Ultimas falhas'; echo '[3] Ultimos sucessos'; echo '[0] Voltar'
  read_key opt 'Opcao: '
  case "$opt" in
   1) echo; tail -n 30 "$BASE/logs/execucoes.log" 2>/dev/null || echo 'Nenhum log ainda.';;
   2) echo; grep ' FALHA ' "$BASE/logs/execucoes.log" 2>/dev/null | tail -n 30 || true;;
   3) echo; grep ' OK ' "$BASE/logs/execucoes.log" 2>/dev/null | tail -n 30 || true;;
   0) return;; *) echo 'Opcao invalida.';;
  esac
 done
}
config_menu(){
 local opt
 while :; do
  echo; echo '========== CONFIGURACOES =========='
  echo '[1] Ver diretorios e ambiente'; echo '[2] Ver dependencias'; echo '[0] Voltar'
  read_key opt 'Opcao: '
  case "$opt" in
   1) echo; echo "Base: $BASE"; echo "Clientes: $BASE/clientes"; echo "Backups: $BASE/backups"; echo "Logs: $BASE/logs"; echo "Temporarios: $BASE/tmp";;
   2) echo; for x in bash ssh scp sshpass curl jq flock zip; do command -v "$x" >/dev/null 2>&1 && echo "OK   $x" || echo "FALTA $x"; done;;
   0) return;; *) echo 'Opcao invalida.';;
  esac
 done
}
menu(){
 local opt
 while :; do
  echo; echo '========================================'; echo '       BACKUP MANAGER V3 BETA'; echo '========================================'; echo '[1] Gerenciar clientes'; echo '[2] Executar backup manual'; echo '[3] Agendamentos'; echo '[4] Consultar logs'; echo '[5] Configuracoes'; echo '[0] Sair'; echo '========================================'
  read_key opt 'Escolha uma opcao: '
  case "$opt" in
   1) clients_menu;;
   2) manual_backup_menu;;
   3) schedules_menu;;
   4) logs_menu;;
   5) config_menu;;
   0) break;; *) echo 'Opcao invalida';;
  esac
 done
}
case "${1:-menu}" in menu) menu;; run) [[ $# == 3 ]] || exit 2; run_backup "$2" "$3";; run-all) [[ $# == 2 ]] || exit 2; backup_all_devices "$2";; *) echo 'Uso: bash backup-manager-v3-beta.sh [menu|run CLIENTE DISPOSITIVO|run-all CLIENTE]'; exit 2;; esac