# 公网端点 D —— nginx 静态分发（ADR-018 §2.1 D）。
# dist/ 以**只读卷**挂载到 /srv/dist（见 README.md），镜像内不含任何 adapter/凭证/状态。
#
#   docker build -t elecon-endpoint deploy/public-endpoint
#   docker run --rm -p 8080:80 -v /abs/path/to/dist:/srv/dist:ro elecon-endpoint

FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf

# dist 在运行时以只读卷提供;镜像本身零内容、零状态、零凭证（红线 #2）。
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/health || exit 1
