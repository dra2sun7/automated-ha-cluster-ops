# terraform/main.tf

# 1. 독립된 가상 네트워크 망(VPC) 생성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.environment}-vpc"
  }
}

# 2. 외부 통신용 Public 서브넷 (인터넷 관문 영역)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.environment}-public-subnet"
  }
}

# 3. 내부 클러스터 상주용 격리된 Private 서브넷 (보안 영역)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "${var.environment}-private-subnet"
  }
}

# 4. VPC의 외부 인터넷 관문(Gateway) 개방
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment}-igw"
  }
}

# 5. Public 서브넷 전용 라우팅 테이블 (모든 외부 트래픽을 게이트웨이로 향하게 함)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.environment}-public-rt"
  }
}

# 6. 라우팅 테이블을 Public 서브넷에 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 7. 외부 관문(Public) 서브넷용 보안 그룹: 외부 접속(SSH) 포트 제어
resource "aws_security_group" "bastion_sg" {
  name        = "${var.environment}-bastion-sg"
  description = "Allow SSH traffic to Bastion Host"
  vpc_id      = aws_vpc.main.id

  # 인바운드(Inbound): 외부에서 서버로 들어오는 트래픽 규칙
  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 포트폴리오 환경을 위해 우선 전면 개방
  }

  # 아웃바운드(Outbound): 서버에서 외부 인터넷으로 나가는 트래픽 규칙
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1은 모든 프로토콜(TCP, UDP 등)을 허용함을 의미
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment}-bastion-sg"
  }
}

# 8. 내부 벙커(Private) 클러스터용 보안 그룹: 내부 노드 간 상호 전면 개방 및 Bastion 경유 강제화
resource "aws_security_group" "cluster_sg" {
  name        = "${var.environment}-cluster-sg"
  description = "Security group for Kafka and Elasticsearch internal traffic"
  vpc_id      = aws_vpc.main.id

  # [접근 제어] SSH(22번) 접속은 오직 7번 Bastion 보안 그룹을 가진 가상 머신을 통해서만 진입 가능
  ingress {
    description     = "SSH only from Bastion Host"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id] # Bastion SG ID 연쇄 바인딩
  }

  # [플랫폼 내부 통신] 이 보안 그룹을 함께 나눠 가진 클러스터 노드끼리는 모든 포트 통신을 제한 없이 허용
  ingress {
    description = "Allow all traffic between cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true # 자기 자신(동일 보안 그룹 구성원)들 간의 통신 허용
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment}-cluster-sg"
  }
}

# 9. 외부 관문용 Bastion Host 가상 머신 생성 (Public 서브넷 배치)
resource "aws_instance" "bastion" {
  ami           = "ami-040c33c6a51fd5d96" # Ubuntu 22.04 LTS 서울 리전 최신 AMI ID
  instance_type = var.instance_type       # variables.tf에 정의된 t2.micro 수혈
  key_name      = aws_key_pair.cluster_key.key_name

  subnet_id              = aws_subnet.public.id                  # 2번 Public 서브넷에 상주
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]     # 7번 방화벽 옷 장착

  # 프리티어 기본 디스크 용량 설정 (최소화)
  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.environment}-bastion"
  }
}

# 10. 내부 격리 구역의 분산 클러스터용 기본 가상 머신 생성 (Private 서브넷 배치)
resource "aws_instance" "cluster_nodes" {
  count         = 3                       # 분산 환경 구성을 위해 총 3대의 서버를 동시에 생성
  ami           = "ami-040c33c6a51fd5d96" # 동일한 Ubuntu 22.04 LTS 적용
  instance_type = var.instance_type       # 프리티어 t2.micro 적용
  key_name      = aws_key_pair.cluster_key.key_name

  subnet_id              = aws_subnet.private.id                 # 3번 격리된 Private 서브넷에 상주
  vpc_security_group_ids = [aws_security_group.cluster_sg.id]     # 8번 벙커 전용 방화벽 옷 장착

  root_block_device {
    volume_size = 8 # 8GB * 3대 = 24GB (프리티어 제한인 총 30GB 이내로 안전하게 통제)
    volume_type = "gp3"
  }

  tags = {
    # count.index(0, 1, 2)를 사용하여 서버 이름이 node-0, node-1, node-2로 자동 넘버링되게 설정
    Name = "${var.environment}-node-${count.index}"
  }
}

# 11. 가상 머신 접속용 SSH 공개키(자물쇠) 등록
resource "aws_key_pair" "cluster_key" {
  key_name   = "${var.environment}-key"
  public_key = file("${path.module}/my-cluster-key.pub") # 방금 생성한 pub 파일 자동 로드
}

# 12. 배포 완료 후 외부에서 접속할 Bastion Host의 공인 IP 주소 출력
output "bastion_public_ip" {
  description = "The public IP address of the bastion host"
  value       = aws_instance.bastion.public_ip
}
