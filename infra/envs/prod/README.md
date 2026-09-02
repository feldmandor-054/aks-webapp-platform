# prod environment

Identical root to `../dev` (`main.tf`, `variables.tf`, `outputs.tf` are byte-for-byte the same and
only call `modules/platform`). The **only** files that differ per environment are:

- `terraform.tfvars` — sizing, zones, SKU tier, API-server allow-list
- `backend.hcl` — separate state file (`webapp-prod.tfstate`), written by `infra/bootstrap/bootstrap.sh`

That is the "reusable infrastructure vs environment-specific configuration" boundary.

**Not applied during the assignment** to stay within the free-account budget; the values show the
production posture (Standard tier SLA, zone-redundant 3+ nodes, dedicated user pool, restricted API server).
