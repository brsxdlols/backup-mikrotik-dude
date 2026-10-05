#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BASE=/opt/backup-manager-v3
mkdir -p "$BASE"/{clientes,config,logs,backups,tmp}
chmod 700 "$BASE" "$BASE"/{clientes,config,logs,backups,tmp}
need(){ command -v "$1" >/dev/null || { echo "Dependencia ausente: $1"; exit 1; }; }
for x in ssh sshpass scp curl jq flock tar; do need "$x"; done
valid_id(){ [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }
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
   read -r -p 'Identificador do cliente (letras/numeros/-/_): ' id
   valid_id "$id" || { echo 'Identificador invalido'; return; }
   [[ ! -e "$BASE/clientes/$id" ]] || { echo 'Cliente ja existe'; return; }
   read -r -s -p 'Bot Token Telegram (oculto; vazio para depois): ' token; echo
   read -r -p 'Chat ID Telegram: ' chat
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
 echo '[ENTER] Voltar ao menu principal'
 read -r
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
   read -r -p 'Escolha o numero: ' choice
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
   ((rc==0)) && [[ "$result" == *OK* ]] || { echo "Falha na conexao (codigo $rc): $result"; return 1; }
 fi

 file="$BASE/clientes/$id/$name.json"
 jq -n --arg name "$name" --arg ip "$ip" --arg port "$port" --arg username "$username" --arg password "$password" '{name:$name,ip:$ip,port:$port,username:$username,password:$password,type:"mikrotik"}' > "$file" || return 1
 chmod 600 "$file"
 ui_message "MikroTik $name cadastrado com sucesso em $id.\n\nNenhum agendamento foi criado."
}
notify(){
 local client="$1" msg="$2" cfg="$BASE/clientes/$client/telegram.json" token chat
 [[ -f "$cfg" ]] || return 1
 token=$(jq -r '.token // ""' "$cfg"); chat=$(jq -r '.chat // ""' "$cfg")
 [[ -n "$token" && -n "$chat" ]] || return 1
 curl -fsS --connect-timeout 10 --max-time 30 -X POST "https://api.telegram.org/bot${token}/sendMessage" --data-urlencode "chat_id=$chat" --data-urlencode "text=$msg" | jq -e '.ok==true' >/dev/null
}
run_backup(){
 local client="$1" name="$2" file="$BASE/clientes/$client/$name.json"
 valid_id "$client" && valid_id "$name" && [[ -f "$file" ]] || { echo 'Dispositivo nao encontrado'; return 1; }
 local ip port username password lock temp stamp basename remote localfile dest err rc step reason
 ip=$(jq -r '.ip' "$file"); port=$(jq -r '.port' "$file"); username=$(jq -r '.username' "$file"); password=$(jq -r '.password' "$file")
 lock="$BASE/tmp/$client-$name.lock"
 exec 9>"$lock"; flock -n 9 || { echo 'Backup ja em execucao'; return 1; }
 temp=$(mktemp -d "$BASE/tmp/run.XXXXXXXX")
 stamp=$(date +%Y%m%d-%H%M%S); basename="bkp-$client-$name-$stamp"; remote="$basename.rsc"; localfile="$temp/$remote"
 dest="$BASE/backups/$client/$name"; mkdir -p "$dest"; chmod 700 "$dest"
 err="$temp/error"; step='export'; reason=''
 if ! SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -p "$port" -- "$username@$ip" "/export file=$basename" 2>"$err"; then reason='Falha SSH/autenticacao/exportacao';
 elif ! SSHPASS="$password" sshpass -e scp -O -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -P "$port" -- "$username@$ip:/$remote" "$localfile" 2>"$err"; then step='download'; reason='Falha ao transferir backup por SCP';
 elif [[ ! -s "$localfile" ]]; then step='validacao'; reason='Arquivo de backup vazio';
 elif ! tar -czf "$dest/$basename.tar.gz" -C "$temp" "$remote" 2>"$err"; then step='compactacao'; reason='Falha ao compactar backup';
 else
   SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -p "$port" -- "$username@$ip" "/file remove [find where name=\"$remote\"]" >/dev/null 2>&1 || true
   echo "$(date -Is) OK $client/$name $dest/$basename.tar.gz" >> "$BASE/logs/execucoes.log"
   if ! notify "$client" "✅ BACKUP OK | Cliente: $client | Equipamento: $name | IP: $ip | Arquivo: $basename.tar.gz"; then echo "$(date -Is) AVISO Telegram indisponivel $client/$name" >> "$BASE/logs/execucoes.log"; fi
   rm -rf -- "$temp"; echo "Backup salvo: $dest/$basename.tar.gz"; return 0
 fi
 echo "$(date -Is) FALHA $client/$name etapa=$step motivo=$reason" >> "$BASE/logs/execucoes.log"
 if ! notify "$client" "🔴 BACKUP FALHOU | Cliente: $client | Equipamento: $name | IP: $ip | Porta: $port | Etapa: $step | Motivo: $reason | $(date -Is)"; then echo "$(date -Is) AVISO Falha ao notificar Telegram $client/$name" >> "$BASE/logs/execucoes.log"; fi
 echo "Falha: $reason (etapa $step)"; rm -rf -- "$temp"; return 1
}
# Interface interativa dialog (fallback automatico para terminal simples).
HAS_DIALOG=0
if [[ -t 0 && -t 1 ]] && command -v dialog >/dev/null 2>&1; then HAS_DIALOG=1; fi
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
ui_menu(){
 local choice c d log
 while :; do
   choice=$(dialog --stdout --backtitle 'BACKUP MANAGER V3 BETA - MULTICLIENTE' --title 'MENU PRINCIPAL' --cancel-label 'Sair' --menu 'Use as setas e ENTER para selecionar:' 18 76 10 \
     1 'Clientes cadastrados' \
     2 'Adicionar cliente' \
     3 'Adicionar MikroTik' \
     4 'Executar backup manual' \
     5 'Consultar logs' \
     0 'Sair') || break
   case "$choice" in
     1) ui_manage_clients       ;;
     2|3)
       if [[ "$choice" == 2 ]]; then
         add_client
       else
         add_device
       fi
       ;;
     4)
       if select_client; then
         c="$SELECTED_CLIENT"
         if ui_select_device "$c"; then
           d="$SELECTED_DEVICE"
           clear
           run_backup "$c" "$d" || true
           read -r -p 'Pressione ENTER para continuar...' || true
         fi
       fi
       ;;
     5)
       log=$(tail -n 30 "$BASE/logs/execucoes.log" 2>/dev/null || true)
       dialog --backtitle 'BACKUP MANAGER V3 BETA' --title 'ULTIMAS EXECUCOES' --msgbox "${log:-Nenhuma execucao registrada.}" 22 95
       ;;
     0) break;;
   esac
 done
 clear
}
menu(){
 if (( HAS_DIALOG )); then ui_menu; return; fi
 local opt c d
 while :; do
   echo
   echo '========================================'
   echo '       BACKUP MANAGER V3 BETA'
   echo '========================================'
   echo '[1] Listar clientes'
   echo '[2] Adicionar cliente'
   echo '[3] Adicionar MikroTik'
   echo '[4] Executar backup manual'
   echo '[5] Consultar logs'
   echo '[0] Sair'
   echo '========================================'
   read -r -p 'Escolha uma opcao: ' opt
   case "$opt" in
     1) show_clients;;
     2) add_client;;
     3) add_device;;
     4) select_client || continue; c="$SELECTED_CLIENT"; read -r -p 'Nome do dispositivo: ' d; run_backup "$c" "$d" || true;;
     5) tail -n 30 "$BASE/logs/execucoes.log" 2>/dev/null || echo 'Nenhum log ainda.';;
     0) break;;
     *) echo 'Opcao invalida';;
   esac
 done
}
case "${1:-menu}" in menu) menu;; run) [[ $# == 3 ]] || exit 2; run_backup "$2" "$3";; *) echo 'Uso: bash backup-manager-v3-beta.sh [menu|run CLIENTE DISPOSITIVO]'; exit 2;; esac