project     = "africair"
environment = "stg"
region      = "eu-west-1"
# aws_profile = "africair"               # or export AWS_PROFILE

kubernetes_version = "1.35"
# api_allowed_cidrs = ["203.0.113.10/32"] # your IP: curl -s https://checkip.amazonaws.com

node_instance_type = "t3.medium"
node_count         = 2
db_instance_class  = "db.t4g.micro"

github_repository = "CHAFAH/AfricAir"
# circleci_org_id     = "00000000-0000-0000-0000-000000000000"
# circleci_project_id = "00000000-0000-0000-0000-000000000000"

admin_iam_arns = ["arn:aws:iam::075120018043:user/landmark-eks"]
