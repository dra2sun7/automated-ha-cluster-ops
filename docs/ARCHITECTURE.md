# 🌐 Network Architecture: VPC 사설망 격리 및 라우팅 설계 백서

본 문서는 대용량 데이터 플랫폼 인프라의 가용성과 보안성을 확보하기 위해 **Terraform(IaC)**으로 구현한 가상 네트워크(VPC) 및 서브넷 격리 아키텍처의 설계 당위성과 세부 명세를 기록한 기술 백서입니다.

---

## 🏗️ 1. 네트워크 토폴로지 (Network Topology)

```mermaid
graph TD
    %% 글로벌 스타일 정의
    classDef vpcStyle fill:#f9f9f9,stroke:#333,stroke-width:2px,stroke-dasharray: 5 5;
    classDef publicStyle fill:#e1f5fe,stroke:#0288d1,stroke-width:2px;
    classDef privateStyle fill:#efebe9,stroke:#5d4037,stroke-width:2px;
    classDef nodeStyle fill:#fff,stroke:#333,stroke-width:1px;
    classDef internetStyle fill:#fff3e0,stroke:#ffb74d,stroke-width:2px;

    %% 외부 인터넷 세계
    Internet((인터넷 세계<br>Internet)):::internetStyle

    %% AWS VPC 경계
    subgraph VPC [🛡️ 최외곽 경계: 사설 가상 데이터 센터 VPC 10.0.0.0/16]
        IGW[🚪 정문: Internet Gateway]:::nodeStyle
        
        %% Public 서브넷 구역
        subgraph PublicSubnet [🌐 1번 성벽: Public 서브넷 10.0.1.0/24]
            Bastion[🖥️ 외부 관문용 서버<br>Bastion Host]:::nodeStyle
        end
        
        %% Private 서브넷 구역
        subgraph PrivateSubnet [🔒 2번 성벽: Private 서브넷 10.0.2.0/24]
            subgraph KafkaCluster [🗄️ 분산 버퍼 레이어]
                Kafka[Apache Kafka<br>Cluster 3 노드]:::nodeStyle
            end
            
            subgraph ESCluster [💾 분산 검색 엔진 및 저장소]
                ES[Elasticsearch<br>Cluster 3 노드]:::nodeStyle
            end
        end
    end

    %% 클래스 지정
    class VPC vpcStyle;
    class PublicSubnet publicStyle;
    class PrivateSubnet privateStyle;

    %% 트래픽 흐름 및 차단 관계 선언
    Internet -->|공인 트래픽 진입| IGW
    IGW -->|Public 라우팅 테이블 안내| Bastion
    Bastion -->|내부 사설망 SSH 경유| Kafka
    Bastion -->|내부 사설망 SSH 경유| ES
    
    %% 외부 차단선 표현
    Internet -.->|X 직접 통신 불가 X| PrivateSubnet

    %% 링크 스타일링 (차단선 빨간색 강조)
    linkStyle 4 stroke:#e53935,stroke-width:2px,stroke-dasharray: 5 5;
```

---

## 🛡️ 2. 아키텍처 설계 의도 및 보안 당위성

### ① 제로 트러스트(Zero Trust) 기반의 망 분리
* **설계 목적**: 분산 저장소(Elasticsearch)와 메시지 큐(Kafka)는 기업의 중요 원본 데이터와 인프라 메타데이터를 담고 있으므로 외부 인터넷 환경에 노출될 경우 스캐닝 및 무차별 대입 공격의 타깃이 됩니다.
* **구현 핵심**: 
  * 외부와 소통하는 관문 구역인 **Public Subnet(`10.0.1.0/24`)**과 내부 격리 구역인 **Private Subnet(`10.0.2.0/24`)**을 물리적으로 분리했습니다.
  * Private 서브넷은 외부 인터넷 정문(Internet Gateway)으로 향하는 이정표가 라우팅 테이블에 존재하지 않으므로, 외부 공격자가 직접 사설 IP 주소로 패킷을 주입하는 행위가 구조적으로 불가능합니다.

### ② 명확한 네트워크 컴포넌트 역할 정의
* **VPC (`10.0.0.0/16`)**: AWS 공용 클라우드 환경 내에서 우리 인프라 자원만을 독점적으로 보호하는 거대한 논리적 사설 데이터 센터의 경계를 형성합니다.
* **Public Subnet**: 외부 관리자가 내부 인프라에 안전하게 접근하기 위한 유일한 경유지인 **Bastion Host(문지기 서버)**가 상주하는 영역입니다. `map_public_ip_on_launch = true` 옵션을 통해 외부 통신용 공인 IP를 자동 제어합니다.
* **Private Subnet**: 오직 내부 통신망 및 Bastion Host를 통한 내부 사설 라우팅으로만 접근 가능한 핵심 보안 구역입니다. **Kafka 브로커 3노드**와 **Elasticsearch 3노드**가 이 안전한 구역 내에서 상주하며 상호 통신을 수행합니다.

---

## 📊 3. 서브넷 및 주소 공간 할당 명세 (IP IPAM)

Terraform 자원의 확장성을 고려하여 CIDR 대역을 사전에 체계적으로 분할 지정했습니다.

| 서브넷 명칭 | 할당 CIDR 블록 | 가용 IP 개수 | 외부 인터넷 통신 여부 | 배치 자원 역할 |
| :--- | :--- | :--- | :--- | :--- |
| **VPC 기본 대역** | `10.0.0.0/16` | 65,536개 | 사설망 전체 경계 | 프로젝트 전용 가상 데이터 센터 |
| **Public Subnet** | `10.0.1.0/24` | 251개 | **가능 (In/Outbound)** | Bastion Host, 외부 인프라 관문 계층 |
| **Private Subnet** | `10.0.2.0/24` | 251개 | **불가 (내부 사설 통신만)** | Kafka Cluster, Elasticsearch Cluster |

---

## ⚙️ 4. 관련 인프라 선언 코드 (Terraform Reference)

본 아키텍처는 `terraform/main.tf` 파일의 선언적 코드를 통해 휴먼 에러 없이 동일한 규격으로 복제 및 제거가 가능합니다.

```hcl
# 가상 네트워크(VPC) 및 서브넷 핵심 선언부 예시

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
}
```
