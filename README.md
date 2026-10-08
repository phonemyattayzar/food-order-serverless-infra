# Food Order Serverless Infrastructure

This is a separate deployment of the existing Food Order application found in `food-order-3tier-aws`, using:

```text
React/Vite frontend → private S3 bucket ← CloudFront
                                  CloudFront /api/*
                                        ↓
                              API Gateway HTTP API
                                        ↓
                                  AWS Lambda
                                        ↓
                         RDS PostgreSQL (private)
```

The application lives in the `food-order-3tier-aws` source repository. Its `deploy/lambda` branch builds a versioned Lambda/frontend bundle and uploads it to this repository's private artifact S3 bucket. This repository owns Terraform infrastructure and deploys the selected bundle to Lambda, S3, and CloudFront.

## Application source and AWS configuration

- The source repository owns `lambda_handler.py`, `migrate_handler.py`, the Lambda packaging script, backend migrations, and the React frontend build.
- The source workflow uploads a versioned `deployment-bundle.tar.gz` to `s3://<artifact-bucket>/releases/<version>/`.
- Terraform downloads the selected bundle and deploys the API/migration Lambdas and static frontend.
- The API Lambda reads its database secret and writes uploads to the private site bucket. CloudFront serves the frontend, API routes, and uploaded files.

The infra GitHub Actions workflow invokes the migration Lambda after each successful deployment.

## AWS resources created

- Encrypted private RDS PostgreSQL with a generated database password and app signing key stored in Secrets Manager.
- Lambda functions for the API and Alembic migrations, with CloudWatch logs.
- Private, encrypted, versioned S3 bucket for application release bundles.
- API Gateway HTTP API with Lambda proxy integration.
- VPC with two public subnets, two private subnets, and no NAT Gateway.
- Interface VPC endpoints for Secrets Manager and CloudWatch Logs, plus an S3 gateway endpoint for uploaded images.
- Lambda security-group egress is restricted to PostgreSQL, HTTPS interface endpoints, and the S3 prefix list. RDS accepts PostgreSQL only from Lambda.
- Private S3 frontend bucket, CloudFront Origin Access Control, HTTPS redirect, SPA fallback, and `/api/*` routing to API Gateway.

The database and Lambda run in private subnets. This example keeps SIT costs lower by using Single-AZ RDS; use the production settings and review capacity, recovery, and security requirements before deploying production.

## Requirements

- Terraform 1.10 or newer
- AWS CLI credentials with permission to create the stack resources
- An existing S3 bucket for Terraform state, with versioning/encryption and restricted access

Terraform cannot create its own backend bucket before it initializes. Copy `backend.hcl.example` to `backend.hcl`, set the pre-created state bucket, and keep a unique state key per environment. The `.gitignore` excludes `backend.hcl`, local tfvars, state, and build output.

## Local application development

Application development and builds happen in the source repo (`food-order-3tier-aws`). Configure its local `.env` there and run the backend/frontend from that repository. This infrastructure repo consumes built releases; it does not build application code.

## Bootstrap SIT and deploy releases with GitHub Actions

```bash
if [ ! -f backend.hcl ]; then cp backend.hcl.example backend.hcl; fi
# If backend.hcl already exists, preserve it and verify its key is the SIT state key.
cp sit.tfvars.example sit.tfvars
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive
terraform validate
terraform plan \
  -target=aws_s3_bucket.artifacts \
  -target=aws_s3_bucket_versioning.artifacts \
  -target=aws_s3_bucket_server_side_encryption_configuration.artifacts \
  -target=aws_s3_bucket_public_access_block.artifacts \
  -target=aws_s3_bucket_lifecycle_configuration.artifacts \
  -var-file=sit.tfvars \
  -var=static_site_path=.github/workflows
terraform apply \
  -target=aws_s3_bucket.artifacts \
  -target=aws_s3_bucket_versioning.artifacts \
  -target=aws_s3_bucket_server_side_encryption_configuration.artifacts \
  -target=aws_s3_bucket_public_access_block.artifacts \
  -target=aws_s3_bucket_lifecycle_configuration.artifacts \
  -var-file=sit.tfvars \
  -var=static_site_path=.github/workflows
```

This one-time targeted apply creates the artifact bucket before the source pipeline needs to upload the first release. The Terraform state bucket in `backend.hcl` must already exist. The artifact bucket is private, encrypted, versioned, and protected from force deletion.

Configure GitHub Actions variables in both repositories (Settings → Secrets and variables → Actions → Variables): `AWS_REGION` (usually `ap-southeast-1`) and `ARTIFACT_BUCKET` (from `terraform output -raw artifact_bucket_name`). In the infra repository also set `TF_STATE_BUCKET` and `TF_STATE_KEY`, such as `food-order-serverless/sit/terraform.tfstate`. Add an `AWS_ROLE_TO_ASSUME` secret to both repositories for their AWS GitHub OIDC role. The source role trust should match `repo:phonemyattayzar/food-order-3tier-aws:ref:refs/heads/deploy/lambda`. The infra role is assumed both by the plan job and by the gated apply job, so trust the infra repository's default-branch subject and its `environment:sit` subject. The source role needs `s3:PutObject`, `s3:AbortMultipartUpload`, and `s3:ListMultipartUploadParts` under `releases/*`; the infra role needs `s3:GetObject` for releases plus the usual Terraform permissions for this stack and state bucket.

