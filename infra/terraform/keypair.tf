resource "aws_key_pair" "this" {
  key_name   = var.cluster_name
  public_key = file(pathexpand(var.ssh_public_key_path))
}
