# AfricAir on AWS: architecture (staging)

```mermaid
flowchart LR
  user([Browser]) -->|HTTP| alb

  subgraph vpc["VPC 10.40.0.0/16 (2 AZs)"]
    subgraph pub["Public subnets 10.40.0.0/20, 10.40.16.0/20"]
      alb["Application Load Balancer<br/>(created by the AWS Load Balancer Controller)"]
      subgraph eks["EKS africair-stg-cluster · 2 × t3.medium"]
        subgraph ns["namespace africair-staging"]
          web["web ×2<br/>nginx :8080"]
          api["api ×2<br/>:4000"]
          mig["migrate Job"]
        end
        lbc["AWS Load Balancer Controller"]
        eso["External Secrets Operator"]
      end
    end
    subgraph priv["Private subnets 10.40.100.0/24, 10.40.101.0/24 (no internet route)"]
      rds[("RDS PostgreSQL 16<br/>db.t4g.micro, TLS only")]
    end
  end

  alb -->|"/"| web
  alb -->|"/api"| api
  api -->|5432| rds
  mig -->|5432| rds

  tf["terraform apply<br/>(local state)"] -->|"generates secrets"| sm[("Secrets Manager<br/>africair/stg/app · africair/stg/db")]
  sm -->|Pod Identity| eso
  eso -->|"Secret africair-db (env DATABASE_URL)"| api
  eso -->|"Secret africair-app (files ADMIN_TOKEN, PROMO_CODES)"| api

  ecr[("ECR africair-web · africair-api")] -->|pull| eks
  ci["GitHub Actions / CircleCI<br/>(OIDC role)"] -->|push images| ecr
  ci -->|helm upgrade| ns
```

- Only the ALB receives traffic from the internet. The nodes have public IPs (no NAT gateway), but
  their security group admits nothing from outside the cluster and the ALB.
- RDS lives in subnets with no internet route and accepts 5432 only from the cluster security group.
- AWS permissions inside the cluster come from **EKS Pod Identity**: one role for the Load Balancer
  Controller, one for External Secrets (read-only on the two secrets).
