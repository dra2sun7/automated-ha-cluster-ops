# 📡 Phase 3-1: 주키퍼 프리(Zookeeper-less) 지향, KRaft 아키텍처 기반 Kafka 단독 분산 클러스터 백서

본 문서는 Apache Kafka의 최신 아키텍처 표준인 **KRaft(Kafka Raft)** 모듈을 활용하여, 외부 분산 코디네이터인 Zookeeper 없이 카프카 단독(Standalone Cluster Mode)으로 고가용성 메타데이터 합의체를 구성하는 이론적 배경과 분산 흐름을 기술합니다.

---

## 🏗️ 1. 아키텍처 패러다임의 변화 (Zookeeper vs KRaft)

기존의 카프카 클러스터는 메타데이터 관리와 브로커 상태 감시를 외부 솔루션인 Zookeeper에 전적으로 의존하는 이중 구조였습니다. KRaft는 이러한 구조적 한계를 극복하기 위해 제안된 자체 분산 합의 메커니즘입니다.



### ❌ 기존 Zookeeper 방식의 한계
* **이중 관리 오버헤드:** 카프카 브로커 외에 주키퍼 앙상블 프로세스를 별도로 관리해야 하므로 방화벽 포트, 디렉토리 권한, 구성 설정 파일이 배로 늘어납니다.
* **메타데이터 동기화 병목:** 브로커나 파티션이 수만 개 이상으로 늘어날 경우, 주키퍼와 카프카 브로커 간의 상태 동기화 속도가 저하되어 리더 선출(Leader Election) 및 장애 복구 타임라인이 길어집니다.

### ⭕ KRaft 방식의 혁신
* **단일 데몬 통합:** 외부 프로세스가 완전히 소멸하고 오직 **Kafka JVM 프로세스 하나**만 가동됩니다.
* **초고속 장애 복구:** 메타데이터가 카프카 내부의 전용 로그 파티션(`__cluster_metadata`)에서 직접 관리되므로, 특정 브로커가 다운되었을 때 새로운 컨트롤러 대장을 선출하는 속도가 밀리초(ms) 단위로 단축됩니다.

---

## 🗺️ 2. KRaft 클러스터 토폴로지 (Target Topology)

우리가 3대의 격리 노드(`node0, 1, 2`)에 구축할 KRaft 클러스터의 물리적/논리적 구조입니다.

```graph TB
    subgraph VPC ["AWS VPC - 격리 구역 (Private Subnet)"]
        direction LR
        
        node0["<b>node0 (Node ID: 0)</b><br>• Broker 역할<br>• Controller 역할"]
        node1["<b>node1 (Node ID: 1)</b><br>• Broker 역할<br>• Controller 역할"]
        node2["<b>node2 (Node ID: 2)</b><br>• Broker 역할<br>• Controller 역할"]
        
        %% KRaft 내부 Raft 합의체 메쉬 네트워크 교신 채널 (9093 포트)
        node0 <--> |Raft 합의체 통신 : 9093| node1
        node1 <--> |Raft 합의체 통신 : 9093| node2
        node2 <--> |Raft 합의체 통신 : 9093| node0
    end

    Client["<b>외부 애플리케이션 / 서비스</b><br>(Producer & Consumer)"]
    
    %% 클라이언트 트래픽 진입 (9092 포트)
    Client ==> |이벤트 스트림 송수신 : 9092| node0
    Client ==> |이벤트 스트림 송수신 : 9092| node1
    Client ==> |이벤트 스트림 송수신 : 9092| node2

    %% 스타일 정의
    style VPC fill:#f9f9f9,stroke:#333,stroke-width:2px;
    style node0 fill:#e1f5fe,stroke:#0288d1,stroke-width:2px;
    style node1 fill:#e1f5fe,stroke:#0288d1,stroke-width:2px;
    style node2 fill:#e1f5fe,stroke:#0288d1,stroke-width:2px;
    style Client fill:#fff3e0,stroke:#f57c00,stroke-width:2px;
```


본 구성에서는 3대의 노드가 메시지를 전달하는 **브로커(Broker) 역할**과 클러스터 의회를 통제하는 **컨트롤러(Controller) 역할**을 동시에 수행하는 하이브리드 모드로 매핑되어 완벽한 3중 고가용성(HA)을 달성합니다.

---

## 📚 3. KRaft 작동 원리 및 핵심 이론

KRaft 아키텍처를 지탱하는 핵심 메커니즘과 통신 흐름은 다음과 같습니다.

### ① Raft 합의 알고리즘 (Active Controller Election)
주키퍼가 하던 대장 선출을 카프카 내부의 **Raft 프로토콜**이 전담합니다. 
* 3대의 컨트롤러 노드 중 한 대가 투표를 통해 **액티브 컨트롤러(Active Controller, 대장)**로 선출됩니다.
* 나머지 2대의 노드는 **팔로워 컨트롤러(Standby Controller)**가 되어 대장의 메타데이터 로그를 실시간으로 복제하며 비상대기 상태를 유지합니다.

### ② 쿼럼 보터(Quorum Voters) 메커니즘
설정 파일의 `controller.quorum.voters` 옵션을 통해 3대 노드가 서로의 존재를 명확히 인지합니다.
* 예: `0@node0사설IP:9093, 1@node1사설IP:9093, 2@node2사설IP:9093`
* 이 정족수 투표단(Voters)은 내부 통신 전용 포트인 **9093번**을 통해 심장박동 패킷(Heartbeat)을 주고받으며 상호 감시를 전개합니다.

### ③ 클러스터 고유 식별자 (Cluster ID Formatting)
KRaft 환경에서는 최초에 생성한 단 하나의 **고유 암호화 UUID(Cluster ID)**를 기반으로 전체 노드들의 데이터 디렉토리를 포맷팅해야 합니다. 
* 동일한 Cluster ID로 포맷팅된 브로커들만 하나의 쿼럼(의회) 조직원으로 인정받아 교신할 수 있는 강력한 보안 체계가 작동합니다.

---

## 🎯 4. 인프라적 기대 효과 (Expected Benefits)

1. **FinOps 관점의 단순화:** 주키퍼 프로세스가 완전히 소멸하므로 인스턴스의 CPU 및 가상 메모리(Heap Memory) 자원 낭비가 대폭 줄어듭니다.
2. **Configuration Management 편의성:** 앤서블 코드가 극도로 경량화됩니다. 주키퍼용 데이터 디렉토리 생성, `myid` 바인딩, `zookeeper.properties` 관련 설정이 통째로 걷어내 지므로 유지보수 난이도가 낮아집니다.
3. **무중단 신뢰성(Reliability) 극대화:** 3대 중 특정 브로커가 예고 없이 다운되더라도, 내부 Raft 엔진이 수 밀리초 만에 컨트롤러 권한을 이양받으므로 외부 클라이언트 앱 입장에서 트래픽 단절이나 지연을 체감할 수 없는 고가용성 인프라가 실현됩니다.
