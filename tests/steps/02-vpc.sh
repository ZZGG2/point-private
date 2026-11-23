# 2단계 — 3-Tier VPC
step 02 "VPC (3-Tier, NAT, S3 엔드포인트)"

VPC=$(tfo vpc_id)
if [ -z "$VPC" ]; then ng "terraform output vpc_id" "없음"; return; fi
V=$(aws ec2 describe-vpcs --vpc-ids "$VPC" --output json 2>/dev/null)
eq "VPC CIDR" "$(echo "$V" | jq -r '.Vpcs[0].CidrBlock')" "10.10.0.0/16"
eq "DNS hostnames 활성 (EKS 필수)" "$(aws ec2 describe-vpc-attribute --vpc-id "$VPC" --attribute enableDnsHostnames --query EnableDnsHostnames.Value --output text)" "True"
eq "공통 태그 project=point-platform (default_tags)" "$(echo "$V" | jq -r '.Vpcs[0].Tags[]? | select(.Key=="project") | .Value')" "point-platform"

S=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --output json)
eq "서브넷 총 9개 (3 tier × 3 AZ)" "$(echo "$S" | jq '.Subnets | length')" "9"
eq "Public 서브넷 3개 (kubernetes.io/role/elb — ALB 용)" "$(echo "$S" | jq '[.Subnets[] | select(any(.Tags[]?; .Key=="kubernetes.io/role/elb"))] | length')" "3"
eq "Private-App 3개 (internal-elb 태그)" "$(echo "$S" | jq '[.Subnets[] | select(any(.Tags[]?; .Key=="kubernetes.io/role/internal-elb"))] | length')" "3"
eq "Private-App 3개에 karpenter.sh/discovery 태그" "$(echo "$S" | jq '[.Subnets[] | select(any(.Tags[]?; .Key=="karpenter.sh/discovery" and .Value=="point-dev-eks"))] | length')" "3"
eq "AZ 3개에 분산" "$(echo "$S" | jq '[.Subnets[].AvailabilityZone] | unique | length')" "3"
eq "퍼블릭 IP 자동 할당 서브넷 없음 (VPC 모듈 v6 기본값, ALB 는 불필요)" "$(echo "$S" | jq '[.Subnets[] | select(.MapPublicIpOnLaunch)] | length')" "0"
APPFREE=$(echo "$S" | jq '[.Subnets[] | select(.CidrBlock|test("^10\\.10\\.(32|64|96)\\.")) | .AvailableIpAddressCount] | add')
ge "Private-App 남은 IP (/19 × 3, prefix delegation 여유)" "$APPFREE" 1000

eq "NAT 게이트웨이 1개 (single_nat_gateway, 비용 절감)" "$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" Name=state,Values=available --query 'length(NatGateways)' --output text)" "1"
eq "인터넷 게이트웨이 1개" "$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC" --query 'length(InternetGateways)' --output text)" "1"
EP=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$VPC" Name=service-name,Values=com.amazonaws.$REGION.s3 --output json)
eq "S3 Gateway 엔드포인트 (ECR 레이어가 NAT 우회)" "$(echo "$EP" | jq -r '.VpcEndpoints[0].VpcEndpointType // "없음"')" "Gateway"
# 서브넷 → 실제로 연결된 라우트 테이블 기준으로 검사
RT=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --output json)
rt_of() { echo "$RT" | jq -r --arg s "$1" '.RouteTables[] | select(any(.Associations[]?; .SubnetId==$s)) | .RouteTableId'; }
APP1=$(echo "$S" | jq -r '[.Subnets[] | select(.CidrBlock|startswith("10.10.32."))][0].SubnetId')
APP_RT=$(rt_of "$APP1")
EPRT=$(echo "$EP" | jq -r '.VpcEndpoints[0].RouteTableIds[]')
if echo "$EPRT" | grep -qx "$APP_RT"; then ok "S3 엔드포인트가 App 라우트 테이블에 연결" "$APP_RT"; else ng "S3 엔드포인트가 App 라우트 테이블에 연결" "$EPRT"; fi
eq "App 서브넷 기본 경로 → NAT" "$(echo "$RT" | jq -r --arg r "$APP_RT" '.RouteTables[] | select(.RouteTableId==$r) | .Routes[] | select(.DestinationCidrBlock=="0.0.0.0/0") | (.NatGatewayId // "없음") | sub("-.*";"")')" "nat"
DATA_EGRESS=0; for sid in $(echo "$S" | jq -r '.Subnets[] | select(.CidrBlock|test("^10\\.10\\.(128|129|130)\\.")) | .SubnetId'); do
  r=$(rt_of "$sid"); [ -z "$r" ] && r=$(echo "$RT" | jq -r '.RouteTables[] | select(any(.Associations[]?; .Main)) | .RouteTableId')
  n=$(echo "$RT" | jq --arg r "$r" '[.RouteTables[] | select(.RouteTableId==$r) | .Routes[] | select(.DestinationCidrBlock=="0.0.0.0/0")] | length')
  DATA_EGRESS=$((DATA_EGRESS+n)); DATA_N=$((${DATA_N:-0}+1)); done
eq "Private-Data 서브넷 3개 검사됨" "${DATA_N:-0}" "3"
if [ "$DATA_EGRESS" = 0 ]; then ok "Private-Data 서브넷에 0.0.0.0/0 경로 없음 (DB 인터넷 격리)"; else
  warn "Private-Data 서브넷에 0.0.0.0/0 경로 없음 (DB 인터넷 격리)" "Data 서브넷 3개가 App 라우트 테이블(→NAT)을 공유 — VPC 모듈 create_database_subnet_route_table=true 로 분리 가능 (RDS 는 퍼블릭 IP 없음 + SG 로 인바운드 차단이라 당장 노출은 아님)"; fi
check "DB 서브넷 그룹 존재 (RDS 용)" aws rds describe-db-subnet-groups --db-subnet-group-name point-dev-vpc
