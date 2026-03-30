#!/bin/bash
# Oracle Cloud ARM Free Tier - Auto Retry Script

usage() {
  cat <<EOF
Usage: $0 -t TENANCY -a AD -s SUBNET (-o OS | -i IMAGE) [options]

필수 인자:
  -t, --tenancy   <ocid>   테넌시(컴파트먼트) OCID
  -a, --ad        <name>   가용 도메인 (예: tsPF:AP-CHUNCHEON-1-AD-1)
  -s, --subnet    <ocid>   서브넷 OCID

이미지 선택 (둘 중 하나 필수):
  -o, --os        <name>   OS 이름으로 선택 (아래 목록 참고)
  -i, --image     <ocid>   이미지 OCID 직접 입력

지원 OS 목록 (-o):
  oracle-linux-8
  oracle-linux-9
  oracle-linux-10
  ubuntu-20.04
  ubuntu-22.04
  ubuntu-24.04
  (지원 리전: ap-chuncheon-1)

선택 인자:
  -k, --ssh-key   <path>   SSH 공개키 파일 경로 (기본값: ~/.ssh/oracle_arm.pub)
  -n, --name      <name>   인스턴스 표시 이름 (기본값: arm-free-instance)
  -c, --ocpus     <num>    OCPU 수 (기본값: 4)
  -m, --memory    <num>    메모리(GB) (기본값: 24)
  -r, --retry     <sec>    재시도 간격(초) (기본값: 120)
  -d, --no-duplicate-check 중복 생성 방지 비활성화 (기본값: 활성화)
  -h, --help               도움말 출력
EOF
  exit 1
}

resolve_image_ocid() {
  local os="$1"
  local os_name shape_filter

  case "$os" in
    oracle-linux-8)  os_name="Oracle Linux"; shape_filter="8" ;;
    oracle-linux-9)  os_name="Oracle Linux"; shape_filter="9" ;;
    oracle-linux-10) os_name="Oracle Linux"; shape_filter="10" ;;
    ubuntu-20.04)    os_name="Canonical Ubuntu"; shape_filter="20.04" ;;
    ubuntu-22.04)    os_name="Canonical Ubuntu"; shape_filter="22.04" ;;
    ubuntu-24.04)    os_name="Canonical Ubuntu"; shape_filter="24.04" ;;
    *) echo ""; return ;;
  esac

  oci compute image list \
    --compartment-id "$TENANCY" \
    --operating-system "$os_name" \
    --shape "$SHAPE" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
images = data.get('data', [])
for img in images:
    ver = img.get('operating-system-version', '')
    if '${shape_filter}' in ver:
        print(img['id'])
        break
"
}

# 기본값
SHAPE="VM.Standard.A1.Flex"
OCPUS=4
MEMORY=24
DISPLAY_NAME="arm-free-instance"
SSH_KEY_FILE="$HOME/.ssh/oracle_arm.pub"
RETRY_INTERVAL=120
DUPLICATE_CHECK=true  # 기본값: 중복 방지 활성화

TENANCY=""
AD=""
SUBNET=""
IMAGE=""
OS_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tenancy)            TENANCY="$2"; shift 2 ;;
    -a|--ad)                 AD="$2";      shift 2 ;;
    -s|--subnet)             SUBNET="$2";  shift 2 ;;
    -o|--os)                 OS_NAME="$2"; shift 2 ;;
    -i|--image)              IMAGE="$2";   shift 2 ;;
    -k|--ssh-key)            SSH_KEY_FILE="$2"; shift 2 ;;
    -n|--name)               DISPLAY_NAME="$2"; shift 2 ;;
    -c|--ocpus)              OCPUS="$2";   shift 2 ;;
    -m|--memory)             MEMORY="$2";  shift 2 ;;
    -r|--retry)              RETRY_INTERVAL="$2"; shift 2 ;;
    -d|--no-duplicate-check) DUPLICATE_CHECK=false; shift ;;
    -h|--help)               usage ;;
    *) echo "알 수 없는 옵션: $1"; usage ;;
  esac
done

MISSING=()
[[ -z "$TENANCY" ]] && MISSING+=("-t/--tenancy")
[[ -z "$AD"      ]] && MISSING+=("-a/--ad")
[[ -z "$SUBNET"  ]] && MISSING+=("-s/--subnet")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "오류: 다음 필수 인자가 없습니다: ${MISSING[*]}"
  echo ""
  usage
fi

