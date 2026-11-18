# eapol_test (wpa_supplicant 소스의 RADIUS EAP 시험 도구) 컨테이너
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends eapoltest ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["eapol_test"]
