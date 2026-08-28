# ==============================================================================
# Amazon Elastic Container Registry (ECR) Repositories
# ==============================================================================

resource "aws_ecr_repository" "golang_product_service" {
  name                 = "golang-product-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_repository" "python_product_info_service" {
  name                 = "python-product-info-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}
