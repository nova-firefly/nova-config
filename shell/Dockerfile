# Browser shell: ttyd (actively maintained C/websocket terminal) +
# openssh-client so it can relay to the host's sshd. Image rebuilt locally
# because the upstream wettyoss/wetty image hasn't been rebuilt since 2022.
# tsl0922/ttyd:alpine already provides tini as ENTRYPOINT.
FROM tsl0922/ttyd:alpine

RUN apk add --no-cache openssh-client
