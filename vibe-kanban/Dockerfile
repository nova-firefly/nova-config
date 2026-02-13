FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    unzip \
    ca-certificates \
    && curl -fsSL https://get.docker.com | sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repos

ENV HOST=0.0.0.0
ENV PORT=4000

EXPOSE 4000 4001

CMD ["npx", "-y", "vibe-kanban"]
