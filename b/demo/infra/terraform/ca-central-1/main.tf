
resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.project}-artifacts-${random_id.rand.hex}"
  force_destroy = true
  tags = { Project = var.project }
}

resource "aws_ecr_repository" "repo" {
  name = "${var.project}"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  tags = { Project = var.project }
}

resource "random_id" "rand" {
  byte_length = 4
}

output "artifacts_bucket" { value = aws_s3_bucket.artifacts.bucket }
output "ecr_repository_url" { value = aws_ecr_repository.repo.repository_url }
