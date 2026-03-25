# Oracle Cloud ARM Free Tier - Auto Retry Script

> **주의:** 버그가 있을 수 있으며 정상 동작을 보장하지 않습니다. 사용에 따른 책임은 본인에게 있습니다.

Oracle Cloud(OCI) ARM 인스턴스(VM.Standard.A1.Flex)를 용량이 확보될 때까지 자동으로 재시도하며 생성하는 스크립트입니다.

---

## 사전 요구사항

- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) 설치 및 `oci setup config` 완료
- Python 3 (JSON 파싱용)
- SSH 키 쌍

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/oracle_arm
```

---

## 실행 가이드

### 1. 필수 정보 수집

| 항목 | 확인 위치 |
|------|-----------|
| 테넌시(컴파트먼트) OCID | OCI 콘솔 → Identity → Compartments |
| 가용 도메인(AD) | OCI 콘솔 → 리전 선택 후 AD 이름 확인 |
| 서브넷 OCID | OCI 콘솔 → Networking → VCN → Subnets |

### 2. 실행

`-o` 옵션으로 OS 이름을 지정하면 OCI CLI로 최신 이미지 OCID를 **자동 조회**합니다. 별도 하드코딩 불필요.


```bash
chmod +x create_arm_instance.sh

# OS 이름으로 실행 (이미지 OCID 사전 설정 필요)
./create_arm_instance.sh \
  -t ocid1.tenancy.oc1..xxxx \
  -a tsPF:AP-CHUNCHEON-1-AD-1 \
  -s ocid1.subnet.oc1.ap-chuncheon-1.xxxx \
  -o oracle-linux-10

# 이미지 OCID 직접 지정
./create_arm_instance.sh \
  -t ocid1.tenancy.oc1..xxxx \
  -a tsPF:AP-CHUNCHEON-1-AD-1 \
  -s ocid1.subnet.oc1.ap-chuncheon-1.xxxx \
  -i ocid1.image.oc1.ap-chuncheon-1.xxxx
```

백그라운드 실행 (24/7):

```bash
nohup ./create_arm_instance.sh -t ... -a ... -s ... -o oracle-linux-10 > /dev/null 2>&1 &
echo "PID: $!"
```

### 4. 옵션 목록

| 옵션 | 설명 | 기본값 |
|------|------|--------|
| `-t`, `--tenancy` | 테넌시(컴파트먼트) OCID | **필수** |
| `-a`, `--ad` | 가용 도메인 이름 | **필수** |
| `-s`, `--subnet` | 서브넷 OCID | **필수** |
| `-o`, `--os` | OS 이름 (`-i`와 택1) | **필수** |
| `-i`, `--image` | 이미지 OCID 직접 지정 (`-o`와 택1) | **필수** |
| `-k`, `--ssh-key` | SSH 공개키 파일 경로 | `~/.ssh/oracle_arm.pub` |
| `-n`, `--name` | 인스턴스 표시 이름 | `arm-free-instance` |
| `-c`, `--ocpus` | OCPU 수 | `4` |
| `-m`, `--memory` | 메모리(GB) | `24` |
| `-r`, `--retry` | 재시도 간격(초) | `120` |

**지원 OS (`-o`):** `oracle-linux-8`, `oracle-linux-9`, `oracle-linux-10`, `ubuntu-20.04`, `ubuntu-22.04`, `ubuntu-24.04`

---

## 동작 방식

1. 시도 전마다 RUNNING 인스턴스 존재 여부 확인 → 이미 있으면 중복 방지를 위해 종료
2. `oci compute instance launch` 호출 (Oracle 내부 용량 탐색으로 응답까지 약 90~100초 소요되는 것은 정상)
3. 성공 → Public IP 할당 대기(최대 5분) 후 SSH 접속 정보 출력하고 종료
4. `Out of host capacity` → `RETRY_INTERVAL`초 후 재시도
5. `TooManyRequests (429)` → 120초 고정 대기 후 재시도
6. 기타 오류 → `RETRY_INTERVAL`초 후 재시도
7. 로그: 스크립트와 동일 디렉터리의 `create_arm_instance.log`

### 성공 시 로그 예시

```
[SUCCESS] 인스턴스 생성 성공! (시도: N회)
OCID: ocid1.instance.oc1...
Public IP: x.x.x.x
SSH 접속: ssh -i ~/.ssh/oracle_arm opc@x.x.x.x
```

---

## 로그 확인

```bash
# 실시간
tail -f create_arm_instance.log

# 성공 여부만
grep -E 'SUCCESS|Public IP' create_arm_instance.log
```

---

## 개선이 필요한 점

### 기능
- **리전 고정**: 현재 `ap-chuncheon-1`만 지원. `-R/--region` 옵션 추가 및 리전별 이미지 OCID 매핑으로 확장 필요
- **멀티 AD 순환**: 용량 부족 시 동일 AD만 재시도함. 리전 내 복수 AD를 순서대로 시도하면 성공 확률 향상
- **중단 신호 처리**: `Ctrl+C` 시 로그에 종료 메시지를 남기는 `trap` 핸들러 없음
- **스토리지 미할당**: 인스턴스 프로비저닝 후 블록 볼륨 스토리지는 자동 할당되지 않음. OCI 콘솔 또는 CLI에서 수동으로 연결 및 마운트 필요

### 안정성
- **사전 검증 부재**: 스크립트 시작 시 `oci`, `python3` 설치 여부 및 SSH 키 파일 존재 여부를 확인하지 않음 (SSH 키 없으면 인스턴스 생성 후 접속 불가)
- **JSON 파싱**: `python3 -c` 인라인 방식 대신 `jq` 또는 OCI CLI `--query` 옵션 사용 시 가독성·안정성 향상
- **429 대기 고정값**: 항상 120초 고정. 지수 백오프(exponential backoff) 적용 권장

### 보안
- **OCID 커맨드라인 노출**: 인자로 전달된 OCID는 `ps` 명령으로 노출됨. 환경변수 또는 `.env` 파일 방식 지원 추가 권장
- **로그 파일 권한**: 로그에 OCID 등 민감 정보가 기록되므로 `chmod 600` 자동 적용 고려

---

## 참고

- Oracle Always Free 한도: AMD Micro 2개 + ARM 4OCPU/24GB (별개 쿼터)
- ARM 용량 부족은 Oracle 서버 상황에 따라 수시간~수일 소요될 수 있음
- OCI 인증: API 프라이빗 키 방식 (세션 만료 없음)
