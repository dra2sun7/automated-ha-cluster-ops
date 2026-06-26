# 📡 Phase 1: Zero-Touch Infrastructure Automation Pipeline

본 문서는 Terraform(IaC)을 활용한 클라우드 가상 가상 사설망(VPC) 인프라 프로비저닝과 Ansible(CM) 구성 관리 엔진을 유기적으로 융합하여, 최초 배포부터 내부 은닉 노드 통신 검증까지 수동 개입률 0%를 달성한 무중단 파이프라인 구축 연대기를 기록합니다.

---

## 🏗️ 1. 엔지니어링 아키텍처 도면 (Network Topology)

본 프로젝트는 보안 무결성을 극대화하기 위해 관문 역할을 수행하는 Public Subnet의 Bastion Host와, 실제 분산 클러스터가 구동되는 격리된 Private Subnet 구조로 설계되었습니다.

* **로컬 개발 호스트 (Local Ubuntu):** Ansible 사령관 엔진 및 Terraform 제어소 구동.
* **중간 징검다리 (Bastion Host):** 외부 인터넷과 통하는 유일한 관문 (Public IP).
* **내부 격리 노드 (Kafka Nodes 0, 1, 2):** 외부와 차단된 채 사설 IP만 보유 (Private Subnet).

---

## 🔌 2. 완전 자동화 파이프라인 핵심 설계 (Core Mechanics)

학습 및 테스트 환경 특성상 인프라를 On-Demand로 파괴하고 재건축(`destroy` & `apply`)할 때마다 자원의 IP 주소가 동적으로 계속 변하는 병목이 존재했습니다. 본 파이프라인은 이를 **역할 기반 코드 생성 기법**으로 완벽히 해결했습니다.

### 🔹 1단계: 테라폼의 동적 자산 수집 및 인벤토리 실시간 빌드
테라폼 컴파일 완료 직후, AWS로부터 갓 발급된 Bastion의 최신 공인 IP와 내부 노드 3대의 사설 IP를 실시간으로 가로채어 Ansible의 `inventory.ini` 파일을 100% 코드로 자동 작성(Overwrite)합니다.

### 🔹 2단계: 에이전트 포워딩을 이용한 프록시 터널링 통합
Ansible의 `ansible_ssh_common_args` 속성을 통해 로컬의 SSH 열쇠 권한을 Bastion Host에게 안전하게 인계(`ForwardAgent=yes`)하고, 징검다리 프록시 명령어(`ProxyCommand="ssh -W ..."`) 내부에서 호스트 키 검증을 우회하도록 설계하여 소켓 충돌을 예방했습니다.

---

## 📝 3. 파이프라인 최종 자산 형상 (Configuration)

### 📂 `terraform/main.tf` (동적 파일 생성 훅)
```hcl
# 모든 동적 IP(공인/사설)를 취합하여 하나의 완벽한 인벤토리 파일로 실시간 빌드
resource "local_file" "ansible_inventory" {
  filename = "$${path.module}/../ansible/inventory.ini"
  content  = <<EOT
[kafka_nodes]
node0 ansible_host=${aws_instance.cluster_nodes[0].private_ip}
node1 ansible_host=${aws_instance.cluster_nodes[1].private_ip}
node2 ansible_host=${aws_instance.cluster_nodes[2].private_ip}

[kafka_nodes:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=../terraform/my-cluster-key
ansible_python_interpreter=/usr/bin/python3

ansible_ssh_common_args='-o ForwardAgent=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="ssh -W %h:%p -i ../terraform/my-cluster-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_instance.bastion.public_ip}"'
EOT
}
```

### 📂 `ansible/ansible.cfg` (기본형 박제)
```ini
[defaults]
inventory = ./inventory.ini
host_key_checking = False
```

---

## 🚀 4. 파이프라인 가동 및 통신 검증 결과 (Validation)

인프라 완전 철거 후 재배포 단계부터 Ansible 핑 테스트까지 **단 한 번의 수동 개입(키보드 입력, 파일 수정) 없이** 무중단으로 통과한 최종 성공 텔레메트리입니다.

```bash
# 1. 인프라 철거 후 재생성
cd terraform/
terraform destroy -auto-approve
terraform apply -auto-approve

# 2. 제어소 이동 후 무중단 교신 실행
cd ../ansible/
ansible kafka_nodes -m ping
```

### 📊 최종 성공 터미널 로그 출력 (Telemetry)
```json
node1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
node0 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
node2 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

### 🎯 기대 효과 및 결론
본 설계를 통해 인프라 인스턴스의 생명주기가 변동되더라도 운영 오버헤드가 제로(0)에 수렴하는 확장성 높은 인프라 환경을 확보했습니다. 이를 바탕으로 인프라 스트레스 튜닝 및 애플리케이션(Kafka) 대규모 배포 아키텍처로 진격할 수 있는 안정적인 발판을 마련했습니다.
