# 📡 Phase 1: 테라폼-앤서블 연동망 구축 및 SSH 터널링 트러블슈팅 기술 백서

본 문서는 인프라 프로비저닝 도구(Terraform)와 구성 관리 엔진(Ansible)을 융합하는 과정에서 마주한 심각한 네트워크 통신 병목과 소켓 교착 문제를 엔지니어링 관점에서 어떻게 분석하고, 가설을 세워 해결했는지에 대한 논리적 여정을 기록합니다.

---

## 🏗️ 1. 초기 아키텍처 목표 (Target Topology)

보안 무결성을 극대화하기 위해 외부 인터넷과 단절된 Private Subnet 내에 3대의 격리 노드(`node0, 1, 2`)를 배치하고, 오직 Public Subnet의 Bastion Host를 통해서만 내부로 진입할 수 있는 안전한 징검다리 프록시 구조를 설계했습니다.



---

## 🚨 2. 직면한 문제 (The Problem)

인프라를 생성한 직후, 로컬 호스트에서 Ansible 사령관을 통해 내부 격리 노드들에게 통신 검증(`ansible -m ping`)을 시도했으나 아래와 같이 치명적인 연결 실패 에러가 발생하며 파이프라인이 완전히 붕괴되었습니다.

```json
[ERROR]: Task failed: Failed to connect to the host via ssh: Connection closed by UNKNOWN port 65535
node0 | UNREACHABLE! => { "unreachable": true, "msg": "Connection timed out during banner exchange" }
```

---

## 🔬 3. 원인 추적 및 디버깅 가설 (Hypothesis & Debugging)

문제의 본질을 파헤치기 위해 에러 메시지를 단계별로 쪼개어 논리적 추론을 전개했습니다.

### 💡 가설 1: Bastion Host의 성문 자체가 막혔는가?
* **분석:** 만약 AWS 보안 그룹(Security Group)이나 IP 주소가 틀려 Bastion Host 자체에 도달하지 못했다면 `Connection refused`나 `Network is unreachable`이 떴어야 합니다.
* **결론:** 그러나 에러는 `banner exchange(프로토콜 교환)` 단계에서 타임아웃이 났습니다. 즉, **Bastion Host의 안내 데스크(성문 안쪽)까지는 완벽하게 진입했으나 그 이후 단계에서 패킷이 갇혔음**을 의미합니다.

### 💡 가설 2: 테라폼 프로비저너와 리눅스 SSH 소켓의 간섭 (근본 원인)
기존 코드에서는 테라폼 배포 직후 호스트 키 등록을 자동화하기 위해 `local-exec`를 통해 아래 명령어를 실행하도록 설계했습니다.
```bash
ssh-keyscan -H ${self.public_ip} >> ~/.ssh/known_hosts
```
* **발견한 맹점:** `ssh-keyscan`은 단순히 텍스트만 긁어오는 것이 아니라, 대상 서버와 실제 임시 SSH 핸드셰이크를 맺습니다. 이 과정에서 발생한 비정상적인 세션 찌꺼기가 로컬 리눅스의 SSH 소켓 풀에 꼬인 채 남게 되었습니다.
* 그 직후 Ansible이 `ProxyCommand` 터널을 타고 Bastion에 들어갔을 때, 꼬여있는 소켓 세션과 충돌을 일으키며 내부 노드로 패킷을 토스하지 못하고 문 앞에서 하염없이 서성이다가 `timed out during banner exchange`를 뿜은 것입니다.

### 💡 가설 3: 동적 자산(사설 IP)의 현행화 누락
인프라를 재구축(`destroy` 후 `apply`)할 때마다 Bastion의 공인 IP뿐만 아니라 내부 노드 3대의 사설 IP(`10.0.2.x`) 역시 계속해서 무작위로 변경되었습니다. 기존 구조에서는 `ansible/inventory.ini` 내의 사설 IP 주소들이 과거의 낡은 IP를 바라보고 있었기에 물리적인 도달 자체가 불가능한 상태였습니다.

---

## 🛠️ 4. 점진적 해결 과정 (Resolution Steps)

범인을 좁혀낸 후, 수동 개입을 0%로 만들면서도 소켓 충돌을 원천 차단하는 구조로 아키텍처를 진화시켰습니다.

### 1단계: 수동 제어권 검증 (`ssh-agent` 충전 및 포워딩 선언)
Bastion Host가 내부 벙커 노드들의 문을 대신 열려면, 내 로컬 컴퓨터가 쥐고 있는 마스터 열쇠 권한을 위임받아야 합니다. `ssh-add -l` 명령어로 로컬 메모리에 키가 충전된 것을 확인한 뒤, `ansible.cfg`에 `ForwardAgent=yes` 속성을 부여하여 인증 권한이 중간 징검다리로 안전하게 인계되도록 조치했습니다.

### 2단계: 소켓 간섭 원천 차단 및 테라폼-앤서블 결합도 해제
소켓 꼬임의 주범이었던 테라폼 내의 `ssh-keyscan` 쉘 스크립트 라인을 과감히 제거했습니다. 대신 호스트 키 검증 우회 옵션(`StrictHostKeyChecking=no`)을 Ansible의 프록시 명령어 내부에 직접 주입하여 역할을 완벽히 격리했습니다.

### 3단계: `local_file` 기반의 동적 인벤토리 단일화 빌드 (최종 진화)
`sed` 명령어로 파일을 한 줄씩 치환하던 불안정한 방식을 버리고, 테라폼의 `local_file` 리소스를 도입했습니다. 테라폼이 AWS로부터 받아온 실시간 공인/사설 IP 전반을 가로채어 `inventory.ini` 파일을 통째로 새로 구워내도록 아키텍처를 통합했습니다.

---

## 📝 5. 최종 완성된 인프라 자산 형상 (Code)

### 📂 `terraform/main.tf` (역할 기반 동적 파일 생성 훅)
```hcl
# [최종형] 모든 동적 IP를 취합하여 단 하나의 완벽한 인벤토리 파일로 실시간 오버라이트
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content  = <<EOT
[kafka_nodes]
node0 ansible_host=${aws_instance.cluster_nodes[0].private_ip}
node1 ansible_host=${aws_instance.cluster_nodes[1].private_ip}
node2 ansible_host=${aws_instance.cluster_nodes[2].private_ip}

[kafka_nodes:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=../terraform/my-cluster-key
ansible_python_interpreter=/usr/bin/python3

# 🔥 핵심 논리: 에이전트 포워딩 및 프록시 터널링 제어권을 인벤토리 변수로 완벽히 이관
ansible_ssh_common_args='-o ForwardAgent=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="ssh -W %h:%p -i ../terraform/my-cluster-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_instance.bastion.public_ip}"'
EOT
}
```

---

## 🚀 6. 최종 검증 및 엔지니어링 성과 (Validation)

인프라 전면 파괴한 후 재배포하는 극한의 상황에서도, 엔지니어의 키보드 조작이나 파일 수정이 전혀 없는 **'수동 개입률 0% (Zero-Touch)'** 상태에서 한 방에 통신망을 개척하는 데 성공했습니다.

### 📊 최종 성공 텔레메트리 (Ansible Ping)
```json
node0 | SUCCESS => { "changed": false, "ping": "pong" }
node1 | SUCCESS => { "changed": false, "ping": "pong" }
node2 | SUCCESS => { "changed": false, "ping": "pong" }
```
