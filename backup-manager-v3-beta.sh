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
 local id token chat
 read -r -p 'Identificador do cliente (letras/numeros/-/_): ' id
 valid_id "$id" || { echo 'Identificador invalido'; return; }
 [[ ! -e "$BASE/clientes/$id" ]] || { echo 'Cliente ja existe'; return; }
 mkdir -m 700 "$BASE/clientes/$id"
 read -r -p 'Bot Token Telegram (vazio para configurar depois): ' token
 read -r -p 'Chat ID Telegram: ' chat
 jq -n --arg token "$token" --arg chat "$chat" '{token:$token,chat:$chat}' > "$BASE/clientes/$id/telegram.json"
 chmod 600 "$BASE/clientes/$id/telegram.json"
 echo "Cliente $id criado"
}
list_clients(){ find "$BASE/clientes" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }
add_device(){
 local id name ip port username password type file
 list_clients
 read -r -p 'Cliente: ' id
 valid_id "$id" && [[ -d "$BASE/clientes/$id" ]] || { echo 'Cliente inexistente'; return; }
 read -r -p 'Nome do dispositivo: ' name
 valid_id "$name" || { echo 'Nome invalido'; return; }
 file="$BASE/clientes/$id/$name.json"
 [[ ! -e "$file" ]] || { echo 'Dispositivo ja cadastrado'; return; }
 read -r -p 'IP ou hostname: ' ip
 read -r -p 'Porta SSH [22]: ' port; port=${port:-22}
 read -r -p 'Usuario: ' username
 read_secret password
 while :; do
   if [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port>=1 && 10#$port<=65535)) && [[ -n "$ip" && -n "$username" ]]; then
     local result rc
     result=$(SSHPASS="$password" sshpass -e ssh -o BatchMode=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$port" -- "$username@$ip" ':put "OK"' 2>&1) && rc=0 || rc=$?
     if ((rc==0)) && [[ "$result" == *OK* ]]; then echo 'Conexao OK'; break; fi
     echo "Falha na conexao (codigo $rc). Verifique IP, porta, SSH e autenticacao."
   else echo 'IP, usuario ou porta invalidos'; fi
   echo '1) Tentar mesmos dados  2) Alterar IP  3) Alterar usuario  4) Alterar senha  5) Alterar porta  0) Cancelar'
   read -r -p 'Opcao: ' opt
   case "$opt" in
     1) ;; 2) read -r -p 'Novo IP: ' ip;; 3) read -r -p 'Novo usuario: ' username;; 4) read_secret password;; 5) read -r -p 'Nova porta: ' port;; 0) return;; *) echo 'Opcao invalida';;
   esac
 done
 jq -n --arg name "$name" --arg ip "$ip" --arg port "$port" --arg username "$username" --arg password "$password" '{name:$name,ip:$ip,port:$port,username:$username,password:$password,type:"mikrotik"}' > "$file"
 chmod 600 "$file"
 echo 'Dispositivo salvo. Nenhum agendamento foi criado.'
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
menu(){
 while :; do
 echo; echo '=== BACKUP MANAGER V3 BETA ==='; echo '1) Listar clientes  2) Adicionar cliente  3) Adicionar MikroTik  4) Backup manual  5) Ver logs  0) Sair'
 read -r -p 'Opcao: ' opt
 case "$opt" in
  1) list_clients;; 2) add_client;; 3) add_device;; 4) read -r -p 'Cliente: ' c; read -r -p 'Dispositivo: ' d; run_backup "$c" "$d" || true;; 5) tail -n 30 "$BASE/logs/execucoes.log" 2>/dev/null || :;; 0) break;; *) echo 'Opcao invalida';;
 esac
 done
}
case "${1:-menu}" in menu) menu;; run) [[ $# == 3 ]] || exit 2; run_backup "$2" "$3";; *) echo 'Uso: bash backup-manager-v3-beta.sh [menu|run CLIENTE DISPOSITIVO]'; exit 2;; esac