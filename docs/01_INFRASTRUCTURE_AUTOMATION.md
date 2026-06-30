# 📡 Phase 1 & 2: 테라폼-앤서블 연동망 구축 및 Bastion 프록시 기반 격리 노드 커널 최적화 백서

본 문서는 인프라 프로비저닝 도구(Terraform)와 구성 관리 엔진(Ansible)을 융합하는 과정에서 마주한 심각한 네트워크 통신 병목과 소켓 교착 문제를 엔지니어링 관점에서 어떻게 분석하고, 가설을 세워 해결했는지에 대한 논리적 여정을 기록합니다.

---

## 🏗️ 1. 초기 아키텍처 목표 (Target Topology)

보안 무결성을 극대화하기 위해 외부 인터넷과 단절된 Private Subnet 내에 3대의 격리 노드(`node0, 1, 2`)를 배치하고, 오직 Public Subnet의 Bastion Host를 통해서만 내부로 진입할 수 있는 안전한 징검다리 프록시 구조를 설계했습니다.



---

## 🚨 2. 직면한 문제 (The Problem)

인프라를 생성한 직후, 로컬 호스트에서 Ansible 사령관을 통해 내부 격리 노드들에게 시스템 최적화 및 Java 17 일괄 설치(`ansible-playbook`)를 시도했으나 아래와 같이 패키지 캐시 업데이트 단계에서 무한 타임아웃이 발생하며 파이프라인이 중단되었습니다.

```json
TASK [우분투 apt 캐시 업데이트 및 필수 유틸리티 설치] ******************************************************************
[WARNING]: Failed to update cache after 5 retries due to , retrying
fatal: [node0]: FAILED! => {"changed": false, "msg": "Failed to update apt cache after 5 retries: "}
```

---

## 🔬 3. 원인 추적 및 디버깅 가설 (Hypothesis & Debugging)

문제의 본질을 파헤치기 위해 에러 메시지와 인프라 구성을 단계별로 쪼개어 논리적 추론을 전개했습니다.

### 💡 가설 1: 인바운드(들어오는 길)의 문제인가?
* **분석:** `ansible kafka_nodes -m ping`을 통한 내부 노드 교신은 성공했습니다. 즉, 로컬 PC ➔ Bastion Host ➔ Private 노드로 이어지는 SSH 프록시 터널링 고속도로는 완벽히 정상 작동 중이었습니다.

### 💡 가설 2: 아웃바운드(나가는 길) 통신 단절 (근본 원인)
* **분석:** `apt update` 명령어는 내부 노드가 외부 인터넷 세상에 있는 우분투 미러 서버(`archive.ubuntu.com`)로 직접 패킷을 쏘고 받아와야 합니다.
* **결론:** 그러나 Private Subnet에 상주하는 노드들은 사설 IP만 가지고 있고, 외부 인터넷망으로 나가는 게이트웨이(지도)가 완전히 부재했습니다. 이에 따라 아웃바운드 트래픽이 VPC 내부망에 갇혀 타임아웃 에러를 발생시켰습니다.

---

## 💰 4. 엔지니어링 비용 최적화 고찰 (FinOps)

AWS 환경에서 격리 구역에 인터넷을 공급하는 정석 솔루션은 **NAT Gateway**와 **EIP(고정 공인 IP)**의 조합입니다. 그러나 이는 프리티어 제외 자원으로, 아키텍처 유지를 위한 고정 비용이 청구되는 부담이 있었습니다.

* **엔지니어의 결정:** 단순히 초기 패키지 수혈(`apt install`)만을 위해 상시 비용이 발생하는 NAT Gateway를 도입하는 것은 비효율적이라 판단. 
* 이미 완벽하게 구축되어 있는 **Bastion Host를 0원짜리 아웃바운드 HTTP 프록시 서버(Squid)로 개조**하여, 인프라 추가 비용을 단 1원도 쓰지 않는 무료 우회 라우팅 경로를 설계하기로 결정했습니다.

