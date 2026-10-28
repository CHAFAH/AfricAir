# AfricAir on AWS: architecture (Projects 4 and 5)

```mermaid
flowchart LR
  user([Browser]) -->|HTTPS| alb

  subgraph vpc["VPC 10.40.0.0/16 (3 AZs)"]
    subgraph pub["Public subnets 10.40.0-2.0/24"]
      alb["ALB (group africair)<br/>created by AWS Load Balancer Controller"]
      nat[NAT gateway ×1]
    end
    subgraph priv["Private subnets 10.40.16/32/48.0/20: EKS nodes (AL2023, IMDSv2 hop 1)"]
      subgraph ns["namespace africair-staging / africair-production"]
        web["web ×2–6<br/>nginx :8080"]
        api["api ×2–6<br/>:4000 app · :9464 metrics"]
        mig["migrate Job"]
        bak["backup CronJob 02:00"]
      end
      eso["External Secrets Operator"]
      lbc["AWS Load Balancer Controller"]
      argo["Argo CD (Project 5)"]
      mon["Prometheus · Alertmanager · Grafana (Project 5)"]
    end
    subgraph db["Database subnets 10.40.100-102.0/24 (no internet route)"]
      rds[("RDS PostgreSQL 16<br/>force_ssl, private")]
    end
  end

  alb -->|"/ (target-type ip)"| web
  alb -->|"/api"| api
  api -->|5432 TLS| rds
  mig -->|5432| rds
  bak -->|pg_dump| rds
  bak -->|PutObject via Pod Identity| s3[("S3 backups<br/>africair/staging/*")]
  mon -->|scrape :9464| api

  sm[("Secrets Manager<br/>RDS master secret · africair/&lt;env&gt;/app · africair/platform/*")] -->|GetSecretValue via Pod Identity| eso
  ssm[("SSM Parameter Store<br/>/africair/staging/db/*")] --> eso
  eso -->|"Secret africair-db → env DATABASE_URL"| api
  eso -->|"Secret africair-app → files /var/run/secrets/africair"| api
  kms{{"KMS key (rotation on)<br/>K8s Secrets · RDS · Secrets Manager · S3"}} -.-> sm
  kms -.-> rds

  ecr[("ECR africair-web / africair-api")] -->|pull by node role| ns
  git[(GitHub repo)] -->|"pull (Project 5)"| argo
  argo -->|sync| ns
  ci["GitHub Actions / CircleCI (OIDC)"] -->|push :sha| ecr
  ci -->|"commit image.tag"| git
  nat --> internet((Internet))
```

- Only the ALB is internet-facing. Nodes reach the internet through the single NAT gateway; RDS can't.
- Every AWS permission inside the cluster comes from **EKS Pod Identity**: ESO, the load balancer
  controller, the EBS CSI driver and the backup job each have their own role, scoped by namespace and
  service account in the trust policy.
- Secret values exist only in Secrets Manager and as Kubernetes Secrets (envelope-encrypted with KMS).
  They are never in Git, Terraform state or CI logs.
