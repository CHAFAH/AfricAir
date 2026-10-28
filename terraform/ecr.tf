resource "aws_ecr_repository" "app" {
  for_each             = toset(["africair-web", "africair-api"])
  name                 = each.value
  image_tag_mutability = "MUTABLE" # allows re-pushing :latest
  force_delete         = true      # terraform destroy also removes the images

  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}
