#!/bin/sh
# Backup Manager: atualizacao incremental de historico (sem reinstalar/alterar cron)
set -eu
[ "$(id -u)" = 0 ] || { echo "Execute como root"; exit 1; }
python3 - <<'PY'
from pathlib import Path
import os, shutil, subprocess, tempfile, datetime
base=Path('/etc/scripts')
mk=base/'mkbkp.sh'; dude=base/'dudebkp.sh'; menu=base/'backup-manager.sh'
paths=(mk,dude,menu)
for p in paths:
    if not p.is_file(): raise SystemExit('Arquivo ausente: '+str(p))
    subprocess.run(['bash','-n',str(p)],check=True)
old={p:p.read_text() for p in paths}
def worker(s,typ):
    if '# HISTORICO_V21' in s: return s
    anchor='DATA="$(date +%Y%m%d-%H%M%S)"'
    if s.count(anchor)!=1: raise ValueError('DATA inesperada em '+typ)
    addition="""
# HISTORICO_V21
BKP_ETAPA="INICIO"
bkp_registrar_saida(){
  local rc="$1" resultado="FALHA" equipamento tamanho="-"
  [ "$rc" -eq 0 ] && resultado="SUCESSO"
  equipamento="$(printf '%s' "$IDENTITY" | tr '\\r\\n|' '   ')"
  [ -n "$equipamento" ] || equipamento="$IP"
  [ "$rc" -eq 0 ] && tamanho="$TAM"
  (umask 077; printf '%s | TIPO | %s | %s | %s | %s\\n' "$(date '+%F %T')" "$equipamento" "$resultado" "$BKP_ETAPA" "$tamanho" >> /var/log/mkbkp-status.log) 2>/dev/null || true
}
trap 'bkp_registrar_saida "$?"' EXIT
"""
    addition=addition.replace('TIPO',typ)
    s=s.replace(anchor,anchor+'\n'+addition,1)
    for token,stage in [('IDENTITY="$(sshpass','IDENTITY'),('echo "💾','EXPORT'),('echo "📥','SCP'),('zip -q ','ZIP'),('echo "📲 Enviando ao Telegram..."','TELEGRAM'),('echo "✅ Backup','CONFIRMADO')]:
        i=s.find(token)
        if i<0: raise ValueError('Marcador ausente: '+token)
        i=s.rfind('\n',0,i)+1
        s=s[:i]+'BKP_ETAPA="'+stage+'"\n'+s[i:]
    s=s.replace('echo "$RESP"\nexit 1','echo "Resposta da API omitida por seguranca."\nexit 1')
    return s
def manager(s):
    if '# HISTORICO_MENU_V21' in s: return s
    label='    echo " [0] 🚪 Sair"'
    case='        0) exit 0 ;;'
    start='while true; do\n    status_resumido'
    if any(s.count(x)!=1 for x in (label,case,start)): raise ValueError('Menu nao corresponde ao instalador original')
    f="""
# HISTORICO_MENU_V21
historico_backups(){
    echo "===== HISTORICO DE BACKUPS ====="
    if [ -s /var/log/mkbkp-status.log ]; then
        tail -n 60 /var/log/mkbkp-status.log
    else
        echo "Nenhum resultado registrado ainda."
    fi
    echo "Data | Tipo | Equipamento | Resultado | Etapa | Tamanho"
}
"""
    s=s.replace(start,f+'\n'+start,1)
    s=s.replace(label,'    echo " [11] Histórico dos backups"\n'+label,1)
    s=s.replace(case,'        11) historico_backups; pause ;;\n'+case,1)
    s=s.replace('printf \'%02d:%02d\' "$h" "$m"','printf \'%02d:%02d\' "$((10#$h))" "$((10#$m))"')
    return s
updated={mk:worker(old[mk],'ROUTEROS'),dude:worker(old[dude],'DUDE'),menu:manager(old[menu])}
temp={}
back={}
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
try:
    for p,s in updated.items():
        fd,name=tempfile.mkstemp(prefix='.historico-v21-',dir=str(base))
        with os.fdopen(fd,'w') as f: f.write(s)
        os.chmod(name,p.stat().st_mode & 0o777)
        subprocess.run(['bash','-n',name],check=True)
        temp[p]=Path(name)
    for p in paths:
        dest=Path(str(p)+'.bak-historico-'+stamp)
        shutil.copy2(p,dest)
        back[p]=dest
    for p in paths: os.replace(temp[p],p)
    log=Path('/var/log/mkbkp-status.log')
    log.touch(mode=0o600,exist_ok=True)
    os.chmod(log,0o600)
except Exception:
    for p,b in back.items(): shutil.copy2(b,p)
    raise
finally:
    for p in temp.values():
        if p.exists(): p.unlink()
print('OK: menu 11 e historico habilitados.')
print('OK: sintaxe validada. Cron e Telegram preservados.')
for p in back.values(): print('Backup:',p)
print('Abrir menu: bkp')
PY
