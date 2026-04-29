data "aws_iam_policy_document" "bedrock" {
  statement {
    sid    = "BedrockInference"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "bedrock" {
  name        = var.iam_policy_name
  description = "Allows OpenClaw gateway to invoke Bedrock foundation models."
  policy      = data.aws_iam_policy_document.bedrock.json
}

resource "aws_iam_user" "bedrock" {
  name = var.iam_user_name

  tags = {
    Project = "openclaw"
    Branch  = "vaniam-ai"
  }
}

resource "aws_iam_user_policy_attachment" "bedrock" {
  user       = aws_iam_user.bedrock.name
  policy_arn = aws_iam_policy.bedrock.arn
}

# ── Access Key ────────────────────────────────────────────────────────────────
# The secret is written to Terraform state. Store state in a secured backend
# (e.g. S3 + DynamoDB with encryption) or use AWS Secrets Manager after
# initial provisioning and rotate the key there.

resource "aws_iam_access_key" "bedrock" {
  user = aws_iam_user.bedrock.name
}
