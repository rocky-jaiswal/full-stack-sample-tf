output "key_id" {
  value = aws_kms_key.main.key_id
}

output "key_arn" {
  value = aws_kms_key.main.arn
}

output "key_alias_arn" {
  value = aws_kms_alias.main.arn
}
