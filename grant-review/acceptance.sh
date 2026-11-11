#!/usr/bin/env bash
# Acceptance tests for the grant-review VM (PRIMER.md section 11). Runs on the admin laptop.
#
#   ./acceptance.sh                       all safe tests
#   ./acceptance.sh --only 1,23,28        just these
#   ./acceptance.sh --with-resource       also 35-37 (fork bomb, memory hog, disk fill)
#   ./acceptance.sh --with-lifecycle      also 52 and 54: REVOKES testa's key and REMOVES testa
#
# Before the first run:
#   - testa, testb and testa2 added, sample.pdf and sample.txt loaded for each, and activated
#   - their SSH private keys in test-keys/testa, test-keys/testb, test-keys/testa2 (gitignored)
#   - review.env filled in and the host key pinned (review pin-hostkey)
#   - optional: PENDING_USER=<name> of a test reviewer that is added but NOT activated (test 51)
#
# It plants canaries (HOST-, TESTB-, PROMPT-, FILE-CANARY-<random>) and removes them at the end.
# Results go to test-logs/acceptance-<timestamp>.log. Exit status: 0 only if nothing FAILED.
# MANUAL results need a person (often a brine admin); the log says what to do.
# Never run this against real reviewers: it only touches testa, testb, testa2 (and PENDING_USER).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
die() { echo "error: $*" >&2; exit 2; }

only="" with_resource=false with_lifecycle=false
while (( $# )); do
  case $1 in
    --only) only=",$2,"; shift 2 ;;
    --with-resource) with_resource=true; shift ;;
    --with-lifecycle) with_lifecycle=true; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