---

## 🛠 `5`. 점진적 해결 과정 및 아키텍처 진화 (Resolution Steps)

### 1단계: 테라폼을 통한 Bastion 사설 IP 및 방화벽 동적 제어
수동 개입률 0%를 유지하기 위해 `main.tf` 코드를 고도화했습니다. 테라폼이 AWS로부터 받아온 Bastion의 사설 IP를 인벤토리 변수(`bastion_private_ip`)로 실시간 사출하도록 설정했습니다. 또한, 내부 노드들이 Bastion의 프록시 포트로 패킷을 보낼 수 있도록 Bastion 보안 그룹(`bastion_sg`)에 **3128번 인바운드 허용 규칙**을 연쇄 바인딩했습니다.

### 2단계: 앤서블 플레이북의 2단계 오케스트레이션 설계
플레이북을 개정하여 **[STEP 1]** 로컬 PC에서 Bastion의 공인 IP로 안전하게 원격 접속해 오픈소스 프록시인 `Squid`를 자동 구성하도록 처리했습니다. 그 후 **[STEP 2]**에서 내부 노드들의 플레이북 가동 환경 변수(`environment`)에 테라폼이 준 `http_proxy: "http://{{ bastion_private_ip }}:3128"`를 동적으로 주입했습니다.

---

## 📝 6. 최종 완성된 인프라 자산 형상 (Code)

### 📂 `terraform/main.tf` (Bastion 보안 그룹 및 동적 인벤토리 훅)
```hcl
# Bastion 보안 그룹 내부에 3128 프록시 포트 개방
resource "aws_security_group" "bastion_sg" {
  name        = "${var.environment}-bastion-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow proxy traffic from internal VPC nodes"
    from_port   = 3128
    to_port     = 3128
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block] # 내부 사설망 트래픽만 허용
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 모든 동적 자산 취합 및 변수 사출 훅
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
bastion_private_ip=${aws_instance.bastion.private_ip}

ansible_ssh_common_args='-o ForwardAgent=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="ssh -W %h:%p -i ../terraform/my-cluster-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_instance.bastion.public_ip}"'
EOT
}
```

---

## 🚀 7. 최종 검증 및 엔지니어링 성과 (Validation)

인프라 반영 후, 단 한 번의 수동 조작이나 파일 수정 없이 `ansible-playbook` 명령 단 한 줄로 **[프록시 망 개척 ➔ 아웃바운드 통신망 확보 ➔ Java 17 수혈 및 OS 커널 튜닝]**까지 일사천리로 완수되었습니다.

### 📊 최종 성공 텔레메트리 (Ansible Play RECAP)
```json
TASK [설치된 Java 버전 로그 출력] **************************************************************************************
ok: [node0] => { "msg": "openjdk version \"17.0.19\" 2026-04-21" }
ok: [node1] => { "msg": "openjdk version \"17.0.19\" 2026-04-21" }
ok: [node2] => { "msg": "openjdk version \"17.0.19\" 2026-04-21" }

PLAY RECAP *************************************************************************************************************
node0                      : ok=8    changed=4    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
node1                      : ok=7    changed=4    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
node2                      : ok=7    changed=4    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

### 🎯 본 트러블슈팅의 교훈 (Key Takeaways)
1. **FinOps 기반 아키텍처 설계:** 무조건 비싸고 편한 클라우드 관리형 컴포넌트(NAT GW)를 쓰기보다, 오픈소스 프록시 조합을 통해 인프라 유지 비용을 0원으로 완벽하게 방어해 냈습니다.
2. **멱등성을 활용한 복구 마인드셋:** 앤서블 플레이북 실행 도중 에러가 나더라도 상태가 꼬이거나 과거로 되돌아가지 않으므로, 원인 파악 후 코드만 정정해 재수행하면 안전하게 목표 상태(Desired State)에 도달할 수 있음을 체득했습니다.
