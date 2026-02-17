FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    unzip \
    ca-certificates \
    && curl -fsSL https://get.docker.com | sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# Add node user to docker group for socket access, ensure home dir ownership
RUN groupadd -f docker \
    && usermod -aG docker node \
    && mkdir -p /home/node/.npm/_npx \
    && chown -R node:node /home/node

WORKDIR /repos
RUN chown node:node /repos

USER node

ENV HOST=0.0.0.0
ENV PORT=4000

EXPOSE 4000 4001

CMD ["npx", "-y", "vibe-kanban"]