envf=${REVIEW_ENV:-$here/review.env}
[[ -r $envf ]] || die "$envf missing"
# shellcheck source=/dev/null
source "$envf"
keys=${TEST_KEYS_DIR:-$here/test-keys}
logdir=${TEST_LOGS_DIR:-$here/test-logs}
LOCAL_TEST=${LOCAL_TEST:-0}
: "${VM_ADMIN:=ubuntu}" "${BRINE_URL:=https://brine.sharcnet.ca}" "${PENDING_USER:=}"
brine_host=${BRINE_URL#https://}; brine_host=${brine_host%%/*}
model=${MODELS%% *}
[[ -n $model ]] || die "MODELS is empty in review.env"
ip=${VM_HOST:-$(terraform -chdir="$here/terraform" output -raw ip 2>/dev/null)}
[[ -n $ip ]] || die "no VM address (set VM_HOST or run review apply)"
kh=${REVIEW_SSH_DIR:-$here/.ssh}/known_hosts
[[ -s $kh ]] || die "host key not pinned: review pin-hostkey"
for u in testa testb testa2; do [[ -r $keys/$u ]] || die "missing $keys/$u"; done

tmp=$(mktemp -d)
mkdir -p "$logdir"
log=$logdir/acceptance-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$log") 2>&1

R=$(openssl rand -hex 6)
HOST_CANARY=HOST-CANARY-$R TESTB_CANARY=TESTB-CANARY-$R
PROMPT_CANARY=PROMPT-CANARY-$R FILE_CANARY=FILE-CANARY-$R

# ---------- connections ----------

ssh_common=(-o HostKeyAlias=review-vm -o UserKnownHostsFile="$kh" -o StrictHostKeyChecking=yes
            -o IdentitiesOnly=yes -o ConnectTimeout=10)

# Root on the VM; the script arrives on stdin, so nothing lands in sudo's log or argv.
vm_root() {
  ssh "${ssh_common[@]}" -o ControlMaster=auto -o ControlPath="$tmp/cm" -o ControlPersist=120 \
      ${ADMIN_SSH_KEY:+-i "$ADMIN_SSH_KEY"} "$VM_ADMIN@$ip" 'sudo -n bash -s' <<<"$1"
}

# Run a script inside a reviewer's container, as the reviewer (same as enter-review does).
in_ctr() {
  vm_root "podman exec -i --user reviewer -w /home/reviewer review-$1 bash -s <<'__CTR_EOF__'
$2
__CTR_EOF__"
}

# ssh as a test reviewer with their key; extra ssh args come first, then the host is added.
as_rv() {
  local u=$1; shift
  ssh "${ssh_common[@]}" -o BatchMode=yes -i "$keys/$u" "$@" "$u@$ip"
}

# A real interactive login (through sshd, ForceCommand and enter-review). Prints only what the
# commands print, between markers. Extra args are ssh options.
rv_session() {
  local u=$1 cmds=$2; shift 2
  { printf 'PS1=; stty -echo\n'; printf 'echo "__B""EGIN__"\n%s\necho "__E""ND__"\nexit\n' "$cmds"; } \
    | ssh "${ssh_common[@]}" -o BatchMode=yes -i "$keys/$u" -tt "$@" "$u@$ip" 2>&1 \
    | tr -d '\r' | sed -n '/__BEGIN__$/,/__END__$/p' | sed '1d;$d'
}

sftp_batch() {   # user, batch text; runs in $tmp/dl
  mkdir -p "$tmp/dl"
  ( cd "$tmp/dl" && printf '%s\n' "$2" \
      | sftp "${ssh_common[@]}" -o BatchMode=yes -i "$keys/$1" -b - "$1@$ip" 2>&1 )
}

# ---------- harness ----------

declare -a RES_ID=() RES_ST=()
selected() { [[ -z $only || $only == *",$1,"* ]]; }
has()  { grep -qF -- "$2" <<<"$1"; }
hasE() { grep -qE -- "$2" <<<"$1"; }
FAILS=""
check() {  # check <condition-exit-status> <what>
  if [[ $1 -eq 0 ]]; then echo "  ok   $2"; else echo "  FAIL $2"; FAILS+="x"; fi
}
run() {
  local id=$1 desc=$2 fn=$3 st
  selected "$id" || return 0
  echo; echo "=== Test $id: $desc"
  FAILS=""; NOTE=""
  "$fn"; st=$?
  if [[ -n $FAILS ]]; then st=FAIL
  elif [[ $st -eq 2 ]]; then st=MANUAL
  elif [[ $st -eq 3 ]]; then st=SKIP
  elif [[ $st -ne 0 ]]; then st=FAIL
  else st=PASS; fi
  echo "RESULT $id $st${NOTE:+ ($NOTE)}"
  RES_ID+=("$id"); RES_ST+=("$st")
}
manual() { echo "  MANUAL: $*"; return 2; }
# On the local Lima test VM there is no OpenStack, config drive or security group.
not_local() { [[ $LOCAL_TEST != 1 ]] || { NOTE="not applicable on the local test VM"; return 1; }; }

# ---------- setup and cleanup ----------

setup() {
  echo "Log: $log"
  echo "VM $ip, brine $brine_host, model $model, run id $R, $(date)"
  vm_root "
    set -e
    for u in testa testb testa2; do systemctl is-active --quiet review-\$u.service || { echo \"review-\$u not running\"; exit 1; }; done
    printf '%s\n' '$HOST_CANARY' > /root/acceptance-canary.txt
    printf '%s\n' '$TESTB_CANARY' > /srv/review/homes/testb/.acceptance-canary.txt
    chmod 0644 /srv/review/homes/testb/.acceptance-canary.txt
    printf 'This is a test application. Its code word is %s.\n' '$FILE_CANARY' > /srv/review/homes/testa/acceptance-file-canary.txt
    chmod 0644 /srv/review/homes/testa/acceptance-file-canary.txt
    for u in testa testb testa2; do printf '%s\n' \$u > /srv/review/homes/\$u/.acceptance-whoami; chmod 0644 /srv/review/homes/\$u/.acceptance-whoami; done
  " || die "setup failed (are testa, testb and testa2 added and running?)"
}

cleanup() {
  vm_root "rm -f /root/acceptance-canary.txt /srv/review/homes/testb/.acceptance-canary.txt \
    /srv/review/homes/testa/acceptance-file-canary.txt /srv/review/homes/testa/sample-out.txt \
    /srv/review/homes/*/.acceptance-whoami /srv/review/homes/testa/r /srv/review/homes/testa/b \
    /srv/review/homes/testa/ls /srv/review/homes/testa/x /srv/review/homes/testa/big; \
    rm -rf /srv/review/homes/testa/d" >/dev/null 2>&1 || true
  ssh -o ControlPath="$tmp/cm" -O exit x 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# ---------- 11.1 SSH entry ----------

t1() { local o; o=$(rv_session testa 'id -un; cat ~/.acceptance-whoami; echo "ps1=$(bash -lic "echo \$PS1" 2>/dev/null </dev/null)"')
  echo "$o"; has "$o" reviewer; check $? "id shows reviewer"
  hasE "$o" '^testa$'; check $? "landed in testa's own home"
  has "$o" 'review:'; check $? "review prompt"; }

t2() { local o rc
  o=$(as_rv testa whoami 2>&1); rc=$?; echo "whoami: rc=$rc $o"
  [[ $rc -ne 0 ]] && has "$o" "remote commands are not allowed"; check $? "ssh whoami refused"
  o=$(as_rv testa -tt bash </dev/null 2>&1 | tr -d '\r'); echo "bash: $o"
  has "$o" "remote commands are not allowed"; check $? "ssh -t bash refused"
  o=$(as_rv testa -s foo </dev/null 2>&1); rc=$?; echo "subsystem foo: rc=$rc $o"
  [[ $rc -ne 0 ]]; check $? "ssh -s foo refused"; }

t3() { local p=$((20000 + RANDOM % 20000)) pid o rc
  as_rv testa -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$p:$brine_host:443" & pid=$!
  sleep 4; o=$(curl -sk -m5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$p/v1/models" 2>&1); kill $pid 2>/dev/null; wait $pid 2>/dev/null
  echo "-L: $o"; [[ $o == 000 ]]; check $? "-L local forward carries nothing"
  as_rv testa -N -o ExitOnForwardFailure=yes -D "127.0.0.1:$((p+1))" & pid=$!
  sleep 4; o=$(curl -sk -m5 -o /dev/null -w '%{http_code}' --socks5-hostname "127.0.0.1:$((p+1))" "https://$brine_host/" 2>&1); kill $pid 2>/dev/null; wait $pid 2>/dev/null
  echo "-D: $o"; [[ $o == 000 ]]; check $? "-D dynamic forward carries nothing"
  o=$(as_rv testa -N -o ExitOnForwardFailure=yes -R "0:127.0.0.1:22" 2>&1 & pid=$!; sleep 6; kill $pid 2>/dev/null; wait $pid; echo "rc=$?")
  echo "-R: $o"; ! has "$o" "rc=143"; check $? "-R remote forward refused (ssh exited by itself)"
  o=$(as_rv testa -W "$brine_host:443" </dev/null 2>&1); rc=$?; echo "-W: rc=$rc $o"
  [[ $rc -ne 0 ]]; check $? "-W stdio forward refused"
  o=$(rv_session testa 'echo "display=[$DISPLAY]"' -X); echo "-X: $o"
  has "$o" "display=[]"; check $? "-X gives no DISPLAY"
  NOTE="-w tunnel needs local root: check by hand with sudo ssh -w any"; }

t4() { local o; o=$(rv_session testa 'echo "sock=[$SSH_AUTH_SOCK]"; ls /tmp/ssh-* 2>/dev/null | head -1' -A)
  echo "$o"; has "$o" "sock=[]" && ! has "$o" "/tmp/ssh-"; check $? "no agent in the container"; }

t5() { local o; o=$(LC_EVIL='$(id)' rv_session testa 'echo "evil=[$LC_EVIL]"' -o SendEnv=LC_EVIL)
  echo "$o"; has "$o" "evil=[]"; check $? "client env not passed"; }

t6() { local o; o=$(ssh "${ssh_common[@]}" -o BatchMode=yes -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive "testa@$ip" true 2>&1)
  echo "$o"; has "$o" "Permission denied (publickey)"; check $? "only publickey offered"; }

t7() { local o rc; o=$(scp -O "${ssh_common[@]}" -o BatchMode=yes -i "$keys/testa" \
        "testa@$ip:originals/sample.pdf" "$tmp/legacy.pdf" 2>&1); rc=$?
  echo "rc=$rc $o"; [[ $rc -ne 0 && ! -s $tmp/legacy.pdf ]]; check $? "legacy scp refused"; }

t8() { local o l; o=$(vm_root 'sshd -T -C user=testa,host=x,addr=203.0.113.1')
  for l in "passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin no" \
           "disableforwarding yes" "allowtcpforwarding no" "allowagentforwarding no" \
           "allowstreamlocalforwarding no" "x11forwarding no" "permittunnel no" "permituserrc no" \
           "permituserenvironment no" "maxauthtries 3" "forcecommand sudo -n /usr/local/sbin/enter-review"; do
    hasE "$o" "^$l\$"; check $? "$l"
  done; }

t9() { local o; o=$(vm_root 'fail2ban-client status sshd'); echo "$o"
  has "$o" "Status for the jail: sshd"; check $? "sshd jail active"; }

t10() { manual "log in as an admin from an address outside ADMIN_CIDRS (e.g. a phone hotspot): it must be refused. Keep another session open."; }

# ---------- 11.2 Container isolation ----------

t11() { local o; o=$(in_ctr testa 'for t in curl wget python3 git ssh apt apt-get dpkg npm sudo gcc; do command -v $t; done; true')
  echo "found: [$o]"; [[ -z $o ]]; check $? "none of the tools present"; }

t12() { local o; o=$(in_ctr testa "for u in https://1.1.1.1 https://example.com 'https://[2606:4700:4700::1111]' http://169.254.169.254/; do
    node -e \"const u=process.argv[1];let said=0;const say=(...m)=>{if(!said++)console.log(...m)};require(u.startsWith('https')?'https':'http').get(u,{timeout:5000},r=>say('REACHED',u,r.statusCode)).on('error',e=>say('blocked',e.code,u)).on('timeout',function(){say('blocked timeout',u);this.destroy()})\" \"\$u\"; done")
  echo "$o"; [[ $(grep -c '^blocked' <<<"$o") -eq 4 ]] && ! has "$o" REACHED; check $? "all four blocked"; }

t13() { local o; o=$(in_ctr testa "node -e \"const s=require('dgram').createSocket('udp4');s.send('x',53,'1.1.1.1',e=>{console.log(e?'blocked '+e.code:'SENT');s.close()})\"")
  echo "$o"; has "$o" blocked; check $? "UDP blocked"; }

t14() { local o; o=$(in_ctr testa "awk 'NR>1 && \$4==\"0A\"{print FILENAME, \$2}' /proc/net/tcp /proc/net/tcp6; awk 'NR>1{print FILENAME, \$2}' /proc/net/udp /proc/net/udp6")
  echo "$o"; [[ $o == "/proc/net/tcp 0100007F:0FA0" ]]; check $? "only 127.0.0.1:4000 listening"; }

t15() { local o; o=$(in_ctr testa 'ls /run/brine; ls -a /home /home/reviewer; cat /etc/passwd /proc/mounts; find / -xdev \( -name "*testb*" -o -name "*testa2*" \) 2>/dev/null; true')
  echo "$o" | head -60
  ! hasE "$o" 'testb|testa2'; check $? "no other reviewer's name visible"
  [[ $(in_ctr testa 'ls /run/brine') == brine.sock ]]; check $? "only own socket"; }

t16() { local o; o=$(in_ctr testa "grep -rlF --exclude-dir=proc --exclude-dir=sys -e $HOST_CANARY -e $TESTB_CANARY / 2>/dev/null; true")
  echo "[$o]"; [[ -z $o ]]; check $? "host and testb canaries unreachable"; }

t17() { local o; o=$(in_ctr testa 'touch /usr/bin/x 2>&1 && echo ROOT_WRITABLE; touch ~/x && echo HOME_OK; touch /tmp/x && echo TMP_OK; grep " /tmp " /proc/mounts; cp /bin/ls ~/ls && ~/ls >/dev/null 2>&1 && echo EXEC_OK; rm -f ~/x ~/ls /tmp/x')
  echo "$o"; ! has "$o" ROOT_WRITABLE; check $? "root fs read-only"
  has "$o" HOME_OK; check $? "home writable"; has "$o" TMP_OK; check $? "/tmp writable"
  hasE "$o" 'tmpfs /tmp tmpfs .*size=262144k'; check $? "/tmp is 256 MB tmpfs"
  ! has "$o" EXEC_OK; check $? "copied binary won't run (noexec)"; }

t18() { local o; o=$(in_ctr testa 'stat -c "%U %a %n" ~/originals/*; touch ~/originals/x 2>/dev/null && echo TOUCHED; rm -f ~/originals/sample.pdf 2>/dev/null; [ -e ~/originals/sample.pdf ] && echo STILL_THERE')
  echo "$o"; ! grep -v ' 444 ' <<<"$(grep originals/ <<<"$o")" | grep -q .; check $? "all originals 0444"
  ! hasE "$o" '^reviewer '; check $? "not owned by reviewer"
  ! has "$o" TOUCHED && has "$o" STILL_THERE; check $? "can't add or delete"; }

t19() { local o; o=$(in_ctr testa 'grep -E "CapEff|NoNewPrivs|Seccomp:" /proc/self/status; cat /proc/self/uid_map; find / -xdev -perm /6000 -type f 2>/dev/null; true')
  echo "$o"; hasE "$o" 'CapEff:[[:space:]]+0+$'; check $? "no capabilities"
  hasE "$o" 'NoNewPrivs:[[:space:]]+1'; check $? "no_new_privs"
  hasE "$o" 'Seccomp:[[:space:]]+2'; check $? "seccomp filter"
  ! hasE "$o" '^[[:space:]]*[0-9]+[[:space:]]+0[[:space:]]'; check $? "uid map never maps to host root"
  ! hasE "$o" '^/'; check $? "no setuid/setgid files"; }

t20() { local o; o=$(in_ctr testa 'ls /proc | grep -E "^[0-9]+$" | wc -l'); echo "processes: $o"
  [[ $o -le 10 ]]; check $? "only this container's few processes"; }

t21() { local o; o=$(in_ctr testa "node -e \"const fs=require('fs');for(const p of fs.readdirSync('/proc').filter(x=>/^\\\\d+\$/.test(x))){let c='';try{c=fs.readFileSync('/proc/'+p+'/cmdline','utf8')}catch{};if(p!==String(process.pid)&&(c.includes('brine-forward')||p==='1')){try{process.kill(+p,'SIGKILL');console.log('KILLED',p)}catch(e){console.log('denied',p,e.code)}}}\"; sleep 1; node -e \"fetch('http://127.0.0.1:4000/v1/models').then(r=>console.log('status',r.status))\"")
  echo "$o"; ! has "$o" KILLED && has "$o" "denied 1"; check $? "can't kill PID 1 or the forwarder"
  has "$o" "status 200"; check $? "model path still works"; }

t22() { local o; o=$(vm_root '
    key_from() { sed -n "s/.*Bearer \([^\"]*\)\".*/\1/p" /etc/nginx/brine-users/testa.conf | head -1; }
    grep -rlF -f <(key_from) /srv/review/homes/testa /srv/review/originals/testa /etc/brine-review/models.json && echo KEY_IN_FILES
    for p in $(podman top review-testa hpid 2>/dev/null | tail -n +2); do grep -qaF -f <(key_from) /proc/$p/environ /proc/$p/cmdline 2>/dev/null && echo KEY_IN_PROCESS; done
    podman inspect review-testa --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -qF -f <(key_from) && echo KEY_IN_ENV
    echo checked')
  echo "$o"; has "$o" checked && ! hasE "$o" 'KEY_IN_'; check $? "real key nowhere in the container (checked from the host)"
  o=$(in_ctr testa 'env | grep -i key; grep -o "\"apiKey\": *\"[^\"]*\"" ~/.pi/agent/models.json')
  echo "$o"; [[ $(tr -d ' ' <<<"$o") == '"apiKey":"injected-by-proxy"' ]]; check $? "only the dummy key; no key in env"; }

# ---------- 11.3 Model access ----------

t23() { local o; o=$(in_ctr testa "node -e \"fetch('http://127.0.0.1:4000/v1/models').then(async r=>console.log(r.status,(await r.text()).slice(0,300))).catch(e=>console.log('error',e.message))\"")
  echo "$o"; hasE "$o" '^200 ' && has "$o" "$model"; check $? "model list without a key in the container"; }

t24() { local o n; o=$(in_ctr testa "node -e \"for (const p of ['/key/info','/key/generate','/user/info','/spend/logs','/model/info','/routes','/openapi.json','/ui','/health','/v1/embeddings','/v1/completions','/models','/v1/../key/info','//key/info','/key/info/','/%6Bey/info','/v1/models/../../key/info','/v1/models?x=1','/v1/%6Dodels','/anthropic/v1/messages','/openai_passthrough/v1/models','/langfuse/api/public/traces','/mcp','/v1/files','/v1/batches']) require('http').get({host:'127.0.0.1',port:4000,path:p},r=>console.log(r.statusCode,p)).on('error',e=>console.log('err',e.code,p))\"")
  echo "$o"; n=$(grep -c . <<<"$o")
  [[ $n -eq 25 && $(grep -c '^403 ' <<<"$o") -eq 25 ]]; check $? "403 for all 25 paths"; }

chat_js() {  # extra-headers-json extra-body-json
  printf '%s' "fetch('http://127.0.0.1:4000/v1/chat/completions',{method:'POST',headers:Object.assign({'Content-Type':'application/json'},$1),body:JSON.stringify(Object.assign({model:'$model',stream:true,max_tokens:20,messages:[{role:'user',content:'Say OK.'}]},$2))}).then(async r=>{const t=await r.text();console.log('status',r.status);console.log(t.slice(0,400))}).catch(e=>console.log('error',e.message))"
}

t25() { local o h js
  # Built in variables first: bash 3.2 brace-expands {a,b} inside $(...) nested in "...".
  h="{Authorization:'Bearer sk-bogus','x-litellm-api-key':'sk-bogus','x-litellm-tags':'forged'}"
  js=$(chat_js "$h" "{}"); o=$(in_ctr testa "node -e \"$js\"")
  echo "$o"; has "$o" "status 200" && has "$o" "data:"; check $? "works and streams despite forged headers"
  NOTE="brine admin: confirm the request is on testa's key alias with no 'forged' tag"; }

t26() { local o b js
  b="{api_base:'https://example.com',base_url:'https://example.com',langfuse_host:'https://example.com',metadata:{callbacks:['langfuse']}}"
  js=$(chat_js "{}" "$b"); o=$(in_ctr testa "node -e \"$js\"")
  echo "$o"; ! has "$o" "status 5"; check $? "no server error"
  manual "brine admin: confirm brine made no outbound connection to example.com and wrote no extra log at $(date '+%H:%M')"; }

t27() { manual "brine admin: look up testa's key alias ($(vm_root "awk '\$2==\"testa\"{print \$1}' /etc/brine-review/keys/aliases" | tail -1)): team = review team; models, max_budget, rpm/tpm set; expiry <= retention date; alias opaque"; }

# ---------- 11.4 Files and tools ----------

t28() { local o; rm -rf "$tmp/dl"; echo "upload test" > "$tmp/x.txt"
  o=$(sftp_batch testa "-ls originals
-get originals/sample.pdf
-put $tmp/x.txt
-put $tmp/x.txt originals/
-mkdir d
-rm originals/sample.pdf"); echo "$o"
  [[ -s $tmp/dl/sample.pdf ]]; check $? "download works"
  o=$(vm_root 'ls /srv/review/homes/testa/x.txt /srv/review/originals/testa/x.txt /srv/review/homes/testa/d 2>/dev/null; [ -e /srv/review/originals/testa/sample.pdf ] && echo PDF_STILL_THERE')
  echo "$o"; [[ $o == PDF_STILL_THERE ]]; check $? "uploads, mkdir and rm all refused"
  rm -f "$tmp/scp.pdf"
  scp "${ssh_common[@]}" -o BatchMode=yes -i "$keys/testa" "testa@$ip:originals/sample.pdf" "$tmp/scp.pdf" >/dev/null 2>&1
  [[ -s $tmp/scp.pdf ]]; check $? "scp download works"
  scp "${ssh_common[@]}" -o BatchMode=yes -i "$keys/testa" "$tmp/x.txt" "testa@$ip:" >/dev/null 2>&1
  [[ -z $(vm_root 'ls /srv/review/homes/testa/x.txt 2>/dev/null') ]]; check $? "scp upload refused"; }

t29() { local o want=${EXPECTED_FILES:-"sample.pdf sample.txt"}
  o=$(vm_root 'cd /srv/review/originals/testa && sha256sum -c /srv/review/manifests/testa.sha256 && stat -c "%U %a %n" *')
  echo "$o"; ! has "$o" FAILED && has "$o" ": OK"; check $? "checksums match the manifest"
  [[ $(grep -cE '^root 444 ' <<<"$o") -eq $(wc -w <<<"$want") ]]; check $? "root 444, exactly $(wc -w <<<"$want") files"
  for f in $want; do hasE "$o" "^root 444 $f\$"; check $? "$f present"; done; }

t30() { local o; rm -rf "$tmp/dl"
  o=$(sftp_batch testa '-cd /
-ls
-ls /home
-ls /run/brine
-get /root/*
-get /srv/review/homes/testb/*
-get /srv/review/homes/testb/.acceptance-canary.txt'); echo "$o"
  ! has "$o" testb.conf && ! grep -rqF CANARY "$tmp/dl" 2>/dev/null; check $? "no host or testb files retrieved"; }

t31() { local o; rm -rf "$tmp/dl"
  in_ctr testa 'ln -sfn /root ~/r; ln -sfn /srv/review/homes/testb ~/b' >/dev/null
  o=$(sftp_batch testa '-ls r
-ls b
-get -r r
-get -r b'); echo "$o"
  ! grep -rqF CANARY "$tmp/dl" 2>/dev/null; check $? "links don't escape"
  in_ctr testa 'rm -f ~/r ~/b' >/dev/null; }

t32() { local o; o=$(in_ctr testa 'pdftotext ~/originals/sample.pdf ~/sample-out.txt && head -c 300 ~/sample-out.txt; rm -f ~/sample-out.txt')
  echo "$o"; [[ -n ${o// /} ]]; check $? "pdftotext works"; }

nginx_lines() { vm_root 'wc -l < /var/log/nginx/brine-testa.access.log'; }

t33() { local before o paths; before=$(nginx_lines)
  o=$(in_ctr testa 'timeout 300 pi-review -p "Summarise the main aims in ~/originals/sample.txt in two sentences." 2>&1 | tail -20')
  echo "$o"; [[ -n ${o// /} ]] && ! hasE "$o" '(Error|error):'; check $? "pi answers"
  paths=$(vm_root "tail -n +$((before + 1)) /var/log/nginx/brine-testa.access.log | awk '{print \$3}' | sort -u")
  echo "paths: $paths"; ! grep -vxE '/v1/models|/v1/chat/completions' <<<"$paths" | grep -q .; check $? "only the two allowed paths used"; }

t34() { local o; o=$(in_ctr testa 'timeout 300 pi-review -p "Use your bash tool to run: ls /proc/1 && echo BASH_RAN_MARKER. If you have no bash tool, say NO_BASH_TOOL." 2>&1 | tail -20')
  echo "$o"; ! has "$o" BASH_RAN_MARKER; check $? "no command ran"
  NOTE="read pi's answer above: it should say it has no bash tool"; }

# ---------- 11.5 Resource isolation (--with-resource) ----------

testb_ok() { in_ctr testb "node -e \"fetch('http://127.0.0.1:4000/v1/models').then(r=>console.log('testb',r.status))\""; }

t35() { $with_resource || return 3; local o
  o=$(in_ctr testa "timeout 30 node -e \"const {spawn}=require('child_process');let n=0;function go(){try{for(let i=0;i<50;i++){spawn(process.execPath,['-e','setTimeout(()=>{},6e5)']).on('error',e=>{console.log('LIMIT',e.code,n);process.exit(0)});n++}}catch(e){console.log('LIMIT',e.code,n);process.exit(0)}setImmediate(go)}go()\"; echo rc=\$?" 2>&1 | tail -5)
  echo "$o"; hasE "$o" 'LIMIT|EAGAIN|Resource temporarily'; check $? "hit the pids limit"
  vm_root 'podman exec --user reviewer review-testa sh -c "kill -9 -1" 2>/dev/null; true' >/dev/null
  has "$(testb_ok)" "testb 200"; check $? "testb unaffected"; }

t36() { $with_resource || return 3; local o
  o=$(in_ctr testa "timeout 60 node -e \"const a=[];for(;;)a.push(Buffer.alloc(1e8,1))\"; echo rc=\$?")
  echo "$o"; hasE "$o" 'rc=(137|134)'; check $? "killed at the memory limit"
  vm_root 'systemctl is-active review-testa' | grep -qx active; check $? "testa's container still running"
  has "$(testb_ok)" "testb 200"; check $? "testb unaffected"; }

t37() { $with_resource || return 3; local o
  o=$(in_ctr testa "node -e \"const fs=require('fs'),f=fs.openSync(process.env.HOME+'/big','w'),b=Buffer.alloc(1<<26,1);try{for(;;)fs.writeSync(f,b)}catch(e){console.log('STOP',e.code)}\"; rm -f ~/big")
  echo "$o"; has "$o" "STOP EDQUOT"; check $? "stopped at the quota"
  has "$(in_ctr testb 'touch ~/x && echo OK; rm -f ~/x')" OK; check $? "testb can still write"; }

# ---------- 11.6 Host and network ----------

t38() { local o; o=$(vm_root 'sudo -l -U testa'); echo "$o"
  has "$o" "/usr/local/sbin/enter-review" && [[ $(grep -c 'NOPASSWD' <<<"$o") -eq 1 ]]; check $? "only enter-review"; }

t39() { local o; o=$(vm_root 'stat -c "%U %a %n" /usr/local/sbin/enter-review /usr/local/sbin /usr/local /usr /usr/local/lib/brine-review/common.sh'); echo "$o"
  ! grep -v '^root ' <<<"$o" | grep -q .; check $? "all owned by root"
  ! awk '{m=substr($2,length($2)-1,2); if (m ~ /[2367]/) print}' <<<"$o" | grep -q .; check $? "none group- or world-writable"; }

t40() { local o rc; o=$(vm_root 'sudo -u testa sudo -n /usr/local/sbin/enter-review testb 2>&1; echo rc=$?'); echo "$o"
  ! has "$o" "rc=0"; check $? "arguments refused by sudo"; }

t41() { local o; o=$(vm_root 'ls -ld /run/brine-proxy/*; ls -A /run/brine-proxy/testa; podman inspect review-testa --format "{{range .Mounts}}{{.Source}}{{println}}{{end}}" | sort')
  echo "$o"; ! grep '^d' <<<"$o" | grep -vE '^drwxr-xr-x +[0-9]+ root root ' | grep -q .; check $? "socket dirs root 0755"
  hasE "$o" '^brine.sock$'; check $? "testa's dir holds only brine.sock"
  [[ $(grep '^/' <<<"$o" | sort | tr '\n' ' ') == "/etc/brine-review/models.json /run/brine-proxy/testa /srv/review/homes/testa /srv/review/originals/testa " ]]
  check $? "testa mounts only its own paths"; }

t42() { local o; o=$(vm_root "sudo -u testa curl -s -m5 -o /dev/null -w '%{http_code}' https://$brine_host/; echo; sudo -u testa curl -s -m5 -o /dev/null -w '%{http_code}' http://169.254.169.254/; echo")
  echo "$o"; [[ $(tr -d '\n' <<<"$o") == 000000 ]]; check $? "reviewer account can't reach brine or metadata"; }

t43() { not_local || return 3; local o; o=$(vm_root 'd=$(mktemp -d); dev=$(blkid -L config-2); mount -o ro "$dev" "$d" && cat "$d/openstack/latest/user_data"; umount "$d"; rmdir "$d"; curl -s -m5 http://169.254.169.254/openstack/latest/user_data')
  echo "$o"; [[ -n $o ]] && ! hasE "$o" 'PRIVATE KEY|sk-[A-Za-z0-9]|password|Bearer'; check $? "user data holds no secrets"; }

t44() { not_local || return 3; local o; o=$(vm_root 'curl -s -m5 -o /dev/null -w "%{http_code}" https://example.com; echo'); echo "example.com: $o"
  [[ $o == 000 ]]; check $? "host can't reach the internet"
  o=$("$here/review" check 2>&1); echo "$o"; has "$o" "port: only"; check $? "only the review group on the port"; }

t45() { local o vol; o=$(vm_root 'swapon --noheadings --show; findmnt -no OPTIONS /srv/review'); echo "$o"
  ! grep -q '^/' <<<"$o"; check $? "no swap"
  for x in nodev nosuid noexec prjquota; do hasE "$o" "(^|,)$x(,|$)"; check $? "$x"; done
  vol=$(terraform -chdir="$here/terraform" output -raw volume_id 2>/dev/null)
  if [[ -n $vol ]] && command -v openstack >/dev/null; then
    o=$(openstack volume show "$vol" -f value -c encrypted); echo "encrypted: $o"; [[ $o == True ]]; check $? "volume encrypted"
  else NOTE="check by hand: openstack volume show <data-volume> -c encrypted"; fi; }

t46() { local o; o=$(vm_root 'find /var/lib/nginx/body /var/lib/nginx/proxy -type f 2>/dev/null | head'); echo "nginx temp: [$o]"
  [[ -z $o ]]; check $? "nginx temp dirs empty"
  if command -v openstack >/dev/null; then
    o=$(openstack volume snapshot list -f value -c Name; openstack image list --private -f value -c Name); echo "snapshots/images: [$o]"
    [[ -z $o ]]; check $? "no snapshots or private images"
  else NOTE="check by hand: openstack volume snapshot list; openstack image list --private"; fi; }

# ---------- 11.7 No content logged ----------

t47() { local o
  o=$(in_ctr testa "timeout 300 pi-review -p 'Repeat exactly: $PROMPT_CANARY' 2>&1 | tail -5"); echo "$o"
  has "$o" "$PROMPT_CANARY"; check $? "pi answered the prompt canary"
  o=$(in_ctr testa "timeout 300 pi-review -p 'What is the code word in ~/acceptance-file-canary.txt?' 2>&1 | tail -5"); echo "$o"
  has "$o" "$FILE_CANARY"; check $? "pi read the file canary"; }

t48() { local o; o=$(vm_root "grep -rlF -e '$PROMPT_CANARY' -e '$FILE_CANARY' /var/log /var/lib/nginx /etc /srv /root /tmp /var/tmp 2>/dev/null; journalctl --since -2h 2>/dev/null | grep -cF -e '$PROMPT_CANARY' -e '$FILE_CANARY'")
  echo "$o"
  ! grep '^/' <<<"$o" | grep -vE '^/srv/review/(homes|originals)/testa/' | grep -q .; check $? "canaries only in testa's own files"
  [[ $(tail -1 <<<"$o") == 0 ]]; check $? "nothing in the journal"; }

t49() { manual "brine admin: grep LiteLLM logs, a LiteLLM DB dump (incl. SpendLogs), ingress and vLLM logs for $PROMPT_CANARY and $FILE_CANARY: no matches"; }
t50() { manual "brine admin: today's requests show testa's opaque key alias with metadata only"; }

# ---------- 11.8 Lifecycle ----------

t51() { local u o
  for u in testb testa2; do
    o=$(rv_session "$u" 'cat ~/.acceptance-whoami; ls ~/originals'); echo "$u: $o"
    [[ $(head -1 <<<"$o") == "$u" ]]; check $? "$u lands in its own container"
  done
  if [[ -n $PENDING_USER && -r $keys/$PENDING_USER ]]; then
    o=$(as_rv "$PENDING_USER" true 2>&1); echo "$PENDING_USER: $o"
    has "$o" "Permission denied"; check $? "not-yet-activated $PENDING_USER refused"
  else NOTE="set PENDING_USER (added, not activated) to test refusal before activation"; fi; }

t52() { $with_lifecycle || return 3; local i o
  "$here/review" revoke testa || { echo "revoke failed"; return 1; }
  for i in $(seq 1 24); do
    o=$(in_ctr testa "node -e \"fetch('http://127.0.0.1:4000/v1/models').then(r=>console.log(r.status))\"")
    [[ $o == 401 ]] && break; sleep 5
  done; echo "testa after revoke: $o"
  [[ $o == 401 ]]; check $? "testa refused within 2 minutes"
  has "$(testb_ok)" "testb 200"; check $? "testb unaffected"; }

t53() { manual "reboot the VM (review ssh sudo reboot), then run this whole suite again; a reboot result is only valid from a full run"; }

t54() { $with_lifecycle || return 3; local o
  echo testa | "$here/review" remove testa
  o=$(vm_root 'id testa 2>&1; podman container exists review-testa && echo CTR; ls -d /run/brine-proxy/testa /srv/review/homes/testa /srv/review/originals/testa /srv/review/manifests/testa.sha256 /etc/nginx/brine-users/testa.conf /etc/ssh/authorized_keys/testa 2>/dev/null; true')
  echo "$o"; has "$o" "no such user" && ! has "$o" CTR && ! grep -q '^/' <<<"$o"; check $? "testa fully removed"
  o=$(as_rv testa true 2>&1); has "$o" "Permission denied"; check $? "ssh testa refused"
  o=$(rv_session testa2 'cat ~/.acceptance-whoami'); [[ $o == testa2 ]]; check $? "testa2 still logs in (test 1)"
  o=$(in_ctr testa2 "node -e \"fetch('http://127.0.0.1:4000/v1/models').then(r=>console.log(r.status))\""); [[ $o == 200 ]]; check $? "testa2 model path (test 23)"
  rm -rf "$tmp/dl"; sftp_batch testa2 '-get originals/sample.pdf' >/dev/null; [[ -s $tmp/dl/sample.pdf ]]; check $? "testa2 download (test 28)"; }

# ---------- 11.9 brine's shared IP and leftover connections ----------

t55() { local ipb o; ipb=$(dig +short A "$brine_host" | grep -E '^[0-9.]+$' | head -1)
  o=$(vm_root "curl -sk -m5 -H 'Host: anything.invalid' https://$ipb/ | head -c 300; echo; echo ---; curl -sk -m5 --resolve x.invalid:443:$ipb https://x.invalid/ | head -c 300")
  echo "$o"; ! grep -qiE 'plausible|<html|register' <<<"$o"; check $? "nothing but brine answers on brine's IP"
  NOTE="until BRINE-REQUIREMENTS item 1 is fixed this fails; record it as the accepted residual risk"; }

t56() { not_local || return 3; local o; o=$("$here/review" check 2>&1); echo "$o"
  has "$o" "port: only"; check $? "only the review group on the port"
  ! grep -- '->' <<<"$o" | grep -vE ':22 ->|-> [0-9.]+:443$' | grep -q .; check $? "open connections are SSH and :443 only"; }

# ---------- run ----------

setup
run 1  "ssh lands in the reviewer's container"      t1
run 2  "remote commands and subsystems refused"     t2
run 3  "every kind of forwarding refused"           t3
run 4  "no agent forwarding"                        t4
run 5  "client environment not passed"              t5
run 6  "public key only"                            t6
run 7  "legacy scp refused"                         t7
run 8  "effective sshd settings for reviewers"      t8
run 9  "fail2ban sshd jail"                         t9
run 10 "admin login only from allowlist"            t10
run 11 "no network tools in the image"              t11
run 12 "no TCP to internet, IPv6 or metadata"       t12
run 13 "no UDP"                                     t13
run 14 "only the forwarder listens"                 t14
run 15 "no view of other reviewers"                 t15
run 16 "canaries unreachable"                       t16
run 17 "read-only root, noexec home, small /tmp"    t17
run 18 "originals read-only"                        t18
run 19 "no privileges"                              t19
run 20 "own processes only"                         t20
run 21 "can't kill the forwarder"                   t21
run 22 "no real key in the container"               t22
run 23 "model list via the proxy"                   t23
run 24 "allowlist and path tricks"                  t24
run 25 "forged headers dropped; streaming works"    t25
run 26 "body overrides refused"                     t26
run 27 "key limits on brine"                        t27
run 28 "sftp/scp download-only"                     t28
run 29 "originals match the manifest"               t29
run 30 "sftp sees only the container"               t30
run 31 "links don't escape sftp"                    t31
run 32 "pdftotext"                                  t32
run 33 "pi answers; only allowed paths used"        t33
run 34 "pi has no bash tool"                        t34
run 35 "fork bomb contained"                        t35
run 36 "memory hog contained"                       t36
run 37 "disk quota"                                 t37
run 38 "sudo rule"                                  t38
run 39 "enter-review path ownership"                t39
run 40 "enter-review takes no arguments"            t40
run 41 "socket dirs and container mounts"           t41
run 42 "reviewer accounts have no network"          t42
run 43 "no secrets in user data"                    t43
run 44 "host egress locked"                         t44
run 45 "no swap; mount options; encrypted volume"   t45
run 46 "no snapshots; no nginx temp files"          t46
run 47 "canaries through pi"                        t47
run 48 "canaries not logged on the VM"              t48
run 49 "canaries not logged on brine"               t49
run 50 "brine attributes requests to the alias"     t50
run 51 "each reviewer lands in their own container" t51
run 53 "reboot"                                     t53
run 55 "brine's shared IP"                          t55
run 56 "lock check and open connections"            t56
run 52 "key revocation"                             t52
run 54 "remove-reviewer"                            t54

echo; echo "=== Summary ($(date))"
pass=0 fail=0 man=0 skip=0
for i in "${!RES_ID[@]}"; do
  case ${RES_ST[$i]} in PASS) ((pass++));; FAIL) ((fail++)); echo "  FAIL   ${RES_ID[$i]}";; MANUAL) ((man++)); echo "  MANUAL ${RES_ID[$i]}";; SKIP) ((skip++));; esac
done
echo "PASS $pass  FAIL $fail  MANUAL $man  SKIP $skip"
echo "Canary strings for the brine admin: $PROMPT_CANARY $FILE_CANARY"
echo "Log: $log"
[[ $fail -eq 0 ]]
