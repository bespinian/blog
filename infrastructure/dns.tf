data "aws_route53_zone" "main" {
  name = "bespinian.io"
}

resource "aws_route53_record" "main" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "blog"
  type    = "CNAME"
  ttl     = 172800 # 2 days
  records = ["bespinian.github.io"]
}
