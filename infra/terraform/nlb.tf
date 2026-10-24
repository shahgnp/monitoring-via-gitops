resource "aws_lb" "api" {
  name               = "${var.cluster_name}-api"
  load_balancer_type = "network"
  internal           = false
  subnets            = [aws_subnet.public.id]
}

# IP targets with client IP preservation off let nodes reach the API through the NLB (no hairpin drops).
resource "aws_lb_target_group" "api" {
  for_each             = toset(["6443", "9345"])
  name                 = "${var.cluster_name}-${each.value}"
  port                 = tonumber(each.value)
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  preserve_client_ip   = "false"
  deregistration_delay = 30

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }
}

resource "aws_lb_listener" "api" {
  for_each          = aws_lb_target_group.api
  load_balancer_arn = aws_lb.api.arn
  port              = tonumber(each.key)
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = each.value.arn
  }
}

resource "aws_lb_target_group_attachment" "api" {
  for_each = {
    for pair in setproduct(["6443", "9345"], range(var.control_plane_count)) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], index = pair[1] }
  }
  target_group_arn = aws_lb_target_group.api[each.value.port].arn
  target_id        = aws_instance.control_plane[each.value.index].private_ip
}