if [[ -n "$OS_NAME" && -n "$IMAGE" ]]; then
  echo "오류: -o/--os 와 -i/--image 는 동시에 사용할 수 없습니다."
  usage
elif [[ -n "$OS_NAME" ]]; then
  IMAGE=$(resolve_image_ocid "$OS_NAME")
  if [[ -z "$IMAGE" ]]; then
    echo "오류: 지원하지 않는 OS입니다: $OS_NAME"
    exit 1
  fi
elif [[ -z "$IMAGE" ]]; then
  echo "오류: -o/--os 또는 -i/--image 중 하나는 필수입니다."
  usage
fi

LOG_FILE="$(dirname "$0")/create_arm_instance.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========================================"
log "Oracle ARM 인스턴스 자동 생성 시작"
log "Shape: $SHAPE | OCPU: $OCPUS | Memory: ${MEMORY}GB"
log "재시도 간격: ${RETRY_INTERVAL}초"
log "중복 생성 방지: $DUPLICATE_CHECK"
log "로그: $LOG_FILE"
log "========================================"

ATTEMPT=0

while true; do
  ATTEMPT=$((ATTEMPT + 1))

  # 중복 생성 방지 (활성화된 경우만)
  if [[ "$DUPLICATE_CHECK" == "true" ]]; then
    EXISTING=$(oci compute instance list \
      --compartment-id "$TENANCY" \
      --lifecycle-state RUNNING \
      2>&1)

    if echo "$EXISTING" | grep -q '"lifecycle-state"'; then
      EXISTING_COUNT=$(echo "$EXISTING" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(len(data.get('data', [])))
" 2>/dev/null)

      if [[ "${EXISTING_COUNT:-0}" -gt 0 ]]; then
        EXISTING_NAMES=$(echo "$EXISTING" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for inst in data.get('data', []):
    print(f\"  - {inst.get('display-name', '(이름없음)')} | {inst.get('id', '')}\")
" 2>/dev/null)
        log "========================================"
        log "[중단] 이미 RUNNING 상태의 인스턴스가 ${EXISTING_COUNT}개 존재합니다:"
        log "$EXISTING_NAMES"
        log "중복 생성을 방지하기 위해 종료합니다."
        log "(비활성화하려면 -d/--no-duplicate-check 옵션 사용)"
        log "========================================"
        exit 0
      fi
    else
      log "[$ATTEMPT] [경고] 인스턴스 목록 조회 실패 - 생성 시도를 계속합니다."
    fi
  fi

  log "[$ATTEMPT] 인스턴스 생성 시도 중..."

  RESULT=$(oci compute instance launch \
    --compartment-id "$TENANCY" \
    --availability-domain "$AD" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY}" \
    --image-id "$IMAGE" \
    --subnet-id "$SUBNET" \
    --display-name "$DISPLAY_NAME" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" \
    2>&1)

  if echo "$RESULT" | grep -q '"lifecycle-state"'; then
    INSTANCE_ID=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['id'])")
    PUBLIC_IP=""

    log "========================================"
    log "[SUCCESS] 인스턴스 생성 성공! (시도: $ATTEMPT회)"
    log "OCID: $INSTANCE_ID"
    log "상태 확인 중..."

    for i in $(seq 1 30); do
      sleep 10
      PUBLIC_IP=$(oci compute instance list-vnics \
        --instance-id "$INSTANCE_ID" \
        --compartment-id "$TENANCY" \
        2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
vnics=data.get('data',[])
if vnics: print(vnics[0].get('public-ip',''))
" 2>/dev/null)
      if [ -n "$PUBLIC_IP" ]; then
        break
      fi
    done

    log "Public IP: ${PUBLIC_IP:-'아직 할당 중...'}"
    log "SSH 접속: ssh -i ~/.ssh/oracle_arm opc@${PUBLIC_IP}"
    log "========================================"
    exit 0

  elif echo "$RESULT" | grep -q "Out of host capacity"; then
    log "[$ATTEMPT] 용량 부족 (Out of host capacity) - ${RETRY_INTERVAL}초 후 재시도..."

  elif echo "$RESULT" | grep -q "TooManyRequests"; then
    log "[$ATTEMPT] 요청 과다 (429) - 120초 대기 후 재시도..."
    sleep 120
    continue

  else
    ERROR=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message','Unknown error'))" 2>/dev/null || echo "$RESULT")
    log "[$ATTEMPT] 오류: $ERROR - ${RETRY_INTERVAL}초 후 재시도..."
  fi

  sleep "$RETRY_INTERVAL"
done