In the source repository set `INFRA_REPOSITORY` to the infra repository's `owner/name`, and add `INFRA_DISPATCH_TOKEN` with a fine-grained GitHub token that has **Contents: read and write** permission on the infra repo. GitHub requires Contents write for the repository-dispatch endpoint ([GitHub REST API documentation](https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event)). Configure the infra repo's `sit` environment with required reviewers if deployment approval is desired.

Commit the infra workflow to the infra repo's default branch so GitHub can receive repository-dispatch events. Then push a commit to source repo branch `deploy/lambda`. Its workflow builds a Lambda ZIP and frontend bundle, uploads `releases/<git-sha>-<workflow-run-id>/deployment-bundle.tar.gz`, and triggers the infra workflow with that exact version. The infra workflow downloads the bundle, creates and saves a Terraform plan, waits for the `sit` environment approval if configured, applies the plan, then invokes the migration Lambda. You can also run the infra workflow manually and enter a release version. The first full deployment creates the network, database, Lambdas, API, site bucket, and CloudFront; CloudFront may take several minutes.

To run database migrations manually when needed:

```bash
MIGRATION_FUNCTION="$(terraform output -raw migration_lambda_name)"
aws lambda invoke \
  --function-name "$MIGRATION_FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  migration-result.json
cat migration-result.json
```

The migration Lambda runs inside the VPC, retrieves the secret, and applies the repository's Alembic revisions from `/var/task/migrations`. Re-run this after deploying changes that add new migration revisions. Review the function logs and response; do not assume migrations succeeded solely because the invocation command returned.

Get the frontend and health URLs:

```bash
terraform output website_url
terraform output api_via_cloudfront_health_url
```

The frontend uses same-origin `/api/v1` requests, so CloudFront forwards those API requests to API Gateway. The health route is the app's `/api/v1/` endpoint. API docs are available at `/api/v1/docs` after deployment.

## SIT and production separation

Use different state keys, for example:

```text
food-order-serverless/sit/terraform.tfstate
food-order-serverless/prod/terraform.tfstate
```

`sit.tfvars.example` is cost-oriented and single-AZ. `prod.tfvars.example` enables Multi-AZ, longer backup retention, deletion protection, a final snapshot, a longer Secrets Manager recovery window, and disables frontend bucket force-destroy. Use a separate AWS account and CI IAM role for production when possible, and require a human approval before production apply. Review the final snapshot name before any planned database replacement/destroy.

## Operational and security notes

- Terraform state includes generated credentials and the JWT signing secret because Terraform creates the Secrets Manager value. Treat state access as secret access; use encrypted/versioned S3 and narrow IAM permissions.
- Secrets are loaded at Lambda cold start and cached for that execution environment. Rotating the database password requires coordinated RDS/Secrets Manager changes and function recycle/deploy; this scaffold does not implement rotation.
- Lambda uses unreserved concurrency (`-1`) so this project does not consume reserved account concurrency during creation. Positive reservations require enough account quota to leave AWS's minimum unreserved capacity. If you later cap concurrency to protect RDS, check the regional Lambda quota first and consider RDS Proxy.
- Uploaded images share the private frontend bucket under `uploads/`; CloudFront serves the files. Add upload size/content scanning and lifecycle rules before production.
- The API has no API Gateway authorizer or WAF/rate limit in this starter. The application has its own JWT auth routes; review public endpoints and add edge protections before production.
- NAT gateways are omitted. The interface endpoints cost per endpoint/AZ-hour and data processed. Use AWS Pricing Calculator for your region before choosing endpoints versus NAT.
- The FastAPI app currently configures permissive CORS. Frontend traffic is same-origin through CloudFront; tighten the app/API CORS policy before exposing the API directly.
- Database subnet CIDRs must not overlap with the original infrastructure, VPN, or connected networks.
- Confirm RDS engine version and instance-class availability in the target AWS region before deploying.

## Troubleshooting API 500 errors

If `/users/` or `/restaurants/` returns HTTP 500 and the API Lambda log says `relation "users" does not exist` or `relation "restaurants" does not exist`, re-run the infra deployment workflow for the selected release; it invokes the Alembic migration Lambda after applying Terraform. To run the migration manually:

```bash
aws lambda invoke \
  --function-name "$(terraform output -raw migration_lambda_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  migration-result.json
cat migration-result.json
```

A successful invocation returns `"status": "migrations applied"`; also check that the invoke response has no `FunctionError` and review the migration Lambda CloudWatch log. The handler explicitly points Alembic at the packaged `/var/task/migrations` folder. An unauthenticated `/me` request returning HTTP 401 is expected; it is separate from missing-table 500 errors.

## Troubleshooting a blank frontend

If the browser shows a blank page after a failed Terraform apply, first correct the apply errors and run `terraform plan` and `terraform apply` again. Terraform may have created some independent resources before reporting failures; do not destroy the whole stack just to retry. Wait until the CloudFront distribution status is `Deployed`. In browser Developer Tools → Network, check `index.html` and its `/assets/*.js` file: both should return `200`, and the JavaScript response must contain JavaScript rather than the SPA `index.html`. A missing bundle commonly returns `403/404` from the private S3 origin and appears as a white screen. Then check `/api/v1/` separately; an API error should not prevent the React shell from rendering, but can prevent data from loading.

## Destroying disposable SIT

SIT settings permit deleting the database without a final snapshot and emptying the frontend bucket. The artifact bucket has `force_destroy = false`; preserve or manually remove its release objects and versions before deleting that bucket. Only after confirming the selected backend key and reviewing the plan:

```bash
terraform plan -destroy -var-file=sit.tfvars
```

Use this only for disposable SIT data. Production resources should be protected and must not be routinely destroyed.
